// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {CelestiaShareProof} from "src/balances/AttestedBalanceAdapters/derive/CelestiaShareProof.sol";
import {IDeriveOptionPricer} from "src/balances/AttestedBalanceAdapters/derive/IDeriveOptionPricer.sol";
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
    /// @notice The newest proven batch's `maxOpTimestamp` (an SP1 public input); 0 after an owner `setRoot`.
    function lastOpTimestamp() external view returns (uint64);
}

/// @title Derive v3 Balance Adapter (attested from Derive's Celestia batch data)
/// @author KPK
/// @notice Reports a fund Safe's collateral and option positions on Derive v3. Derive keeps account state on its
///         sequencer; Ethereum holds the `VerifiableApp` (VAPP), which stores the Celestia share commitment of the
///         newest batch's data blob (`celestiaLastCommitment()`). Each blob carries the full record of every
///         subaccount that changed in that batch. A submitter proves the shares holding the fund's records against
///         that commitment; this adapter decodes the records and caches one value per token: collateral, plus every
///         option at its Black-76 value, netted against the cash token.
///
/// @dev **What the proof binds — the statement ADR 0022 requires of every member.** The cached amount is bound to the
///      bytes Derive posted to Celestia for the newest batch. It is NOT bound to `VAPP.stateRoot()`: whether Derive's
///      SP1 program proves that blob equals the state transition is not public. The owner and subaccount id come from
///      the same bytes. The Derive-asset → token table, the option market table and decimals are constructor
///      constants, not attested.
///
///      **Option valuation: Derive's mark, from Derive's signed feeds.** Options are cash-settled in Derive's USDC
///      cash asset, so 1 cash token = 1 USD and every option's value is credited (long, rounded down) or debited
///      (short, rounded up) to {CASH_TOKEN}. A submit carries Derive's signed spot, forward, rate and vol feed items;
///      {PRICER} (a separate immutable contract, see `derive/DeriveOptionPricer.sol`) verifies them against its fixed
///      signer set and values every option of every submitted subaccount at Derive's mark: Black-76 on Derive's SVI
///      slice for a live option, intrinsic value at Derive's 30-minute settlement TWAP for an expired one. Perps are
///      not valued and refuse the submit ({PerpsNotAllowed}).
///
///      **Every submitted subaccount must be worth at least 0 on its own:** its own cash collateral must cover its own
///      short options ({LiabilityExceedsCollateral}). A contract cannot prove the submitter showed every subaccount
///      of the wallet, so this is what keeps omission safe: leaving a subaccount out can only lower the figure.
///      Netting a short in one subaccount against cash in another would let a submitter drop the short's subaccount
///      and over-report. This assumes Derive has no recourse from one subaccount to another (each is its own margin
///      account; ADR 0031 lists the confirmation as open).
///
///      **Acceptance rules,** each fail-loud in {_verifyPayload}: the blob's first share must verify at index 0 (it
///      fixes the share count, and so the tree shape); every record share must verify at its stated blob index, and
///      a record's shares must be consecutive, so the decoded bytes are exactly the posted bytes; the record's owner
///      must be the account; the subaccount must hold no perps; options need a {PRICER}, which applies its own feed
///      rules (every item signed by every signer, within its deadline, fresh, and used); no collateral balance may be
///      negative (the family is credit-only); every non-zero balance must be in a mapped asset; each subaccount's
///      cash must cover its short options; subaccount ids must be strictly ascending (no double counting); VAPP's
///      `programVKey()` and `verifier()` must equal the reviewed pair passed to the constructor, and its newest batch
///      must be at most {MAX_ATTESTATION_AGE} old. A later rotation or an older batch also makes cached entries read
///      0 ({_isLive}).
///
///      **Freshness.** Only the newest batch's commitment is on Ethereum, and a blob only carries subaccounts that
///      changed, so a submit needs the fund's records in the newest batch. The intended flow touches the account
///      first (a dust transfer between the fund's own subaccounts) and submits in the settlement transaction.
///      Cached entries read 0 after the next batch (about 10 minutes), or once the batch itself is older than
///      {MAX_ATTESTATION_AGE} by VAPP's proven `lastOpTimestamp`: if Derive stops posting batches while its sequencer
///      keeps trading, neither a late first submit nor a replay can make the stalled batch count again. Every token
///      a submit's records cover is written, zero included, so a value that fell to zero replaces the old one.
///
///      **Framing is a consistency check, not a proof.** The record's offset is chosen by the submitter; the adapter
///      requires the next record's head right after it, or the previous record ending exactly where it starts.
///      Framing by the previous record needs that record's shares too, and it may belong to anyone; the fund should
///      hold two adjacent subaccount ids and touch both, so each frames the other with its own small record.
///
///      Trust model and alternatives: `docs/decisions/0031-derive-celestia-attested-adapter.md`. Family: ADR 0022.
contract DeriveCelestiaAttestedBalanceAdapter is AttestedValueCache {
    //
    // Type Definitions
    //

    /// @notice One 512-byte share and its path to the blob commitment. The share's place in the tree (subtree,
    ///         position, depth) is derived from `index` and the proven share count, never supplied.
    struct ShareProof {
        uint256 index; // the share's index in the blob
        bytes share;
        bytes[] nmtSiblings;
        bytes32[] rfcSiblings;
    }

    /// @notice The consecutive shares that hold one subaccount record, plus where the record starts in their payload.
    /// @param recordOffset Offset of the record in the concatenated share payloads (share headers stripped).
    /// @param usePrevious  Frame the record by the previous record ending at `recordOffset` (decoded from
    ///                     `prevOffset`) instead of by the next record's head. Needed when the record is the last in
    ///                     its section.
    struct SubaccountProof {
        uint256 subaccountId;
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

    /// @notice Upper bound on shares per subaccount proof. A collateral-only record fits in one or two. An option
    ///         takes 30 to 46 bytes, so 32 shares hold a record of about 330 options; a larger record is refused by
    ///         size ({TooManyShares}).
    uint256 public constant MAX_SHARES_PER_SUBACCOUNT = 32;

    /// @notice Upper bound on distinct tokens cached per account.
    uint256 public constant MAX_TOKENS_PER_ACCOUNT = 8;

    /// @notice How old the newest batch may be, by VAPP's proven `lastOpTimestamp`, for its records to be submitted
    ///         or read. Batches land about every 10 minutes and the intended flow submits and reads in one
    ///         transaction, so this only bites when Derive stops posting batches: its sequencer can keep settling
    ///         trades that spend the collateral while the commitment, and so the epoch, stays put.
    uint256 public constant MAX_ATTESTATION_AGE = 30 minutes;

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

    /// @notice The token options settle into (Derive's USDC cash asset, mapped). Zero when there is no {PRICER}.
    address public immutable CASH_TOKEN;

    /// @notice Values options from Derive's signed feeds. Zero: any record holding options is refused.
    IDeriveOptionPricer public immutable PRICER;

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
    error PerpsNotAllowed(uint256 subaccountId, uint256 perps);
    /// @notice The record holds options and the adapter has no {PRICER}.
    error UnmappedOption(uint256 subaccountId, address optionAsset);
    /// @notice A subaccount's short options owe more than its own cash collateral plus its long options.
    error LiabilityExceedsCollateral(uint256 subaccountId);
    /// @notice The newest batch is older than {MAX_ATTESTATION_AGE}.
    error BatchTooOld(uint256 lastOpTimestamp);
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
    /// @param cashAsset_      Derive asset id options settle into (USDC). Must be mapped when `pricer_` is set.
    /// @param pricer_         The option pricer, or zero to refuse records holding options.
    constructor(
        address vapp_,
        address navCalculator_,
        address admin_,
        bytes32 pinnedVKey_,
        address pinnedVerifier_,
        address[] memory deriveAssets_,
        address[] memory tokens_,
        address cashAsset_,
        address pricer_
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

        if (pricer_ != address(0)) {
            AddressCheckLib.requireContract(pricer_, "DeriveOptionPricer");
            address cash = tokenOf[cashAsset_];
            if (cash == address(0)) revert InvalidArguments();
            CASH_TOKEN = cash;
            PRICER = IDeriveOptionPricer(pricer_);
        }
    }

    //
    // Mutators
    //

    /// @notice Typed convenience over {IAttestedBalanceAdapter.submit}. Requires `SUBMITTER_ROLE`.
    /// @param firstShare The blob's share 0 with its proof; it fixes the blob's share count.
    /// @param feeds      `abi.encode(IDeriveOptionPricer.Feeds)`: the signed feed items that price the options.
    /// @dev Funnels through `_submitPayload`, the family's single write path.
    function submitSubaccounts(
        address account,
        ShareProof calldata firstShare,
        SubaccountProof[] calldata proofs,
        bytes calldata feeds
    ) external {
        _submitPayload(account, abi.encode(firstShare, proofs, feeds));
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
    /// @dev `["Collateral"]` — the token is in `balanceAsset`; the argument is ignored. The amount is net of
    ///      options (contract NatSpec).
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Collateral";
    }

    //
    // Hooks — the attested family contract
    //

    /// @inheritdoc AttestedValueCache
    /// @dev Decodes `abi.encode(ShareProof firstShare, SubaccountProof[], bytes feeds)`, verifies the first share and
    ///      every subaccount record, has {PRICER} value their options from `feeds`, and returns one netted value per
    ///      token. The returned `ctxs` are empty: this member keeps no state beside the attestation and
    ///      {_assetLegs} ignores `ctx`.
    function _verifyPayload(bytes32 epoch, address account, bytes memory data)
        internal
        view
        override
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
    {
        if (!_programPinned()) revert ProgramChanged(VAPP.programVKey(), VAPP.verifier());
        if (!_batchFresh()) revert BatchTooOld(VAPP.lastOpTimestamp());
        (ShareProof memory first, SubaccountProof[] memory proofs, bytes memory feeds) =
            abi.decode(data, (ShareProof, SubaccountProof[], bytes));
        (assets, values) = _settle(_collect(epoch, account, first, proofs, feeds));
        ctxs = new bytes[](assets.length);
    }

    /// @dev Verifies the first share and every subaccount record, values their options, and returns the book.
    function _collect(
        bytes32 epoch,
        address account,
        ShareProof memory first,
        SubaccountProof[] memory proofs,
        bytes memory feeds
    ) private view returns (Book memory book) {
        uint256 n = proofs.length;
        if (n == 0) revert EmptyPayload();
        if (n > MAX_SUBACCOUNTS) revert TooManySubaccounts(n);
        uint256 numShares = _provenShareCount(epoch, first);
        book = _newBook(account);

        DeriveRecord.Option[][] memory options = new DeriveRecord.Option[][](n);
        uint256[] memory cash = new uint256[](n);
        uint256[] memory ids = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            SubaccountProof memory p = proofs[i];
            if (i != 0 && p.subaccountId <= ids[i - 1]) revert SubaccountsNotAscending(p.subaccountId);
            ids[i] = p.subaccountId;

            DeriveRecord.Record memory rec = _readRecord(epoch, numShares, p);
            if (rec.owner != account) revert WrongOwner(p.subaccountId, rec.owner);
            if (rec.perpCount != 0) revert PerpsNotAllowed(p.subaccountId, rec.perpCount);
            if (rec.options.length != 0 && address(PRICER) == address(0)) {
                revert UnmappedOption(p.subaccountId, rec.options[0].asset);
            }
            cash[i] = _addCollateral(rec, book);
            options[i] = rec.options;
            total += rec.options.length;
        }
        if (total != 0) _addOptions(options, total, cash, ids, feeds, book);
    }

    /// @dev Has {PRICER} value every option of the submit in one call (so it can reject unused feed items), requires
    ///      each subaccount's own cash to cover its own shorts, and nets the result into {CASH_TOKEN}.
    function _addOptions(
        DeriveRecord.Option[][] memory options,
        uint256 total,
        uint256[] memory cash,
        uint256[] memory ids,
        bytes memory feeds,
        Book memory book
    ) private view {
        DeriveRecord.Option[] memory all = new DeriveRecord.Option[](total);
        uint256 k;
        for (uint256 i; i < options.length; ++i) {
            for (uint256 j; j < options[i].length; ++j) {
                all[k++] = options[i][j];
            }
        }
        int256[] memory v = PRICER.values(feeds, all);

        uint256 slot = _slot(book, CASH_TOKEN); // written even at zero: options were valued
        k = 0;
        for (uint256 i; i < options.length; ++i) {
            uint256 credit;
            uint256 debit;
            for (uint256 j; j < options[i].length; ++j) {
                int256 x = v[k++];
                if (x > 0) credit += uint256(x);
                else debit += uint256(-x);
            }
            if (debit > cash[i] + credit) revert LiabilityExceedsCollateral(ids[i]);
            book.credit[slot] += credit;
            book.debit[slot] += debit;
        }
    }

    /// @dev Every covered token, zero included (a zero must replace an earlier positive value of the same batch),
    ///      rounded down to the token's decimals. Per-subaccount coverage ({_addOptions}) keeps credit ≥ debit.
    function _settle(Book memory book) private view returns (address[] memory assets, uint256[] memory values) {
        assets = new address[](book.count);
        values = new uint256[](book.count);
        for (uint256 t; t < book.count; ++t) {
            assets[t] = book.tokens[t];
            values[t] = _toTokenUnits(book.credit[t] - book.debit[t], _decimals[book.tokens[t]]);
        }
    }

    /// @inheritdoc AttestedValueCache
    function _liveEpoch() internal view override returns (bytes32) {
        return VAPP.celestiaLastCommitment();
    }

    /// @inheritdoc AttestedValueCache
    /// @dev Live iff the epoch is current, the batch is at most {MAX_ATTESTATION_AGE} old by VAPP's proven
    ///      `lastOpTimestamp` (not by when the entry was written, which a replay could refresh), and VAPP still runs
    ///      the reviewed program and verifier. VAPP's owner can rotate either without a new batch; this turns that
    ///      into a 0 read rather than a figure from a program nobody reviewed.
    function _isLive(Attestation memory a, address) internal view override returns (bool) {
        return a.epoch == _liveEpoch() && _batchFresh() && _programPinned();
    }

    /// @dev VAPP keeps `lastOpTimestamp <= block.timestamp` (it rejects batches from the future).
    function _batchFresh() internal view returns (bool) {
        return block.timestamp - VAPP.lastOpTimestamp() <= MAX_ATTESTATION_AGE;
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

    /// @dev Verifies the blob's first share at index 0 and returns the share count it records.
    function _provenShareCount(bytes32 epoch, ShareProof memory first) private pure returns (uint256 numShares) {
        if (first.index != 0) revert CelestiaShareProof.NotFirstShare();
        numShares = CelestiaShareProof.numSharesOf(first.share);
        bytes32 root =
            CelestiaShareProof.commitmentOf(first.share, NAMESPACE, 0, numShares, first.nmtSiblings, first.rfcSiblings);
        if (root != epoch) revert InvalidShareProof();
    }

    /// @dev Verifies `p`'s shares against `epoch` at their blob indices, joins their payloads, decodes the record
    ///      and checks its framing.
    function _readRecord(bytes32 epoch, uint256 numShares, SubaccountProof memory p)
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
            // The index is bound by the proof below (the tree shape comes from the proven share count), so
            // consecutive indices mean the joined payload is the blob's bytes in order.
            if (s.index != p.shares[0].index + j) revert SharesNotContiguous(p.subaccountId);
            bytes32 root =
                CelestiaShareProof.commitmentOf(s.share, NAMESPACE, s.index, numShares, s.nmtSiblings, s.rfcSiblings);
            if (root != epoch) revert InvalidShareProof();
            // Share 0 carries the blob's length after the info byte; the others only the info byte.
            uint256 header = s.index == 0 ? _FIRST_HEADER : _CONT_HEADER;
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

    /// @dev Per-token credits and debits of one submit, in Derive's 12 decimals.
    struct Book {
        address account;
        address[] tokens;
        uint256[] credit;
        uint256[] debit;
        uint256 count;
    }

    function _newBook(address account) private pure returns (Book memory b) {
        b.account = account;
        b.tokens = new address[](MAX_TOKENS_PER_ACCOUNT);
        b.credit = new uint256[](MAX_TOKENS_PER_ACCOUNT);
        b.debit = new uint256[](MAX_TOKENS_PER_ACCOUNT);
    }

    /// @dev Index of `token` in `b`, added if new.
    function _slot(Book memory b, address token) private pure returns (uint256 t) {
        while (t < b.count && b.tokens[t] != token) ++t;
        if (t == b.count) {
            if (t == MAX_TOKENS_PER_ACCOUNT) revert TooManyAttestations(b.account, t + 1);
            b.tokens[b.count++] = token;
        }
    }

    /// @dev Credits `rec`'s collateral and returns its {CASH_TOKEN} part (12 decimals). A mapped asset is written
    ///      even at a zero balance, so it replaces an earlier positive value of the same batch.
    function _addCollateral(DeriveRecord.Record memory rec, Book memory b) private view returns (uint256 cash) {
        for (uint256 c; c < rec.collateral.length; ++c) {
            DeriveRecord.Collateral memory col = rec.collateral[c];
            if (col.balance < 0) revert NegativeBalance(rec.subaccountId, col.asset);
            address token = tokenOf[col.asset];
            if (token == address(0)) {
                if (col.balance == 0) continue;
                revert UnmappedAsset(rec.subaccountId, col.asset);
            }
            uint256 amount = uint256(col.balance);
            b.credit[_slot(b, token)] += amount;
            if (token == CASH_TOKEN) cash += amount;
        }
    }

    /// @dev 12-decimal Derive amount → token units. Rounds down when the token has fewer decimals.
    function _toTokenUnits(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals >= _DERIVE_DECIMALS) return amount * 10 ** (decimals - _DERIVE_DECIMALS);
        return amount / 10 ** (_DERIVE_DECIMALS - decimals);
    }
}
