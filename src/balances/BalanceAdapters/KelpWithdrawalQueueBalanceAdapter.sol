// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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
///      pending claim on the manager. This adapter surfaces it: for every asset Kelp supports it emits up
///      to two positions under a single static positionId (`abi.encode(withdrawalManager)`) — a claimable
///      leg (`isLocked = false`) and a locked/pending leg (`isLocked = true`). The payout asset lives in
///      `balanceAsset.asset` (so it is not duplicated in the positionId); legs are told apart by
///      `balanceAsset.asset` + `isLocked`. A request counts as
///      claimable only once the asset's lock cursor has passed the nonce AND the block delay has elapsed
///      (both gates, matching `completeWithdrawal`). The balance methods report the per-asset summed
///      total. The supported-asset set is discovered at runtime from
///      `lrtConfig().getSupportedAssetList()` rather than hardcoded, mirroring the dynamic-discovery
///      pattern in `AaveUmbrellaBalanceAdapter.sol`.
contract KelpWithdrawalQueueBalanceAdapter is IBalanceAdapter, IPositionDescribable {
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

    /// @notice Looks up `asset` in a pre-fetched NAVCalculator registered-asset set.
    /// @dev Pure in-memory search: the caller fetches `getRegisteredAssets()` once and reuses it
    ///      across every supported asset, rather than re-fetching per lookup (cf. `AaveUmbrella`).
    /// @return found Whether the asset is registered (and therefore priced) in NAV.
    /// @return info The registered Asset tuple (zeroed if not found).
    function _findRegisteredAsset(INAVCalculator.Asset[] memory reg, address asset)
        internal
        pure
        returns (bool found, INAVCalculator.Asset memory info)
    {
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) {
                return (true, reg[i]);
            }
        }
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

    function positionLabels(bytes calldata) external pure returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "rsETH Withdrawal Queue";
        return out;
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
    /// @notice Returns up to TWO positions PER asset under the static `positionId = abi.encode(withdrawalManager)` —
    ///         one claimable (`isLocked = false`) and one locked/pending (`isLocked = true`).
    /// @dev All legs share `positionId = abi.encode(withdrawalManager)`; the payout asset is in `balanceAsset.asset`,
    ///      so legs are distinguished by `balanceAsset.asset` + `isLocked` (the asset is not duplicated in positionId).
    ///      For each supported+registered asset, the account's open requests are aggregated into two sums: a request
    ///      is claimable (feeds the claimable leg) only when BOTH gates pass: the asset's lock cursor has advanced
    ///      past its nonce (`userNonce < nextLockedNonce(asset)`) AND the per-request block delay has elapsed
    ///      (`block.number >= withdrawalStartBlock + withdrawalDelayBlocks()`) — matching `LRTWithdrawalManager`'s own
    ///      `completeWithdrawal` checks. Either gate failing → pending (locked leg). The two legs per asset sum to
    ///      `_owedForAsset`'s total for that asset. A zero-amount leg is omitted. Only assets registered in
    ///      NAVCalculator (and matching `assetFilter`, if set) are emitted.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }

        address[] memory supported = _supportedAssets();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        uint256 delayBlocks = WITHDRAWAL_MANAGER.withdrawalDelayBlocks();

        uint256 nAssets = supported.length;
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2 * nAssets);
        uint256 n;
        for (uint256 a = 0; a < nAssets; a++) {
            address asset = supported[a];
            if (assetFilter != address(0) && assetFilter != asset) {
                continue;
            }
            (bool registered, INAVCalculator.Asset memory underlying) = _findRegisteredAsset(reg, asset);
            if (!registered) {
                continue;
            }
            (uint128 begin, uint128 end) = WITHDRAWAL_MANAGER.userAssociatedNonces(asset, account);
            uint256 c = end - begin;
            if (c == 0) {
                continue;
            }
            if (c > MAX_REQUESTS_PROBED) {
                c = MAX_REQUESTS_PROBED;
            }
            uint256 cursor = WITHDRAWAL_MANAGER.nextLockedNonce(asset);

            uint256 claimable;
            uint256 locked;
            for (uint256 i = 0; i < c; i++) {
                (, uint256 owed, uint256 startBlock, uint256 userNonce) =
                    WITHDRAWAL_MANAGER.getUserWithdrawalRequest(asset, account, i);
                if (owed == 0) {
                    continue;
                }
                // Claimable only when the lock cursor has passed AND the block delay has elapsed.
                bool unlocked = (userNonce < cursor) && (block.number >= startBlock + delayBlocks);
                if (unlocked) {
                    claimable += owed;
                } else {
                    locked += owed;
                }
            }

            // Static positionId = the WithdrawalManager (the immutable anchor). The payout asset is already in
            // `balanceAsset.asset` (part of the identity key), so it is NOT duplicated in the positionId; the two
            // legs per asset are told apart by `balanceAsset.asset` + `isLocked`.
            bytes memory positionId = abi.encode(address(WITHDRAWAL_MANAGER));
            if (claimable > 0) {
                temp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: underlying,
                    balanceAdapter: address(this),
                    amount: claimable,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: positionId,
                    positionKind: PositionKind.Supplied,
                    isLocked: false
                });
            }
            if (locked > 0) {
                temp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: underlying,
                    balanceAdapter: address(this),
                    amount: locked,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: positionId,
                    positionKind: PositionKind.Supplied,
                    isLocked: true
                });
            }
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
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
