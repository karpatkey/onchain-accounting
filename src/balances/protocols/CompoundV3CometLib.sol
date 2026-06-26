// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

interface ICompoundRewards {
    /// @notice Some chains return a 4th `multiplier` value; the adapter detects via `data.length`.
    function rewardConfig(address comet) external view returns (address token, uint64 rescaleFactor, bool shouldUpscale);

    function rewardsClaimed(address comet, address src) external view returns (uint256);
}

interface CometExtInterface {
    function collateralBalanceOf(address account, address asset) external view returns (uint256);

    function getAssetInfo(uint8 i)
        external
        view
        returns (
            uint8 offset,
            address asset,
            address priceFeed,
            uint64 scale,
            uint64 borrowCollateralFactor,
            uint64 liquidateCollateralFactor,
            uint64 liquidationFactor,
            uint128 supplyCap
        );

    function numAssets() external view returns (uint8);

    function userBasic(address account)
        external
        view
        returns (
            int104 principal,
            uint64 baseTrackingIndex,
            uint64 baseTrackingAccrued,
            uint16 assetsIn,
            uint8 reserved
        );

    function totalsBasic()
        external
        view
        returns (
            uint64 baseSupplyIndex,
            uint64 baseBorrowIndex,
            uint64 trackingSupplyIndex,
            uint64 trackingBorrowIndex,
            uint104 totalSupplyBase,
            uint104 totalBorrowBase,
            uint40 lastAccrualTime,
            uint8 pauseFlags
        );

    function baseScale() external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint256);
    function getBorrowRate(uint256 utilization) external view returns (uint256);
    function baseMinForRewards() external view returns (uint256);
    function baseTrackingSupplySpeed() external view returns (uint256);
    function baseTrackingBorrowSpeed() external view returns (uint256);
    function trackingIndexScale() external view returns (uint256);
}

interface CometInterface {
    function baseToken() external view returns (address);
}

/// @title CompoundV3CometLib
/// @author KPK
/// @notice Shared read math for the Compound V3 meta-adapter. Given a Comet (market), the chain's CometRewards,
///         the expected reward token, and an account, it returns the account's base supply/borrow (present value
///         with interest accrued to `block.timestamp`), every collateral balance, and the unclaimed reward amount.
/// @dev Ports `CompoundV3Comet`'s base-accrual + reward-accrual math verbatim, parameterized by the comet so one
///      stateless library serves every market (the per-comet adapter snapshotted collaterals + the accrual
///      descale factor at construction; here they are derived per call). Mirrors the per-comet adapter
///      leg-for-leg (parity fork-tested).
library CompoundV3CometLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    int64 internal constant BASE_INDEX_SCALE = 1e15;
    uint64 internal constant FACTOR_SCALE = 1e18;
    uint64 internal constant BASE_ACCRUAL_SCALE = 1e6;

    /// @notice Everything needed to build an account's positions in one Comet.
    struct AccountData {
        address baseToken;
        int256 baseNet; // >0 supply, <0 borrow, in base-token units
        address[] collateralAssets;
        uint256[] collateralBalances;
        uint256 rewardOwed;
    }

    /// @notice The deduplicated set of assets a comet can report: base + collaterals + reward token.
    function supportedAssets(address comet, address rewardToken) internal view returns (address[] memory) {
        uint8 n = CometExtInterface(comet).numAssets();
        address[] memory tmp = new address[](uint256(n) + 2);
        uint256 m;
        tmp[m++] = CometInterface(comet).baseToken();
        for (uint8 i = 0; i < n; i++) {
            (, address asset,,,,,,) = CometExtInterface(comet).getAssetInfo(i);
            bool seen = false;
            for (uint256 j = 0; j < m; j++) {
                if (tmp[j] == asset) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tmp[m++] = asset;
        }
        bool rewardSeen = false;
        for (uint256 j = 0; j < m; j++) {
            if (tmp[j] == rewardToken) {
                rewardSeen = true;
                break;
            }
        }
        if (!rewardSeen) tmp[m++] = rewardToken;

        address[] memory out = new address[](m);
        for (uint256 i = 0; i < m; i++) {
            out[i] = tmp[i];
        }
        return out;
    }

    /// @notice Reads an account's full position in `comet` (base net, collaterals, unclaimed reward).
    function accountData(address comet, address rewards, address rewardToken, address account)
        internal
        view
        returns (AccountData memory d)
    {
        d.baseToken = CometInterface(comet).baseToken();
        d.baseNet = baseUnderlying(comet, account);

        uint8 n = CometExtInterface(comet).numAssets();
        address[] memory ca = new address[](n);
        uint256[] memory cb = new uint256[](n);
        uint256 m;
        for (uint8 i = 0; i < n; i++) {
            (, address asset,,,,,,) = CometExtInterface(comet).getAssetInfo(i);
            bool seen = false;
            for (uint256 j = 0; j < m; j++) {
                if (ca[j] == asset) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            ca[m] = asset;
            cb[m] = CometExtInterface(comet).collateralBalanceOf(account, asset);
            m++;
        }
        d.collateralAssets = new address[](m);
        d.collateralBalances = new uint256[](m);
        for (uint256 i = 0; i < m; i++) {
            d.collateralAssets[i] = ca[i];
            d.collateralBalances[i] = cb[i];
        }

        d.rewardOwed = rewardOwed(comet, rewards, rewardToken, account);
    }

    //
    // Base-token math (present value of supply/borrow with current accrual)
    //

    function baseUnderlying(address comet, address account) internal view returns (int256) {
        (int104 principal,,,,) = CometExtInterface(comet).userBasic(account);
        (,, uint64 baseSupplyIndex, uint64 baseBorrowIndex) = _accrue(comet);
        int256 total = principal >= 0
            ? int256(principal) * uint256(baseSupplyIndex).toInt256()
            : int256(principal) * uint256(baseBorrowIndex).toInt256();
        return total / BASE_INDEX_SCALE;
    }

    function _accrue(address comet)
        private
        view
        returns (uint64 trackingSupplyIndex, uint64 trackingBorrowIndex, uint64 baseSupplyIndex, uint64 baseBorrowIndex)
    {
        uint104 totalSupplyBase;
        uint104 totalBorrowBase;
        uint40 lastAccrualTime;
        (
            baseSupplyIndex,
            baseBorrowIndex,
            trackingSupplyIndex,
            trackingBorrowIndex,
            totalSupplyBase,
            totalBorrowBase,
            lastAccrualTime,
        ) = CometExtInterface(comet).totalsBasic();

        uint40 now_ = _safeNow();
        uint256 timeElapsed = uint256(now_ - lastAccrualTime);
        if (timeElapsed == 0) return (trackingSupplyIndex, trackingBorrowIndex, baseSupplyIndex, baseBorrowIndex);

        uint256 utilization = CometExtInterface(comet).getUtilization();
        uint256 supplyRate = CometExtInterface(comet).getSupplyRate(utilization);
        uint256 borrowRate = CometExtInterface(comet).getBorrowRate(utilization);
        baseSupplyIndex += _mulFactor(baseSupplyIndex, supplyRate * timeElapsed).toUint64();
        baseBorrowIndex += _mulFactor(baseBorrowIndex, borrowRate * timeElapsed).toUint64();

        uint256 baseMinForRewards = CometExtInterface(comet).baseMinForRewards();
        if (totalSupplyBase >= baseMinForRewards) {
            trackingSupplyIndex += _divBaseWei(
                    comet, CometExtInterface(comet).baseTrackingSupplySpeed() * timeElapsed, totalSupplyBase
                ).toUint64();
        }
        if (totalBorrowBase >= baseMinForRewards) {
            trackingBorrowIndex += _divBaseWei(
                    comet, CometExtInterface(comet).baseTrackingBorrowSpeed() * timeElapsed, totalBorrowBase
                ).toUint64();
        }
    }

    //
    // Reward math (unclaimed reward = accrued − claimed)
    //

    function rewardOwed(address comet, address rewards, address rewardToken, address account)
        internal
        view
        returns (uint256)
    {
        (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier) = _rewardConfig(comet, rewards);
        if (token == address(0) || token != rewardToken) return 0;

        uint256 claimed = ICompoundRewards(rewards).rewardsClaimed(comet, account);
        uint256 accrued = _rewardAccrued(comet, account, shouldUpscale, rescaleFactor, multiplier);
        if (accrued > claimed) {
            unchecked {
                return accrued - claimed;
            }
        }
        return 0;
    }

    function _rewardConfig(address comet, address rewards)
        private
        view
        returns (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier)
    {
        (bool ok, bytes memory data) =
            rewards.staticcall(abi.encodeWithSelector(ICompoundRewards.rewardConfig.selector, comet));
        if (!ok) return (address(0), 0, false, FACTOR_SCALE);
        if (data.length == 96) {
            (token, rescaleFactor, shouldUpscale) = abi.decode(data, (address, uint64, bool));
            return (token, rescaleFactor, shouldUpscale, FACTOR_SCALE);
        }
        if (data.length == 128) {
            return abi.decode(data, (address, uint64, bool, uint256));
        }
        return (address(0), 0, false, FACTOR_SCALE);
    }

    function _rewardAccrued(
        address comet,
        address account,
        bool shouldUpscale,
        uint64 rescaleFactor,
        uint256 multiplier
    ) private view returns (uint256) {
        (uint64 trackingSupplyIndex, uint64 trackingBorrowIndex,,) = _accrue(comet);
        (int104 principal, uint64 baseTrackingIndex, uint64 baseTrackingAccrued,,) =
            CometExtInterface(comet).userBasic(account);

        uint256 descale = CometExtInterface(comet).baseScale() / BASE_ACCRUAL_SCALE;
        uint256 accrued = _updateTrackingAccrued(
            comet, baseTrackingAccrued, principal, baseTrackingIndex, trackingSupplyIndex, trackingBorrowIndex, descale
        );

        if (shouldUpscale) {
            accrued *= rescaleFactor;
        } else if (rescaleFactor != 0) {
            accrued /= rescaleFactor;
        }
        return accrued * multiplier / FACTOR_SCALE;
    }

    function _updateTrackingAccrued(
        address comet,
        uint64 baseTrackingAccrued,
        int104 principal,
        uint64 baseTrackingIndex,
        uint64 trackingSupplyIndex,
        uint64 trackingBorrowIndex,
        uint256 descale
    ) private view returns (uint64) {
        uint256 indexDelta;
        uint256 absPrincipal;
        if (principal >= 0) {
            indexDelta = uint256(trackingSupplyIndex - baseTrackingIndex);
            absPrincipal = SafeCast.toUint256(int256(principal));
        } else {
            indexDelta = uint256(trackingBorrowIndex - baseTrackingIndex);
            absPrincipal = SafeCast.toUint256(-int256(principal));
        }
        return baseTrackingAccrued
            + (absPrincipal * indexDelta / CometExtInterface(comet).trackingIndexScale() / descale).toUint64();
    }

    //
    // Small math + time helpers
    //

    function _mulFactor(uint256 n, uint256 factor) private pure returns (uint256) {
        return n * factor / FACTOR_SCALE;
    }

    function _divBaseWei(address comet, uint256 n, uint256 baseWei) private view returns (uint256) {
        return n * CometExtInterface(comet).baseScale() / baseWei;
    }

    function _safeNow() private view returns (uint40) {
        if (block.timestamp >= 2 ** 40) revert InvalidTimestamp(uint64(block.timestamp), uint64(2 ** 40 - 1));
        return uint40(block.timestamp);
    }
}
