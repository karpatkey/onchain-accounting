// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Kelp DAO rsETH Withdrawal Queue Balance Adapter
/// @author KPK
/// @notice Reports assets owed to an account from open requests in Kelp DAO's rsETH exit queue
///         (the `LRTWithdrawalManager`).
/// @dev When a user unstakes rsETH, the rsETH is burned and a per-(asset, user) withdrawal request
///      is recorded denominated in the LST the user chose to receive (stETH, ETHx or native ETH).
///      Until claimed, that value is invisible to wallet/receipt-token adapters — it only lives as a
///      pending claim on the manager. This adapter surfaces it: for every asset Kelp supports it emits
///      **one position per open request** under a single static positionId (`abi.encode(withdrawalManager)`),
///      valued at the request's `expectedAssetAmount`. The payout asset lives in `balanceAsset.asset` (so it
///      is not duplicated in the positionId); each request's `isLocked` reflects its own state — `false` for a
///      claimable request, `true` for a locked/pending one — and its stable `userNonce` rides in the last
///      `labels` entry (`["rsETH Withdrawal Queue", "Request #<userNonce>"]`), never in `positionId` (multiple
///      requests share the static positionId and are distinguished for display by their labels). A request
///      counts as claimable only once the asset's lock cursor has passed the nonce AND the block delay has
///      elapsed (both gates, matching `completeWithdrawal`). The balance methods report the per-asset summed
///      total. The supported-asset set is discovered at runtime from
///      `lrtConfig().getSupportedAssetList()` rather than hardcoded, mirroring the dynamic-discovery
///      pattern in `AaveUmbrellaBalanceAdapter.sol`.
contract KelpWithdrawalQueueBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    using Strings for uint256;

    //
    // Constants
    //

    /// @notice Hard cap on the number of open requests summed per (asset, account).
    /// @dev Bounds gas so a pathological account with many open requests can't make NAV reads run
    ///      out of gas (an out-of-gas revert is NOT caught by NAVCalculator's try/catch, so it would
    ///      DoS the whole NAV call). Mirrors `StaderWithdrawalQueue` and the queue-family note in
    ///      `docs/roadmap/balance-adapter-coverage.md`. In practice an account never has more than a
    ///      handful of pending requests per asset.
    uint256 public constant MAX_REQUESTS_PROBED = 256;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.KELP_WITHDRAWAL;

    //
    // State
    //

    /// @notice Kelp DAO LRTWithdrawalManager contract (the rsETH exit queue).
    ILRTWithdrawalManager public immutable WITHDRAWAL_MANAGER;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param withdrawalManager_ Address of Kelp's LRTWithdrawalManager contract.
    /// @param navCalculator_ The NAVCalculator address used for asset-registry filtering.
    constructor(address withdrawalManager_, address navCalculator_) {
        if (withdrawalManager_ == address(0)) {
            revert InvalidArguments();
        }
        require(withdrawalManager_.code.length > 0, "WithdrawalManager must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WITHDRAWAL_MANAGER = ILRTWithdrawalManager(withdrawalManager_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Balance computation
    //

    /// @notice Sums the `expectedAssetAmount` across all of `account`'s open requests for `asset`.
    /// @dev `userAssociatedNonces` is the public getter of an OZ `DoubleEndedQueue.Uint256Deque`; the
    ///      number of open requests is `end - begin`. `getUserWithdrawalRequest(asset, account, i)`
    ///      resolves to the deque's `.at(i)` for `i ∈ [0, end-begin)` — claimed requests are popped
    ///      off the front, so this only ever counts live claims. No out-of-bounds probing is needed.
    ///      The scan is capped at `MAX_REQUESTS_PROBED` to bound gas (see that constant's NatSpec).
    function _owedForAsset(address asset, address account) internal view returns (uint256 total) {
        if (account == address(0)) {
            return 0;
        }

        (uint128 begin, uint128 end) = WITHDRAWAL_MANAGER.userAssociatedNonces(asset, account);
        uint256 count = end - begin;
        if (count > MAX_REQUESTS_PROBED) {
            count = MAX_REQUESTS_PROBED;
        }
        for (uint256 i = 0; i < count; i++) {
            (, uint256 expectedAssetAmount,,) = WITHDRAWAL_MANAGER.getUserWithdrawalRequest(asset, account, i);
            total += expectedAssetAmount;
        }
    }

    /// @notice Returns the set of assets Kelp's exit queue can pay out, discovered from LRTConfig.
    function _supportedAssets() internal view returns (address[] memory) {
        return ILRTConfig(WITHDRAWAL_MANAGER.lrtConfig()).getSupportedAssetList();
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _supportedAssets();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "Kelp DAO";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Withdrawal Queue", "rsETH"]` — category + the receipt-token symbol (matching the sibling queues). All
    ///      requests share the withdrawal-manager `positionId`; the per-request absolute `userNonce` is the typed
    ///      `positionInstanceId` on each leg, NOT a label.
    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](2);
        out[0] = "Withdrawal Queue";
        out[1] = "rsETH";
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        // No explicit supported-asset guard needed: for any asset this queue does not track, the
        // `userAssociatedNonces` deque is empty, so `_owedForAsset` returns 0.
        if (asset == address(0)) {
            return (0, false);
        }
        return (_owedForAsset(asset, account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        address[] memory supported = _supportedAssets();
        address[] memory tmpAssets = new address[](supported.length);
        uint256[] memory tmpAmounts = new uint256[](supported.length);
        uint256 count;

        for (uint256 i = 0; i < supported.length; i++) {
            uint256 owed = _owedForAsset(supported[i], account);
            if (owed > 0) {
                tmpAssets[count] = supported[i];
                tmpAmounts[count] = owed;
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
        }
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns ONE position PER open withdrawal request under the static
    ///         `positionId = abi.encode(withdrawalManager)`. Each leg's `isLocked` reflects that request's state
    ///         (claimable → `false`, pending → `true`) and its `userNonce` is the last `labels` entry.
    /// @dev All legs share `positionId = abi.encode(withdrawalManager)`; the payout asset is in `balanceAsset.asset`,
    ///      so it is not duplicated in the positionId. For each supported+registered asset, the account's open
    ///      requests are each emitted as a separate `Supplied` leg valued at `expectedAssetAmount`. A request is
    ///      claimable (`isLocked = false`) only when BOTH gates pass: the asset's lock cursor has advanced past its
    ///      nonce (`userNonce < nextLockedNonce(asset)`) AND the per-request block delay has elapsed
    ///      (`block.number >= withdrawalStartBlock + withdrawalDelayBlocks()`) — matching `LRTWithdrawalManager`'s own
    ///      `completeWithdrawal` checks. Either gate failing → pending (`isLocked = true`). The per-asset legs sum to
    ///      `_owedForAsset`'s total for that asset; across assets they sum to `getAdapterBalances`. The request id
    ///      (`userNonce`) rides in `labels` (display only), NOT in `positionId`. A zero-amount leg is omitted. Only
    ///      assets registered in NAVCalculator (and matching `assetFilter`, if set) are emitted.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Resolve `assetFilter` into a concrete asset list HERE, so the heavy build loop (delegated to
        // `buildPositionsSelf` via an external self-call) no longer carries `assetFilter` at the bottom of its stack
        // frame — that one extra slot was tipping the build over the via_ir stack limit.
        address[] memory supported = _supportedAssets();
        address[] memory assetsToProcess;
        if (assetFilter == address(0)) {
            assetsToProcess = supported;
        } else {
            bool isSupported;
            for (uint256 a = 0; a < supported.length; a++) {
                if (supported[a] == assetFilter) {
                    isSupported = true;
                    break;
                }
            }
            if (!isSupported) {
                return new INAVCalculator.PositionBalance[](0);
            }
            assetsToProcess = new address[](1);
            assetsToProcess[0] = assetFilter;
        }

        positions = this.buildPositionsSelf(account, assetsToProcess);
    }

    /// @notice Builds the per-request legs for `account` across the pre-filtered `assets`. Split out of
    ///         `getAdapterPositions` and reached via an external self-call so that `assetFilter` is NOT in this
    ///         frame's stack — without that, the build (sizing pre-pass + emission loop + per-leg struct) exceeds the
    ///         via_ir stack limit.
    /// @dev External (not internal) ON PURPOSE: an internal call inlines, re-merging the frames and re-introducing the
    ///      overflow. Guarded so only this contract can invoke it — it is an implementation detail, not a public API.
    function buildPositionsSelf(address account, address[] calldata assets)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        require(msg.sender == address(this), "self only");

        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        uint256 delayBlocks = WITHDRAWAL_MANAGER.withdrawalDelayBlocks();

        uint256 nAssets = assets.length;

        // Size the scratch array to the sum of per-asset open-request counts (each capped at MAX_REQUESTS_PROBED), an
        // upper bound on the number of legs (zero-amount requests drop below it). Cache each capped count so the
        // emission loop below does NOT re-read `userAssociatedNonces` per asset.
        uint256 cap;
        uint256[] memory counts = new uint256[](nAssets);
        for (uint256 a = 0; a < nAssets; a++) {
            (uint128 begin, uint128 end) = WITHDRAWAL_MANAGER.userAssociatedNonces(assets[a], account);
            uint256 c = end - begin;
            if (c > MAX_REQUESTS_PROBED) {
                c = MAX_REQUESTS_PROBED;
            }
            counts[a] = c;
            cap += c;
        }

        // Static positionId = the WithdrawalManager (the immutable anchor). The payout asset is already in
        // `balanceAsset.asset` (part of the identity key), so it is NOT duplicated in the positionId; per-request
        // legs are distinguished for display by their `userNonce` (in `positionInstanceId`).
        bytes memory positionId = abi.encode(address(WITHDRAWAL_MANAGER));
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](cap);
        uint256 n;
        for (uint256 a = 0; a < nAssets; a++) {
            if (counts[a] == 0) {
                continue;
            }
            address asset = assets[a];
            (INAVCalculator.Asset memory underlying, bool registered) = RegisteredAssetLib.find(reg, asset);
            if (!registered) {
                continue;
            }
            // Append this asset's per-request legs (extracted to keep this loop under the stack limit).
            // `counts[a]` (capped request count) is reused from the sizing pre-pass — no second nonce-range read.
            n = _appendAssetLegs(account, asset, underlying, counts[a], delayBlocks, positionId, temp, n);
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
    }

    /// @dev Appends one `Supplied` leg per open request of `(asset, account)` into `temp` (starting at `n`), returning
    ///      the new count. Mirrors the inner loop of `getAdapterPositions`; extracted so the outer per-asset scope
    ///      stays within the via_ir stack limit. `c` is the capped open-request count from the sizing pre-pass (reused
    ///      here rather than re-reading `userAssociatedNonces`); zero-amount requests are skipped.
    function _appendAssetLegs(
        address account,
        address asset,
        INAVCalculator.Asset memory underlying,
        uint256 c,
        uint256 delayBlocks,
        bytes memory positionId,
        INAVCalculator.PositionBalance[] memory temp,
        uint256 n
    ) private view returns (uint256) {
        uint256 cursor = WITHDRAWAL_MANAGER.nextLockedNonce(asset);

        for (uint256 i = 0; i < c; i++) {
            (, uint256 owed, uint256 startBlock, uint256 userNonce) =
                WITHDRAWAL_MANAGER.getUserWithdrawalRequest(asset, account, i);
            if (owed == 0) {
                continue;
            }
            // Claimable only when the lock cursor has passed AND the block delay has elapsed.
            bool unlocked = (userNonce < cursor) && (block.number >= startBlock + delayBlocks);
            temp[n++] = INAVCalculator.PositionBalance({
                balanceAsset: underlying,
                balanceAdapter: address(this),
                amount: owed,
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: !unlocked,
                positionInstanceId: bytes32(userNonce)
            });
        }
        return n;
    }
}

/// @notice Minimal interface for Kelp DAO's LRTWithdrawalManager (the rsETH exit queue).
interface ILRTWithdrawalManager {
    /// @notice Address of the LRTConfig that holds the supported-asset registry.
    function lrtConfig() external view returns (address);

    /// @notice Public getter of the per-(asset, user) `DoubleEndedQueue.Uint256Deque` of open nonces.
    /// @return begin Front index of the deque (advances as requests are claimed).
    /// @return end One-past-the-back index. Open-request count is `end - begin`.
    function userAssociatedNonces(address asset, address user) external view returns (uint128 begin, uint128 end);

    /// @notice Returns the `userIndex`-th open withdrawal request for `(asset, user)`.
    /// @param userIndex Relative index into the user's deque, `0 ..= (end - begin - 1)`.
    /// @return rsETHAmount rsETH burned to create the request.
    /// @return expectedAssetAmount Amount of `asset` the user will receive on claim (the owed value).
    /// @return withdrawalStartBlock Block at which the request was created.
    /// @return userNonce Absolute nonce of the request within the asset's queue.
    function getUserWithdrawalRequest(address asset, address user, uint256 userIndex)
        external
        view
        returns (uint256 rsETHAmount, uint256 expectedAssetAmount, uint256 withdrawalStartBlock, uint256 userNonce);

    /// @notice The asset's lock cursor: a request is unlocked by the cursor once `userNonce < nextLockedNonce(asset)`.
    /// @dev Advanced by the manager's `unlockQueue(asset)` as the unstaking vault accrues claimable assets.
    function nextLockedNonce(address asset) external view returns (uint256);

    /// @notice Global block delay that must elapse after `withdrawalStartBlock` before a request is claimable.
    /// @dev Second claimability gate alongside the lock cursor (both required), per `completeWithdrawal`.
    function withdrawalDelayBlocks() external view returns (uint256);
}

/// @notice Minimal interface for Kelp DAO's LRTConfig.
interface ILRTConfig {
    /// @notice The list of assets Kelp supports (and therefore can pay out from the exit queue).
    function getSupportedAssetList() external view returns (address[] memory);
}
