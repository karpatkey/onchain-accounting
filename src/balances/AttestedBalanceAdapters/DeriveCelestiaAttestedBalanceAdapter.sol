// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
///         option at Derive's mark, less USDC debt, as credit-only legs (see the dev note).
///
/// @dev **What the proof binds — the statement ADR 0022 requires of every member.** The cached amount is bound to the
///      bytes Derive posted to Celestia for the newest batch. It is NOT bound to `VAPP.stateRoot()`: whether Derive's
///      SP1 program proves that blob equals the state transition is not public. The owner and subaccount id come from
///      the same bytes. The Derive-asset → token table, the option market table and decimals are constructor
///      constants, not attested.
///
///      **Valuation: Derive's mark and spot, from Derive's signed feeds.** Options are cash-settled in Derive's USDC
///      cash asset, so 1 cash token = 1 USD. A submit carries Derive's signed spot, forward, rate and vol feed items;
///      {PRICER} (a separate immutable contract, see `derive/DeriveOptionPricer.sol`) verifies them against its fixed
///      signer set and values every option of every submitted subaccount at Derive's mark (Black-76 on Derive's SVI
///      slice for a live option, intrinsic value at Derive's 30-minute settlement TWAP for an expired one), long
///      rounded down, short rounded up. It also returns the signed spot of every non-cash collateral asset the
///      adapter asks for. Perps are not valued and refuse the submit ({PerpsNotAllowed}).
///
///      **Debt and covered options: equity per subaccount.** A subaccount that holds options or a negative balance
///      (Derive auto-borrows USDC to buy an option) has its equity worked out in USD, 12 decimals: cash at 1, every
///      other collateral asset at the signed spot (positive balances rounded down, a debt rounded up), options as
///      above. **The equity must be at least 0 on its own** ({NegativeEquity}). A contract cannot prove the submitter
///      showed every subaccount of the wallet, so this is what keeps omission safe: leaving a subaccount out can only
///      lower the figure. Netting a deficit in one subaccount against another's surplus would let a submitter drop
///      the deficit's subaccount and over-report. This assumes Derive has no recourse from one subaccount to another
///      (each is its own margin account; ADR 0031 lists the confirmation as open).
///
///      **Legs are credit-only** (ADR 0022 refuses debt legs), worth at most the subaccount's equity at the signed
///      spot, in this order: (1) a non-cash asset with a positive balance stays in its own units, so a fund
///      denominated in that asset keeps its legs in that asset; (2) cash, options and every debt, a non-cash debt at
///      spot rounded up, net into {CASH_TOKEN}; (3) if that net is negative, the subaccount's non-cash legs shrink by
///      the shortfall, in record order, each by the units worth it at spot rounded up (against the fund). The
///      shortfall is never covered by another subaccount's cash: each subaccount's legs are its own. A subaccount
///      with only non-negative collateral and no options needs no price and books as is. The NAV Calculator then
///      prices each leg at its own feed, so the USD total differs from the equity by that feed's spread to Derive's.
///
///      **Acceptance rules,** each fail-loud in {_verifyPayload}: the blob's first share must verify at index 0 (it
///      fixes the share count, and so the tree shape); every record share must verify at its stated blob index, and
///      a record's shares must be consecutive, so the decoded bytes are exactly the posted bytes; the record's owner
///      must be the account; the subaccount must hold no perps; options and negative balances need a {PRICER}, which
///      applies its own feed rules (every item signed by every signer, within its deadline, fresh, and used); every
///      non-zero balance must be in a mapped asset; each priced subaccount's equity must be at least 0; subaccount
///      ids must be strictly ascending (no double counting); VAPP's
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

    /// @notice The token options settle into and USDC debt is owed in (Derive's USDC cash asset, mapped). Zero when
    ///         there is no {PRICER}.
    address public immutable CASH_TOKEN;

    /// @notice Values options and non-cash collateral from Derive's signed feeds. Zero: any record holding options or
    ///         a negative balance is refused.
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
    /// @notice A subaccount's own equity is below 0: its debt and short options exceed its own collateral and long
    ///         options at Derive's marks. Never netted against another subaccount.
    error NegativeEquity(uint256 subaccountId);
    /// @notice The newest batch is older than {MAX_ATTESTATION_AGE}.
    error BatchTooOld(uint256 lastOpTimestamp);
    /// @notice A negative collateral balance and no {PRICER} to value the debt.
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
    /// @param pricer_         The pricer, or zero to refuse records holding options or debt.
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
    ///      options and debt (contract NatSpec).
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Collateral";
    }

    //
    // Hooks — the attested family contract
    //

    /// @inheritdoc AttestedValueCache
    /// @dev Decodes `abi.encode(ShareProof firstShare, SubaccountProof[], bytes feeds)`, verifies the first share and
    ///      every subaccount record, has {PRICER} value their options and non-cash collateral from `feeds`, and
    ///      returns one value per token. The returned `ctxs` are empty: this member keeps no state beside the attestation and
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

    /// @dev Verifies the first share and every subaccount record, then books them: without a {PRICER}, collateral
    ///      only; with one, {_bookPriced}.
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

        DeriveRecord.Record[] memory recs = new DeriveRecord.Record[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            SubaccountProof memory p = proofs[i];
            if (i != 0 && p.subaccountId <= proofs[i - 1].subaccountId) revert SubaccountsNotAscending(p.subaccountId);

            DeriveRecord.Record memory rec = _readRecord(epoch, numShares, p);
            if (rec.owner != account) revert WrongOwner(p.subaccountId, rec.owner);
            if (rec.perpCount != 0) revert PerpsNotAllowed(p.subaccountId, rec.perpCount);
            if (rec.options.length != 0 && address(PRICER) == address(0)) {
                revert UnmappedOption(p.subaccountId, rec.options[0].asset);
            }
            recs[i] = rec;
            total += rec.options.length;
        }
        if (address(PRICER) == address(0)) {
            for (uint256 i; i < n; ++i) {
                _addCollateral(recs[i], book);
            }
        } else {
            _bookPriced(recs, total, feeds, book);
        }
    }

    /// @dev With a {PRICER}. A subaccount that holds options or debt needs its equity: it is priced and booked by
    ///      {_addEquity}. Any other holds only non-negative collateral, which cannot be below 0 and is booked as is.
    ///      One pricer call covers every option and every spot asset of the submit, so the pricer can reject unused
    ///      feed items; no call is made when nothing needs a price.
    function _bookPriced(DeriveRecord.Record[] memory recs, uint256 total, bytes memory feeds, Book memory book)
        private
        view
    {
        uint256 n = recs.length;
        bool[] memory needs = new bool[](n);
        address[] memory spotAssets = new address[](_deriveAssets.length);
        uint256 ns;
        for (uint256 i; i < n; ++i) {
            needs[i] = recs[i].options.length != 0 || _hasDebt(recs[i]);
            if (needs[i]) ns = _addSpotAssets(recs[i], spotAssets, ns);
        }

        int256[] memory v;
        uint256[] memory spots;
        if (total != 0 || ns != 0) {
            DeriveRecord.Option[] memory all = new DeriveRecord.Option[](total);
            uint256 k;
            for (uint256 i; i < n; ++i) {
                for (uint256 j; j < recs[i].options.length; ++j) {
                    all[k++] = recs[i].options[j];
                }
            }
            assembly ("memory-safe") {
                mstore(spotAssets, ns)
            }
            (v, spots) = PRICER.values(feeds, all, spotAssets);
        }

        uint256 at;
        for (uint256 i; i < n; ++i) {
            if (!needs[i]) {
                _addCollateral(recs[i], book);
                continue;
            }
            _addEquity(recs[i], v, at, spotAssets, spots, book);
            at += recs[i].options.length;
        }
    }

    function _hasDebt(DeriveRecord.Record memory rec) private pure returns (bool) {
        for (uint256 c; c < rec.collateral.length; ++c) {
            if (rec.collateral[c].balance < 0) return true;
        }
        return false;
    }

    /// @dev Appends to `assets` (length `ns`) each non-cash mapped asset `rec` holds a non-zero balance of, once.
    function _addSpotAssets(DeriveRecord.Record memory rec, address[] memory assets, uint256 ns)
        private
        view
        returns (uint256)
    {
        for (uint256 c; c < rec.collateral.length; ++c) {
            DeriveRecord.Collateral memory col = rec.collateral[c];
            address token = tokenOf[col.asset];
            if (col.balance == 0 || token == address(0) || token == CASH_TOKEN) continue;
            uint256 j;
            while (j < ns && assets[j] != col.asset) ++j;
            if (j == ns) assets[ns++] = col.asset;
        }
        return ns;
    }

    /// @dev Books one subaccount from its equity in USD (12 decimals): cash at 1, every other collateral asset at its
    ///      signed spot, long options at their value, short options and debt at theirs rounded up. The equity must be
    ///      at least 0. It is booked as credit-only legs worth at most the equity, in this order:
    ///      1. each non-cash asset with a positive balance stays in its own units;
    ///      2. cash, options and debts (including a non-cash debt, at spot rounded up) net into {CASH_TOKEN};
    ///      3. if that net is negative, the non-cash legs shrink by the shortfall, in record order, each by the units
    ///         worth it at spot, rounded up (against the fund).
    ///      The subaccount's own non-cash legs bear its own debt: they are never reduced by another subaccount's cash.
    function _addEquity(
        DeriveRecord.Record memory rec,
        int256[] memory v,
        uint256 from,
        address[] memory spotAssets,
        uint256[] memory spots,
        Book memory book
    ) private view {
        uint256 cashSlot = _slot(book, CASH_TOKEN); // written even at zero: the subaccount was priced
        int256 net; // cash, options and debts, USD
        uint256 nonCash; // positive non-cash collateral, USD rounded down
        for (uint256 j; j < rec.options.length; ++j) {
            net += v[from + j];
        }
        for (uint256 c; c < rec.collateral.length; ++c) {
            DeriveRecord.Collateral memory col = rec.collateral[c];
            address token = tokenOf[col.asset];
            if (token == address(0)) {
                if (col.balance == 0) continue;
                revert UnmappedAsset(rec.subaccountId, col.asset);
            }
            if (token == CASH_TOKEN) {
                net += col.balance;
                continue;
            }
            if (col.balance != 0) {
                uint256 spot = _spotOf(rec, col.asset, spotAssets, spots);
                if (col.balance > 0) nonCash += _usd(col.balance, spot, false);
                else net -= _toInt(_usd(col.balance, spot, true));
            }
        }

        uint256 shortfall;
        if (net < 0) {
            shortfall = _toUint(-net);
            if (shortfall > nonCash) revert NegativeEquity(rec.subaccountId);
        } else {
            book.credit[cashSlot] += _toUint(net);
        }

        for (uint256 c; c < rec.collateral.length; ++c) {
            DeriveRecord.Collateral memory col = rec.collateral[c];
            address token = tokenOf[col.asset];
            if (token == address(0) || token == CASH_TOKEN) continue;
            uint256 slot = _slot(book, token); // written even at zero
            if (col.balance <= 0) continue;
            uint256 units = _toUint(col.balance);
            if (shortfall != 0) {
                uint256 spot = _spotOf(rec, col.asset, spotAssets, spots);
                uint256 take = Math.min(shortfall, _usd(col.balance, spot, false));
                units -= Math.mulDiv(take, 1e18, spot, Math.Rounding.Ceil);
                shortfall -= take;
            }
            book.credit[slot] += units;
        }
    }

    /// @dev `balance`'s USD value at `spot` (1e18), 12 decimals: `|balance| × spot / 1e18`, rounded up or down.
    function _usd(int256 balance, uint256 spot, bool up) private pure returns (uint256) {
        return Math.mulDiv(_abs(balance), spot, 1e18, up ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @dev The verified spot the pricer returned for `asset`. Every non-zero non-cash balance of a priced
    ///      subaccount was requested, so a miss is a pricer fault, refused as an unpriced asset.
    function _spotOf(DeriveRecord.Record memory rec, address asset, address[] memory spotAssets, uint256[] memory spots)
        private
        pure
        returns (uint256)
    {
        for (uint256 j; j < spotAssets.length; ++j) {
            if (spotAssets[j] == asset) return spots[j];
        }
        revert UnmappedAsset(rec.subaccountId, asset);
    }

    function _abs(int256 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _toUint(int256 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(x);
    }

    function _toInt(uint256 x) private pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(x);
    }

    /// @dev Every covered token, zero included (a zero must replace an earlier positive value of the same batch),
    ///      rounded down to the token's decimals.
    function _settle(Book memory book) private view returns (address[] memory assets, uint256[] memory values) {
        assets = new address[](book.count);
        values = new uint256[](book.count);
        for (uint256 t; t < book.count; ++t) {
            assets[t] = book.tokens[t];
            values[t] = _toTokenUnits(book.credit[t], _decimals[book.tokens[t]]);
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

    /// @dev Per-token credits of one submit, in Derive's 12 decimals (the cash token's are USD). Debts are netted per
    ///      subaccount before they reach the book, so there are no debits.
    struct Book {
        address account;
        address[] tokens;
        uint256[] credit;
        uint256 count;
    }

    function _newBook(address account) private pure returns (Book memory b) {
        b.account = account;
        b.tokens = new address[](MAX_TOKENS_PER_ACCOUNT);
        b.credit = new uint256[](MAX_TOKENS_PER_ACCOUNT);
    }

    /// @dev Index of `token` in `b`, added if new.
    function _slot(Book memory b, address token) private pure returns (uint256 t) {
        while (t < b.count && b.tokens[t] != token) ++t;
        if (t == b.count) {
            if (t == MAX_TOKENS_PER_ACCOUNT) revert TooManyAttestations(b.account, t + 1);
            b.tokens[b.count++] = token;
        }
    }

    /// @dev Credits `rec`'s collateral as is. A mapped asset is written even at a zero balance, so it replaces an
    ///      earlier positive value of the same batch. A negative balance is refused: only {_addEquity} values debt.
    function _addCollateral(DeriveRecord.Record memory rec, Book memory b) private view {
        for (uint256 c; c < rec.collateral.length; ++c) {
            DeriveRecord.Collateral memory col = rec.collateral[c];
            if (col.balance < 0) revert NegativeBalance(rec.subaccountId, col.asset);
            address token = tokenOf[col.asset];
            if (token == address(0)) {
                if (col.balance == 0) continue;
                revert UnmappedAsset(rec.subaccountId, col.asset);
            }
            b.credit[_slot(b, token)] += uint256(col.balance);
        }
    }

    /// @dev 12-decimal Derive amount → token units. Rounds down when the token has fewer decimals.
    function _toTokenUnits(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals >= _DERIVE_DECIMALS) return amount * 10 ** (decimals - _DERIVE_DECIMALS);
        return amount / 10 ** (_DERIVE_DECIMALS - decimals);
    }
}
