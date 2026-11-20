// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {CelestiaShareProof} from "src/balances/AttestedBalanceAdapters/derive/CelestiaShareProof.sol";
import {DeriveRecord} from "src/balances/AttestedBalanceAdapters/derive/DeriveRecord.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @notice The parts of Derive v3's `VerifiableApp` (VAPP) this adapter reads.
interface IDeriveVerifiableApp {
    function celestiaLastCommitment() external view returns (bytes32);
    function programVKey() external view returns (bytes32);
    function verifier() external view returns (address);
}

/// @title Derive v3 Balance Adapter (attested from Derive's Celestia batch data)
/// @author KPK
/// @notice Reports a fund Safe's collateral on Derive v3. Derive keeps account state on its sequencer; Ethereum holds
///         the `VerifiableApp` (VAPP), which stores the Celestia share commitment of the newest batch's data blob
///         (`celestiaLastCommitment()`). Each blob carries the full record of every subaccount that changed in that
///         batch. A submitter proves the shares holding the fund's records against that commitment; this adapter
///         decodes the records and caches the collateral, one value per token.
///
/// @dev **What the proof binds — the statement ADR 0022 requires of every member.** The cached amount is bound to the
///      bytes Derive posted to Celestia for the newest batch. It is NOT bound to `VAPP.stateRoot()`: whether Derive's
///      SP1 program proves that blob equals the state transition is not public. The owner and subaccount id come from
///      the same bytes. The Derive-asset → token table and decimals are constructor constants, not attested.
///
///      **Acceptance rules,** each fail-loud in {_verifyPayload}: every share must hash to the live commitment; the
///      record's owner must be the account; the subaccount must hold no perps and no options (their value is not
///      decoded); no balance may be negative (the family is credit-only); every non-zero balance must be in a mapped
///      asset; subaccount ids must be strictly ascending (no double counting); VAPP's `programVKey()` and
///      `verifier()` must equal the reviewed pair passed to the constructor. A later rotation also makes cached
///      entries read 0 ({_isLive}).
///
///      **Freshness.** Only the newest batch's commitment is on Ethereum, and a blob only carries subaccounts that
///      changed, so a submit needs the fund's records in the newest batch. The intended flow touches the account
///      first (a dust transfer between the fund's own subaccounts) and submits in the settlement transaction.
///      Cached entries read 0 after the next batch (about 10 minutes).
///
///      **Framing is a consistency check, not a proof.** The record's offset is chosen by the submitter; the adapter
///      requires the next record's head right after it, or the previous record ending exactly where it starts.
///
///      Trust model and alternatives: `docs/decisions/0031-derive-celestia-attested-adapter.md`. Family: ADR 0022.
contract DeriveCelestiaAttestedBalanceAdapter is AttestedValueCache {
    //
    // Type Definitions
    //

    /// @notice One 512-byte share and its path to the blob commitment.
    struct ShareProof {
        uint256 index; // the share's index in the blob
        bytes share;
        uint256 subtree;
        uint256 position;
        bytes[] nmtSiblings;
        bytes32[] rfcSiblings;
    }

    /// @notice The contiguous shares that hold one subaccount record, plus where the record starts in their payload.
    /// @param recordOffset Offset of the record in the concatenated share payloads (share headers stripped).
    /// @param usePrevious  Frame the record by the previous record ending at `recordOffset` (decoded from
    ///                     `prevOffset`) instead of by the next record's head. Needed when the record is the last in
    ///                     its section.
    struct SubaccountProof {
        uint256 subaccountId;
        uint256 numSubtrees;
        uint256 recordOffset;
        bool usePrevious;
        uint256 prevOffset;
        ShareProof[] shares;
    }

    //
    // Constants & immutables
    //

    /// @notice Derive's Celestia namespace (share version 0).
    bytes29 public constant NAMESPACE = bytes29(hex"0000000000000000000000000000000000000046023b2bfb8ba6dc6fdc");

    /// @notice Upper bound on subaccounts per submit.
    uint256 public constant MAX_SUBACCOUNTS = 8;

    /// @notice Upper bound on shares per subaccount proof. A collateral-only record fits in one or two; the cap is
    ///         set so a record with positions (a real one spans 23 shares) still decodes and is refused by name
    ///         ({PositionsNotAllowed}) rather than by size.
    uint256 public constant MAX_SHARES_PER_SUBACCOUNT = 32;

    /// @notice Upper bound on distinct tokens cached per account.
    uint256 public constant MAX_TOKENS_PER_ACCOUNT = 8;

    /// @dev Share header: namespace (29) + info byte (1), plus the sequence length (4) on a blob's first share.
    uint256 private constant _FIRST_HEADER = 34;
    uint256 private constant _CONT_HEADER = 30;

    /// @dev Derive amounts are 12-decimal fixed point.
    uint8 private constant _DERIVE_DECIMALS = 12;

    IDeriveVerifiableApp public immutable VAPP;

    /// @notice The reviewed SP1 program key. Reads and writes refuse once VAPP reports another.
    bytes32 public immutable PINNED_VKEY;

    /// @notice The reviewed SP1 verifier. Reads and writes refuse once VAPP reports another.
    address public immutable PINNED_VERIFIER;

    /// @notice Derive protocol asset id → Ethereum token. Set once in the constructor.
    mapping(address deriveAsset => address token) public tokenOf;

    /// @dev Token decimals, read once in the constructor.
    mapping(address token => uint8) private _decimals;

    address[] private _deriveAssets;

    //
    // Errors
    //

    error ProgramChanged(bytes32 vkey, address verifier);
    error EmptyPayload();
    error TooManySubaccounts(uint256 count);
    error TooManyShares(uint256 subaccountId, uint256 count);
    error SubaccountsNotAscending(uint256 subaccountId);
    error SharesNotContiguous(uint256 subaccountId);
    /// @notice A share does not hash to the live commitment: a forged or altered share, a wrong path, or a proof
    ///         built against an older batch.
    error InvalidShareProof();
    error WrongSubaccount(uint256 expected, uint256 found);
    error WrongOwner(uint256 subaccountId, address found);
    error BadBoundary(uint256 subaccountId);
    error PositionsNotAllowed(uint256 subaccountId, uint256 perps, uint256 options);
    error NegativeBalance(uint256 subaccountId, address deriveAsset);
    error UnmappedAsset(uint256 subaccountId, address deriveAsset);

    //
    // Constructor
    //

    /// @param vapp_           Derive's `VerifiableApp` proxy.
    /// @param navCalculator_  The NAVCalculator (validated by {AttestedValueCache}).
    /// @param admin_          Holder of `DEFAULT_ADMIN_ROLE`, which grants `SUBMITTER_ROLE`.
    /// @param pinnedVKey_     The reviewed `programVKey`. Must equal VAPP's at deployment.
    /// @param pinnedVerifier_ The reviewed `verifier`. Must equal VAPP's at deployment.
    /// @param deriveAssets_   Derive protocol asset ids (as `WithdrawalOutbox.resolveAsset` knows them).
    /// @param tokens_         The Ethereum token for each Derive asset id.
    constructor(
        address vapp_,
        address navCalculator_,
        address admin_,
        bytes32 pinnedVKey_,
        address pinnedVerifier_,
        address[] memory deriveAssets_,
        address[] memory tokens_
    ) AttestedValueCache(navCalculator_, admin_) {
        if (vapp_ == address(0) || pinnedVKey_ == bytes32(0) || pinnedVerifier_ == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(vapp_, "VerifiableApp");
        uint256 n = deriveAssets_.length;
        if (n == 0 || n != tokens_.length || n > MAX_TOKENS_PER_ACCOUNT) revert InvalidArguments();

        VAPP = IDeriveVerifiableApp(vapp_);
        PINNED_VKEY = pinnedVKey_;
        PINNED_VERIFIER = pinnedVerifier_;
        // A pair that does not match the live VAPP would deploy an adapter that can never read.
        if (!_programPinned()) revert ProgramChanged(VAPP.programVKey(), VAPP.verifier());

        for (uint256 i; i < n; ++i) {
            address asset = deriveAssets_[i];
            address token = tokens_[i];
            if (asset == address(0) || token == address(0) || tokenOf[asset] != address(0)) revert InvalidArguments();
            AddressCheckLib.requireContract(token, "Token");
            tokenOf[asset] = token;
            _decimals[token] = IERC20Metadata(token).decimals();
            _deriveAssets.push(asset);
        }
    }

    //
    // Mutators
    //

    /// @notice Typed convenience over {IAttestedBalanceAdapter.submit}. Requires `SUBMITTER_ROLE`.
    /// @dev Funnels through `_submitPayload`, the family's single write path.
    function submitSubaccounts(address account, SubaccountProof[] calldata proofs) external {
        _submitPayload(account, abi.encode(proofs));
    }

    //
    // Reads
    //

    /// @notice The mapped Derive asset ids, in constructor order.
    function deriveAssets() external view returns (address[] memory) {
        return _deriveAssets;
    }

    function protocolName() external pure returns (string memory) {
        return ProtocolNames.DERIVE_V3;
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Collateral"]` — the token is in `balanceAsset`; the argument is ignored.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Collateral";
    }

    //
    // Hooks — the attested family contract
    //

    /// @inheritdoc AttestedValueCache
    /// @dev Decodes `abi.encode(SubaccountProof[])`, verifies every subaccount record against `epoch`, and returns
    ///      one summed value per token. The returned `ctxs` are empty: this member keeps no state beside the
    ///      attestation and {_assetLegs} ignores `ctx`.
    function _verifyPayload(bytes32 epoch, address account, bytes memory data)
        internal
        view
        override
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
    {
        if (!_programPinned()) revert ProgramChanged(VAPP.programVKey(), VAPP.verifier());
        SubaccountProof[] memory proofs = abi.decode(data, (SubaccountProof[]));
        uint256 n = proofs.length;
        if (n == 0) revert EmptyPayload();
        if (n > MAX_SUBACCOUNTS) revert TooManySubaccounts(n);

        address[] memory tokens = new address[](MAX_TOKENS_PER_ACCOUNT);
        uint256[] memory sums = new uint256[](MAX_TOKENS_PER_ACCOUNT);
        uint256 count;
        uint256 prevId;
        for (uint256 i; i < n; ++i) {
            SubaccountProof memory p = proofs[i];
            if (i != 0 && p.subaccountId <= prevId) revert SubaccountsNotAscending(p.subaccountId);
            prevId = p.subaccountId;

            DeriveRecord.Record memory rec = _readRecord(epoch, p);
            if (rec.owner != account) revert WrongOwner(p.subaccountId, rec.owner);
            if (rec.perpCount != 0 || rec.optionCount != 0) {
                revert PositionsNotAllowed(p.subaccountId, rec.perpCount, rec.optionCount);
            }
            count = _accumulate(rec, tokens, sums, count);
        }

        assets = new address[](count);
        values = new uint256[](count);
        ctxs = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = tokens[i];
            values[i] = sums[i];
        }
    }

    /// @inheritdoc AttestedValueCache
    function _liveEpoch() internal view override returns (bytes32) {
        return VAPP.celestiaLastCommitment();
    }

    /// @inheritdoc AttestedValueCache
    /// @dev Live iff the epoch is current AND VAPP still runs the reviewed program and verifier. VAPP's owner can
    ///      rotate either without a new batch; this turns that into a 0 read rather than a figure from a program
    ///      nobody reviewed.
    function _isLive(Attestation memory a, address) internal view override returns (bool) {
        return a.epoch == _liveEpoch() && _programPinned();
    }

    /// @inheritdoc AttestedValueCache
    /// @dev The attested balance as is. A collateral balance has no on-chain component to subtract, so the
    ///      postcondition (never above the attested figure) holds trivially.
    function _liveValue(address, address, uint256 attestedValue) internal pure override returns (uint256) {
        return attestedValue;
    }

    /// @inheritdoc AttestedValueCache
    /// @dev One `Collateral` leg per token; positionId is the VAPP, the trust anchor.
    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](1);
        legs[0] = _row(meta, liveValue, abi.encode(address(VAPP)), bytes32(0));
    }

    function _maxAssetsPerAccount() internal pure override returns (uint256) {
        return MAX_TOKENS_PER_ACCOUNT;
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.DERIVE;
    }

    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.DERIVE_V3;
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.DERIVE_V3_SUBACCOUNTS;
    }

    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Collateral;
    }

    //
    // Internal
    //

    function _programPinned() internal view returns (bool) {
        return VAPP.programVKey() == PINNED_VKEY && VAPP.verifier() == PINNED_VERIFIER;
    }

    /// @dev Verifies `p`'s shares against `epoch`, joins their payloads, decodes the record and checks its framing.
    function _readRecord(bytes32 epoch, SubaccountProof memory p)
        private
        pure
        returns (DeriveRecord.Record memory rec)
    {
        uint256 k = p.shares.length;
        if (k == 0 || k > MAX_SHARES_PER_SUBACCOUNT) revert TooManyShares(p.subaccountId, k);

        bytes memory data = new bytes(k * (CelestiaShareProof.SHARE_SIZE - _CONT_HEADER));
        uint256 len;
        for (uint256 j; j < k; ++j) {
            ShareProof memory s = p.shares[j];
            if (s.index != p.shares[0].index + j) revert SharesNotContiguous(p.subaccountId);
            bytes32 root = CelestiaShareProof.commitmentOf(
                s.share, NAMESPACE, s.position, s.nmtSiblings, s.subtree, p.numSubtrees, s.rfcSiblings
            );
            if (root != epoch) revert InvalidShareProof();
            // Info byte bit 0 marks the first share of a sequence, which also carries the sequence length.
            uint256 header = uint8(s.share[29]) & 1 == 1 ? _FIRST_HEADER : _CONT_HEADER;
            uint256 size = CelestiaShareProof.SHARE_SIZE - header; // share length checked = 512 by commitmentOf
            bytes memory share = s.share;
            assembly ("memory-safe") {
                mcopy(add(add(data, 32), len), add(add(share, 32), header), size)
            }
            len += size;
        }
        assembly ("memory-safe") {
            mstore(data, len)
        }

        rec = DeriveRecord.decode(data, p.recordOffset);
        if (rec.subaccountId != p.subaccountId) revert WrongSubaccount(p.subaccountId, rec.subaccountId);
        if (p.usePrevious) {
            DeriveRecord.Record memory prev = DeriveRecord.decode(data, p.prevOffset);
            if (prev.end != p.recordOffset || prev.subaccountId >= p.subaccountId) revert BadBoundary(p.subaccountId);
        } else if (!DeriveRecord.isHeadAfter(data, rec.end, p.subaccountId)) {
            revert BadBoundary(p.subaccountId);
        }
    }

    /// @dev Adds `rec`'s non-zero balances into `(tokens, sums)`, scaled from 12 decimals to each token's.
    function _accumulate(DeriveRecord.Record memory rec, address[] memory tokens, uint256[] memory sums, uint256 count)
        private
        view
        returns (uint256)
    {
        for (uint256 c; c < rec.collateral.length; ++c) {
            DeriveRecord.Collateral memory col = rec.collateral[c];
            if (col.balance == 0) continue;
            if (col.balance < 0) revert NegativeBalance(rec.subaccountId, col.asset);
            address token = tokenOf[col.asset];
            if (token == address(0)) revert UnmappedAsset(rec.subaccountId, col.asset);

            uint256 amount = _toTokenUnits(uint256(col.balance), _decimals[token]);
            uint256 t;
            while (t < count && tokens[t] != token) ++t;
            if (t == count) {
                if (count == MAX_TOKENS_PER_ACCOUNT) revert TooManyAttestations(rec.owner, count + 1);
                tokens[count++] = token;
            }
            sums[t] += amount;
        }
        return count;
    }

    /// @dev 12-decimal Derive amount → token units. Rounds down when the token has fewer decimals.
    function _toTokenUnits(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals >= _DERIVE_DECIMALS) return amount * 10 ** (decimals - _DERIVE_DECIMALS);
        return amount / 10 ** (_DERIVE_DECIMALS - decimals);
    }
}
