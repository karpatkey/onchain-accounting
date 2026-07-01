// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {SingleAssetAssistedGetters} from "src/balances/AssistedBalanceAdapters/SingleAssetAssistedGetters.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Stader Withdrawal Queue Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account from open requests in Stader's `UserWithdrawalManager`.
///         Requesting an unstake burns ETHx and records a sequential `requestId` owned by the account; until claimed,
///         the value lives as ETH owed by the manager and is invisible to a wallet/receipt-token scan. Rather than
///         enumerate `requestIdsByUserAddress` on-chain (griefable — anyone can `requestWithdraw(amount, _owner=victim)`
///         to bloat a victim's array past the probe cap), a trusted **wrapper contract** (holder of `SUBMITTER_ROLE` —
///         the {StaderWithdrawalQueueWrapper}) pushes the account's `requestId` via {submit} **atomically as it forwards
///         the withdrawal request**, so the id cache is kept current on-chain in the same transaction.
/// @dev Assisted-family adapter (ADR 0014 / 0015): the cache stores **only request ids, never amounts**, and every read
///      re-verifies ownership (`userWithdrawRequests(id).owner == account`) and re-values live, so a faulty or
///      compromised feeder can only under-report NAV, never over-report. Ownership + valuation come straight from the
///      `UserWithdrawalManager` public getters, which return a zeroed tuple for a claimed/unknown id (owner deleted on
///      claim) rather than reverting — no enumeration, no OOB-sentinel handling. Denominated in `UNDERLYING_TOKEN`
///      (WETH): the claim pays native ETH whose amount is fixed at finalization, so NAV prices it via ETH/USD and an
///      ETHx exchange-rate move can't mis-value a queued claim. Emits ONE `Supplied` leg per owned cached request, all
///      sharing the static `positionId = abi.encode(address(USER_WITHDRAWAL_MANAGER))`; each leg's `isLocked` reflects
///      that request's state (finalized → `false`, pending → `true`) and its request id rides in the typed
///      `positionInstanceId` (`bytes32(requestId)`), never in `positionId`.
contract StaderWithdrawalQueueBalanceAdapter is AccessControl, SingleAssetAssistedGetters, IPositionDescribable {
    using EnumerableSet for EnumerableSet.UintSet;

    //
    // Roles
    //

    /// @notice Role allowed to feed the adapter by submitting/removing request ids (held by the wrapper contract).
    bytes32 public constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

    //
    // Constants
    //

    /// @notice Hard cap on cached request ids per account. `_owedAmount` / `getAdapterPositions` iterate the whole set
    ///         on every NAV read, and an OOG there is NOT caught by NAVCalculator's try/catch — a bloated cache would
    ///         brick the account's NAV scan. Bounding the cache at submit time keeps the read gas-bounded; the wrapper
    ///         GCs claimed ids via {remove}. A real account never approaches 256 open requests.
    uint256 public constant MAX_REQUESTS = 256;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.STADER;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.STADER;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.STADER_WITHDRAWAL;

    //
    // State
    //

    /// @notice Stader UserWithdrawalManager contract (source of ownership + per-request data).
    IUserWithdrawalManager public immutable USER_WITHDRAWAL_MANAGER;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Candidate request ids cached per account (the only thing the wrapper supplies). An
    ///         `EnumerableSet.UintSet` gives dedup, O(1) membership/removal, and `values()` enumeration.
    mapping(address account => EnumerableSet.UintSet) private _requestIds;

    event RequestIdSubmitted(address indexed account, uint256 indexed requestId);
    event RequestIdCleared(address indexed account, uint256 indexed requestId);
    event AccountCleared(address indexed account);

    //
    // Constructor
    //

    /// @param userWithdrawalManager_ Address of Stader's UserWithdrawalManager contract. Must be a contract.
    /// @param underlyingToken_       Address of the asset positions are denominated in (WETH).
    /// @param navCalculator_         The NAVCalculator address used for asset-registry filtering. Must be a contract.
    /// @param admin_                 Holder of `DEFAULT_ADMIN_ROLE` (administers `SUBMITTER_ROLE`). Required.
    /// @param submitter_             Initial holder of `SUBMITTER_ROLE` — the {StaderWithdrawalQueueWrapper}. Optional
    ///                               (pass `address(0)` and grant after the wrapper is deployed, since the wrapper needs
    ///                               this adapter's address at construction).
    constructor(
        address userWithdrawalManager_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address submitter_
    ) SingleAssetAssistedGetters(underlyingToken_) {
        if (userWithdrawalManager_ == address(0) || admin_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(userWithdrawalManager_, "UserWithdrawalManager");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        USER_WITHDRAWAL_MANAGER = IUserWithdrawalManager(userWithdrawalManager_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (submitter_ != address(0)) _grantRole(SUBMITTER_ROLE, submitter_);
    }

    //
    // Writes (SUBMITTER_ROLE)
    //

    /// @notice Track `requestId` for `account` (idempotent). Called by the wrapper right after it forwards a
    ///         `requestWithdraw` that created the request. **Reverts** `NotTokenOwner` if `requestId` is not currently
    ///         owned by `account`, and `TokenIdCacheFull` if a new id would grow the set past {MAX_REQUESTS}.
    /// @dev Re-submitting an already-cached id is a no-op (no cap/ownership re-check, no event).
    function submit(address account, uint256 requestId) external onlyRole(SUBMITTER_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        EnumerableSet.UintSet storage set = _requestIds[account];
        if (set.contains(requestId)) return; // idempotent — nothing to validate or emit
        if (set.length() >= MAX_REQUESTS) revert TokenIdCacheFull(account, MAX_REQUESTS);
        (address owner,) = _ownerOf(requestId);
        if (owner != account) revert NotTokenOwner(account, requestId);
        set.add(requestId);
        emit RequestIdSubmitted(account, requestId);
    }

    //
    // Writes (permissionless — GC of provably-stale ids)
    //

    /// @notice Stop tracking `requestId` for `account` — but **only if** it is no longer owned by `account` (claimed —
    ///         the manager deletes the request, so its owner reads back as `address(0)`). Permissionless: it can only
    ///         *remove* an id, and only one that fails the live ownership check, so no live position can ever be
    ///         deleted. This is the cleanup path for a `claim` executed *outside* the wrapper's `SUBMITTER_ROLE`
    ///         context — a Stader `claim` delegatecalled by the owning Safe (which does not hold `SUBMITTER_ROLE`).
    /// @dev **Reverts** `NotTokenOwner` if `requestId` is still owned by `account` (nothing to remove) so a mistaken
    ///      call is loud rather than silently dropping a live position. Idempotent for an already-absent id.
    function remove(address account, uint256 requestId) external {
        (address owner, bool live) = _ownerOf(requestId);
        if (live && owner == account) revert NotTokenOwner(account, requestId);
        if (_requestIds[account].remove(requestId)) emit RequestIdCleared(account, requestId);
    }

    /// @notice Drop all cached request ids for `account`. Admin-gated rescue (e.g. to reset a mis-fed account); the
    ///         normal path is the wrapper's per-request {submit} / stale-{remove}.
    function clearAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EnumerableSet.UintSet storage set = _requestIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
        emit AccountCleared(account);
    }

    //
    // Reads
    //

    /// @notice Candidate request ids currently cached for `account` (display/debug; not ownership-filtered).
    function requestIdsOf(address account) external view returns (uint256[] memory) {
        return _requestIds[account].values();
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "Stader";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "ETHx"]` — category + the receipt-token symbol (matching the sibling queues). All
    ///      requests share the queue `positionId`; the per-request sequential id is the typed `positionInstanceId` on
    ///      each leg, NOT a label.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "ETHx";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns ONE ETH-denominated `Supplied` leg per owned cached request, all sharing the static
    ///         `positionId = abi.encode(address(USER_WITHDRAWAL_MANAGER))`. Each leg's `isLocked` reflects that
    ///         request's state (finalized → `false`, pending → `true`) and its request id is the typed
    ///         `positionInstanceId`.
    /// @dev Each cached id is valued live (`_owedForRequest`), re-verifying ownership every read: requests not owned by
    ///      `account` / claimed value to 0 and emit no leg — the wrapper can only under-report. Zero-amount legs are
    ///      skipped. The legs sum to `_owedAmount`'s total. Dropped entirely if the underlying asset is not registered
    ///      in NAVCalculator.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        uint256[] memory ids = _requestIds[account].values();
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        (INAVCalculator.Asset memory underlying, bool registered) = RegisteredAssetLib.find(reg, UNDERLYING_TOKEN);
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        bytes memory positionId = abi.encode(address(USER_WITHDRAWAL_MANAGER));
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](ids.length);
        uint256 n;
        for (uint256 i = 0; i < ids.length; i++) {
            (uint256 amount, bool finalized) = _owedForRequest(account, ids[i]);
            if (amount == 0) {
                continue;
            }
            temp[n++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: amount,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: !finalized,
                positionInstanceId: bytes32(ids[i])
            });
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
    }

    //
    // Internal — valuation
    //

    /// @inheritdoc SingleAssetAssistedGetters
    /// @dev Total ETH owed across the account's cached request ids, valued from live on-chain reads. Never reverts.
    function _owedAmount(address account) internal view override returns (uint256 total) {
        uint256[] memory ids = _requestIds[account].values();
        for (uint256 i; i < ids.length; ++i) {
            (uint256 amount,) = _owedForRequest(account, ids[i]);
            total += amount;
        }
    }

    /// @dev ETH owed for a single request and whether it is finalized (claimable). `amount` is 0 if the request is not
    ///      owned by `account` (claimed → owner deleted to `address(0)`, or transferred/never-owned). Mirrors the
    ///      manager's own accounting: finalized (`ethFinalized > 0`) → the exact `ethFinalized`; pending → the
    ///      rate-converted `ethExpected` estimate at request time.
    function _owedForRequest(address account, uint256 requestId)
        internal
        view
        returns (uint256 amount, bool finalized)
    {
        (address owner,, uint256 ethExpected, uint256 ethFinalized,) =
            USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);
        if (owner != account) return (0, false);
        if (ethFinalized > 0) return (ethFinalized, true);
        return (ethExpected, false);
    }

    /// @dev The request's current owner and whether it is live (owner != 0). A claimed request has its storage entry
    ///      deleted by the manager, so `owner` reads back as `address(0)`; the public getter never reverts.
    function _ownerOf(uint256 requestId) internal view returns (address owner, bool live) {
        (address o,,,,) = USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);
        return (o, o != address(0));
    }
}

/// @notice Minimal interface for Stader's UserWithdrawalManager.
/// @dev Mirrors the Solidity-auto-generated getter for the public mapping used by the adapter.
interface IUserWithdrawalManager {
    /// @notice Returns the per-request `UserWithdrawInfo` tuple for a given request id.
    /// @return owner Owner of the request (zero after a successful claim).
    /// @return ethXAmount Amount of ETHx originally burned to create the request.
    /// @return ethExpected Estimated ETH owed at request time (rate-converted).
    /// @return ethFinalized Exact ETH owed once the batch is finalized; zero before finalization.
    /// @return requestBlock Block at which the request was created.
    function userWithdrawRequests(uint256 requestId)
        external
        view
        returns (address owner, uint256 ethXAmount, uint256 ethExpected, uint256 ethFinalized, uint256 requestBlock);
}
