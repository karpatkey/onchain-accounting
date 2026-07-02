// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SingleAssetBalanceAdapterBase} from "../SingleAssetBalanceAdapterBase.sol";
import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Stader Withdrawal Queue Balance Adapter
/// @author KPK
/// @notice Reports the in-flight ETH owed to an account from open requests in Stader's `UserWithdrawalManager`.
/// @dev Requesting an unstake burns ETHx and records a `requestId` owned by the account; until claimed the value lives
///      as ETH owed by the manager and is invisible to a wallet/receipt-token scan. The claim pays **native ETH** whose
///      amount is fixed at finalization, so the position is denominated in `UNDERLYING_TOKEN` (native-ETH sentinel /
///      WETH), not ETHx. This adapter enumerates the account's LIVE requests **on-chain** via
///      `getRequestIdsByUser(account)` — Stader removes an id from that array on claim (swap-and-pop in
///      `deleteRequestId`), so it holds only un-claimed requests, and the protocol caps it at
///      `maxNonRedeemedUserRequestCount` (1000 on mainnet). It emits **one `Supplied` leg per open request**, all under
///      a single static `positionId = abi.encode(address(USER_WITHDRAWAL_MANAGER))`, with each request's `isLocked`
///      reflecting its own state (finalized → `false`, pending → `true`) and its request id in the typed
///      `positionInstanceId` (ephemeral — the entry is deleted on claim). The balance getters
///      (`getAdapterBalances`) report the summed total.
///
///      **On-chain enumeration vs. third-party injection.** `requestWithdraw(ethXAmount, _owner)` pulls the *caller's*
///      ETHx but records the request under an arbitrary `_owner` (claimable only by `_owner`). So anyone can plant a
///      request owned by this account by burning their own ETHx — but they donate that ETH to the account and cannot
///      recover it, so the injected value is **real, claimable, and self-funded** (equivalent to an airdrop, which the
///      wallet ERC20 adapter likewise reports). The residual is cache/gas bloat: the read loops the account's live
///      requests, each an external `userWithdrawRequests` read. {MAX_REQUESTS_PROBED} equals Stader's own
///      `maxNonRedeemedUserRequestCount` (1000), so a legitimate account is never skipped, but the flip side is that
///      the "> cap → skip" guard never engages within protocol rules — an attacker can, by donating real ETHx per
///      request, fill a victim's array toward 1000 and make every subsequent NAV read for that account pay up to ~1000
///      external reads. This is tolerated: NAV reads are async/off-chain (ADR 0017), the griefer permanently loses the
///      donated ETH, and no legit account is ever silently zeroed by a lower cap. A future Stader cap increase would
///      warrant a re-deploy with a gas-appropriate bound (the enumeration cannot both stay unbounded and OOG-safe).
contract StaderWithdrawalQueueBalanceAdapter is SingleAssetBalanceAdapterBase {
    //
    // Constants
    //

    /// @notice Hard cap on the number of open requests this adapter will read for an account.
    /// @dev Bounds gas: matches Stader's own `maxNonRedeemedUserRequestCount` (1000 on mainnet), so no legitimate
    ///      account is ever skipped (the protocol enforces `requestIdsByUserAddress[owner].length <= 1000`). An account
    ///      over the cap is reported as 0 rather than risking an out-of-gas revert in the NAV read (an OOG is NOT caught
    ///      by NAVCalculator's try/catch, so it would DoS the whole NAV call). Skipping (reporting 0) is the safe,
    ///      under-report direction.
    uint256 public constant MAX_REQUESTS_PROBED = 1000;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.STADER;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.STADER;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.STADER_WITHDRAWAL;

    //
    // State
    //

    /// @notice Stader UserWithdrawalManager contract (source of the per-account request list + per-request data).
    IUserWithdrawalManager public immutable USER_WITHDRAWAL_MANAGER;

    /// @notice Stader StaderStakePoolsManager — its `previewWithdraw` gives the LIVE ETH value of a request's burned
    ///         ETHx, used to cap a not-yet-finalized request's stale request-time estimate (see {_owedForRequest}).
    ///         Derived at construction from `USER_WITHDRAWAL_MANAGER.staderConfig().getStakePoolManager()`.
    IStaderStakePoolsManager public immutable STAKE_POOL_MANAGER;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param userWithdrawalManager_ Address of Stader's UserWithdrawalManager contract. Must be a contract.
    /// @param underlyingToken_       Address of the asset positions are denominated in — what Stader pays on claim
    ///        (native ETH; the ERC-7528 sentinel / WETH on mainnet). Must be non-zero.
    /// @param navCalculator_         The NAVCalculator address used for asset-registry filtering. Must be a contract.
    constructor(address userWithdrawalManager_, address underlyingToken_, address navCalculator_)
        SingleAssetBalanceAdapterBase(underlyingToken_)
    {
        if (userWithdrawalManager_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(userWithdrawalManager_, "UserWithdrawalManager");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        USER_WITHDRAWAL_MANAGER = IUserWithdrawalManager(userWithdrawalManager_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        // Derive the StakePoolManager (for the live pending-request cap) from Stader's own config graph. Immutable —
        // no extra constructor arg. requireContract fails loud if the graph doesn't resolve to a contract at deploy.
        address stakePoolManager =
            IStaderConfig(IUserWithdrawalManager(userWithdrawalManager_).staderConfig()).getStakePoolManager();
        AddressCheckLib.requireContract(stakePoolManager, "StakePoolManager");
        STAKE_POOL_MANAGER = IStaderStakePoolsManager(stakePoolManager);
    }

    //
    // Balance computation
    //

    /// @inheritdoc SingleAssetBalanceAdapterBase
    /// @dev Sums the ETH owed across `account`'s open (un-claimed) requests. Enumerates `getRequestIdsByUser` (live-only,
    ///      protocol-bounded to 1000) and values each via {_owedForRequest}. Over the cap → 0 (see {MAX_REQUESTS_PROBED}).
    function _owedAmount(address account) internal view override returns (uint256 total) {
        uint256[] memory ids = _liveRequestIds(account);
        for (uint256 i = 0; i < ids.length; i++) {
            (uint256 amount,) = _owedForRequest(account, ids[i]);
            total += amount;
        }
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns ONE ETH-denominated `Supplied` leg per open (un-claimed) request, all sharing the static
    ///         `positionId = abi.encode(address(USER_WITHDRAWAL_MANAGER))`. Each leg's `isLocked` reflects that
    ///         request's state (finalized → `false`, pending → `true`) and its request id is the typed
    ///         `positionInstanceId`.
    /// @dev Dropped entirely if the underlying asset is not registered in NAVCalculator, or if the account's open-request
    ///      count exceeds {MAX_REQUESTS_PROBED}. Zero-amount legs are skipped. The legs sum to {_owedAmount}'s total.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Asset-filter mismatch → no positions for this adapter.
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }

        uint256[] memory ids = _liveRequestIds(account);
        if (ids.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Underlying must be registered in NAVCalculator for the position to count in NAV.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        (INAVCalculator.Asset memory underlying, bool registered) = RegisteredAssetLib.find(reg, UNDERLYING_TOKEN);
        if (!registered) {
            return new INAVCalculator.PositionBalance[](0);
        }

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

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "Stader";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "ETHx"]` — category + the receipt-token symbol (matching the sibling queues). All
    ///      requests share the queue `positionId`; the per-request id is the typed `positionInstanceId`, NOT a label.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "ETHx";
    }

    //
    // Internal
    //

    /// @dev The account's LIVE (un-claimed) request ids, or an empty array if none / `account == 0` / the list exceeds
    ///      {MAX_REQUESTS_PROBED}. `getRequestIdsByUser` returns `requestIdsByUserAddress[account]`, which Stader keeps
    ///      pruned to only un-claimed requests (swap-and-pop on claim) and caps at 1000.
    function _liveRequestIds(address account) internal view returns (uint256[] memory ids) {
        if (account == address(0)) {
            return new uint256[](0);
        }
        ids = USER_WITHDRAWAL_MANAGER.getRequestIdsByUser(account);
        if (ids.length > MAX_REQUESTS_PROBED) {
            return new uint256[](0);
        }
    }

    /// @dev ETH owed for a single request and whether it is finalized. `amount` is 0 if not owned by `account` (a
    ///      claimed/unknown id reads back with `owner == address(0)`). Finalized (`ethFinalized > 0`) → exact
    ///      `ethFinalized`. Pending → the CONSERVATIVE min of the request-time estimate `ethExpected` and the LIVE
    ///      re-conversion of the burned ETHx (`previewWithdraw(ethXAmount)`): `ethExpected` is frozen at request time,
    ///      so a subsequent ETHx/ETH rate drop (slashing / exit penalty) would leave it overstating the true owed
    ///      amount until finalization — the cap tracks the live rate down (mirrors the Lido adapter's `_cappedOwed`).
    function _owedForRequest(address account, uint256 requestId)
        internal
        view
        returns (uint256 amount, bool finalized)
    {
        (address owner, uint256 ethXAmount, uint256 ethExpected, uint256 ethFinalized,) =
            USER_WITHDRAWAL_MANAGER.userWithdrawRequests(requestId);
        if (owner != account) return (0, false);
        if (ethFinalized > 0) return (ethFinalized, true);
        return (_cappedPending(ethXAmount, ethExpected), false);
    }

    /// @dev Conservative value for a not-yet-finalized request: `min(ethExpected, previewWithdraw(ethXAmount))`.
    ///      Fail-open — if the live re-conversion reverts, fall back to `ethExpected` (the prior behaviour), so a
    ///      StakePoolManager hiccup can never revert the read.
    function _cappedPending(uint256 ethXAmount, uint256 ethExpected) internal view returns (uint256) {
        try STAKE_POOL_MANAGER.previewWithdraw(ethXAmount) returns (uint256 live) {
            return live < ethExpected ? live : ethExpected;
        } catch {
            return ethExpected;
        }
    }
}

/// @notice Minimal interface for Stader's UserWithdrawalManager.
interface IUserWithdrawalManager {
    /// @notice The list of ongoing (un-claimed) withdraw request ids for `owner`. Pruned on claim (swap-and-pop) and
    ///         capped by the protocol at `maxNonRedeemedUserRequestCount`.
    function getRequestIdsByUser(address owner) external view returns (uint256[] memory requestIds);

    /// @notice The StaderConfig contract (the protocol's address registry).
    function staderConfig() external view returns (address);

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

/// @notice Minimal interface for Stader's StaderConfig (address registry) — only the getter this adapter needs.
interface IStaderConfig {
    function getStakePoolManager() external view returns (address);
}

/// @notice Minimal interface for Stader's StaderStakePoolsManager — the live ETHx→ETH re-conversion used to cap a
///         pending request's stale request-time estimate.
interface IStaderStakePoolsManager {
    /// @notice Current ETH value of `ethXAmount` ETHx (ERC4626-style preview at the live exchange rate).
    function previewWithdraw(uint256 ethXAmount) external view returns (uint256);
}
