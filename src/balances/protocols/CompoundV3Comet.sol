// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title CompoundV3Comet balance oracle
/// @notice One adapter wraps a single Compound V3 (Comet) market. Reports the user's
///         base-token supply (credit) or borrow (debt), every collateral leg, and
///         unclaimed COMP rewards. Designed to be deployed once per Comet, per chain.
/// @dev Sign convention: `amount` is always the unsigned magnitude; `isDebt` carries the sign.
///      `balanceOracle` on every emitted position is `address(this)` (audit trail).
///      The adapter is fully immutable: the collateral set is snapshotted at construction
///      via `numAssets()` + `getAssetInfo(i)`. If Comet governance ever adds a new collateral
///      asset to this market, redeploy.
contract CompoundV3Comet is IBalanceOracleAdapter {
    using SafeCast for uint256;
    using SafeCast for int256;

    //
    // Constants — pinned by Comet's CometCore implementation
    //

    /// @dev https://github.com/compound-finance/comet/blob/main/contracts/CometCore.sol
    int64 public constant BASE_INDEX_SCALE = 1e15;
    uint64 public constant FACTOR_SCALE = 1e18;
    uint64 public constant BASE_ACCRUAL_SCALE = 1e6;

    //
    // Immutables
    //

    ICompoundRewards public immutable COMPOUND_REWARDS;
    IERC20 public immutable REWARD_TOKEN;
    address public immutable BASE_TOKEN;
    address public immutable COMET;
    CometExtInterface public immutable COMET_EXT_INTERFACE;
    /// @dev = `Comet.baseScale() / BASE_ACCRUAL_SCALE`. Pinned at construction.
    uint256 public immutable ACCRUAL_DESCALE_FACTOR;
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Effectively-immutable storage (populated once in constructor)
    //

    bytes32 private constant PROTOCOL_ID = ProtocolIds.COMPOUND_V3;

    /// @notice Collateral asset addresses for this Comet (snapshot at construction).
    address[] public collaterals;
    mapping(address asset => bool collateral) public isCollateral;

    /// @param compoundRewards_ The chain's CometRewards contract.
    /// @param comet_           The specific Comet (one per market).
    /// @param rewardToken_     COMP (or the chain-specific bridged COMP).
    /// @param navCalculator_   NAVCalculator used as the asset registry.
    constructor(address compoundRewards_, address comet_, address rewardToken_, address navCalculator_) {
        if (compoundRewards_ == address(0) || comet_ == address(0) || rewardToken_ == address(0)) {
            revert InvalidArguments();
        }
        require(compoundRewards_.code.length > 0, "CompoundRewards must be a contract");
        require(comet_.code.length > 0, "Comet must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        COMPOUND_REWARDS = ICompoundRewards(compoundRewards_);
        REWARD_TOKEN = IERC20(rewardToken_);
        COMET = comet_;
        COMET_EXT_INTERFACE = CometExtInterface(comet_);
        BASE_TOKEN = CometInterface(comet_).baseToken();
        ACCRUAL_DESCALE_FACTOR = COMET_EXT_INTERFACE.baseScale() / BASE_ACCRUAL_SCALE;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        uint8 assetCount = COMET_EXT_INTERFACE.numAssets();
        for (uint8 i = 0; i < assetCount; i++) {
            (, address asset,,,,,,) = COMET_EXT_INTERFACE.getAssetInfo(i);
            if (!isCollateral[asset]) {
                isCollateral[asset] = true;
                collaterals.push(asset);
            }
        }
    }

    //
    // IERC165 / IBalanceOracleAdapter
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Returns the deduplicated union of {base, collaterals, reward}. The reward token
    ///      may also appear as a collateral on some markets (e.g. COMP on Mainnet USDC); the
    ///      result is deduplicated so callers iterating it don't double-count.
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _supportedAssets();
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev If an asset has multiple roles for this market (e.g. COMP as collateral AND as
    ///      reward token), the legs are summed since they're all credits and never offset.
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        if (asset != BASE_TOKEN && asset != address(REWARD_TOKEN) && !isCollateral[asset]) return (0, false);

        // Base leg: at most one (supply OR borrow, never both).
        if (asset == BASE_TOKEN) {
            int256 net = _baseUnderlying(account);
            if (net == 0) return (0, false);
            if (net > 0) return (SafeCast.toUint256(net), false);
            return (SafeCast.toUint256(-net), true);
        }

        // Non-base assets: collateral and/or reward; both are credits, sum them.
        uint256 sum = 0;
        if (isCollateral[asset]) sum += COMET_EXT_INTERFACE.collateralBalanceOf(account, asset);
        if (asset == address(REWARD_TOKEN)) sum += _rewardOwed(account);
        return (sum, false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Returns one entry per supported asset that has a non-zero balance.
    ///      For an asset with multiple roles (e.g. COMP collateral + reward), the legs are
    ///      summed into a single entry — same shape as `getOracleBalanceForAsset`.
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) return (new address[](0), new uint256[](0), new bool[](0));

        address[] memory supported = _supportedAssets();
        address[] memory tmpAssets = new address[](supported.length);
        uint256[] memory tmpAmounts = new uint256[](supported.length);
        bool[] memory tmpIsDebt = new bool[](supported.length);
        uint256 count = 0;

        for (uint256 i = 0; i < supported.length; i++) {
            (uint256 amount, bool isDebt_) = _summedLeg(supported[i], account);
            if (amount == 0) continue;
            tmpAssets[count] = supported[i];
            tmpAmounts[count] = amount;
            tmpIsDebt[count] = isDebt_;
            count++;
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
            isDebt[i] = tmpIsDebt[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Emits one position per (asset, role) pair so multi-role assets (e.g. COMP collateral
    ///      AND reward) keep per-role attribution via `positionDetail`. Only assets registered in
    ///      `NAVCalculator` are returned — unregistered assets carry no price and would be dropped
    ///      downstream anyway.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        // Single registry snapshot per query (avoids the per-asset linear scan the prior
        // implementation did against `getRegisteredAssets()`).
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory supported = _supportedAssets();

        // Up to 2 positions per asset (collateral + reward overlap is the only multi-leg case;
        // base supplies one leg max). Sized generously and trimmed below.
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](supported.length * 2);
        uint256 count = 0;

        for (uint256 i = 0; i < supported.length; i++) {
            address asset = supported[i];
            if (assetFilter != address(0) && asset != assetFilter) continue;

            INAVCalculator.Asset memory meta;
            bool registered = false;
            for (uint256 j = 0; j < reg.length; j++) {
                if (reg[j].asset == asset) {
                    meta = reg[j];
                    registered = true;
                    break;
                }
            }
            if (!registered) continue;

            // Base leg
            if (asset == BASE_TOKEN) {
                int256 net = _baseUnderlying(account);
                if (net != 0) {
                    bool isDebt_ = net < 0;
                    uint256 amount = isDebt_ ? SafeCast.toUint256(-net) : SafeCast.toUint256(net);
                    tmp[count++] =
                        _makePosition(meta, amount, isDebt_, isDebt_ ? PositionKind.Borrowed : PositionKind.Supplied);
                }
            }
            // Collateral leg (separate from base; base is never also a collateral in Comet).
            if (isCollateral[asset]) {
                uint256 c = COMET_EXT_INTERFACE.collateralBalanceOf(account, asset);
                if (c > 0) tmp[count++] = _makePosition(meta, c, false, PositionKind.Collateral);
            }
            // Reward leg
            if (asset == address(REWARD_TOKEN)) {
                uint256 r = _rewardOwed(account);
                if (r > 0) tmp[count++] = _makePosition(meta, r, false, PositionKind.Earned);
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = tmp[i];
        }
    }

    function protocolName() external pure returns (string memory) { return "Compound V3"; }
    function describePosition(bytes calldata) external pure returns (string memory) { return "lending position"; }

    //
    // Internal: position assembly
    //

    /// @dev Sums per-asset legs into a single (amount, isDebt) — used by `getOracleBalanceForAsset`
    ///      and `getOracleBalances`. Base is mutually-exclusive supply/borrow; collateral + reward
    ///      legs are both credits and combine without sign conflicts.
    function _summedLeg(address asset, address account) internal view returns (uint256 amount, bool isDebt) {
        if (asset == BASE_TOKEN) {
            int256 net = _baseUnderlying(account);
            if (net == 0) return (0, false);
            if (net > 0) return (SafeCast.toUint256(net), false);
            return (SafeCast.toUint256(-net), true);
        }
        uint256 sum = 0;
        if (isCollateral[asset]) sum += COMET_EXT_INTERFACE.collateralBalanceOf(account, asset);
        if (asset == address(REWARD_TOKEN)) sum += _rewardOwed(account);
        return (sum, false);
    }

    function _makePosition(INAVCalculator.Asset memory meta, uint256 amount, bool isDebt, PositionKind kind)
        internal
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: meta,
            balanceOracle: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: PROTOCOL_ID,
            positionId: abi.encode(COMET),
            positionKind: kind
        });
    }

    /// @dev Deduplicated [BASE_TOKEN, collaterals..., REWARD_TOKEN]. The reward token can also be a
    ///      collateral on some markets (e.g. COMP on Mainnet USDC); de-duping keeps the iteration
    ///      shape predictable for callers.
    function _supportedAssets() internal view returns (address[] memory) {
        uint256 max = collaterals.length + 2; // base + collaterals + reward
        address[] memory tmp = new address[](max);
        uint256 n = 0;

        tmp[n++] = BASE_TOKEN;
        for (uint256 i = 0; i < collaterals.length; i++) {
            address c = collaterals[i];
            if (c == BASE_TOKEN) continue; // defensive; Comet design forbids this
            tmp[n++] = c;
        }
        address reward = address(REWARD_TOKEN);
        bool seen = false;
        for (uint256 i = 0; i < n; i++) {
            if (tmp[i] == reward) {
                seen = true;
                break;
            }
        }
        if (!seen) tmp[n++] = reward;

        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
        return out;
    }

    //
    // Internal: Comet base-token math (present-value of supply/borrow with current accrual)
    //

    /// @dev Returns the user's base balance with interest accrued to `block.timestamp`.
    ///      Positive = net supply; negative = net borrow.
    function _baseUnderlying(address account) internal view returns (int256) {
        (int104 principal,,,,) = COMET_EXT_INTERFACE.userBasic(account);
        (,, uint64 baseSupplyIndex, uint64 baseBorrowIndex) = _accrue();

        int256 total = principal >= 0
            ? int256(principal) * uint256(baseSupplyIndex).toInt256()
            : int256(principal) * uint256(baseBorrowIndex).toInt256();

        return total / BASE_INDEX_SCALE;
    }

    /// @dev Returns updated indices (supply/borrow + tracking-supply/tracking-borrow) as if
    ///      Comet had accrued at `block.timestamp`. Pure view replica of `Comet.accrueAccount`.
    function _accrue()
        internal
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
        ) = COMET_EXT_INTERFACE.totalsBasic();

        uint40 now_ = _safeNow();
        uint256 timeElapsed = uint256(now_ - lastAccrualTime);
        if (timeElapsed == 0) return (trackingSupplyIndex, trackingBorrowIndex, baseSupplyIndex, baseBorrowIndex);

        uint256 utilization = COMET_EXT_INTERFACE.getUtilization();
        uint256 supplyRate = COMET_EXT_INTERFACE.getSupplyRate(utilization);
        uint256 borrowRate = COMET_EXT_INTERFACE.getBorrowRate(utilization);
        baseSupplyIndex += _mulFactor(baseSupplyIndex, supplyRate * timeElapsed).toUint64();
        baseBorrowIndex += _mulFactor(baseBorrowIndex, borrowRate * timeElapsed).toUint64();

        uint256 baseMinForRewards = COMET_EXT_INTERFACE.baseMinForRewards();
        if (totalSupplyBase >= baseMinForRewards) {
            trackingSupplyIndex += _divBaseWei(
                    COMET_EXT_INTERFACE.baseTrackingSupplySpeed() * timeElapsed, totalSupplyBase
                ).toUint64();
        }
        if (totalBorrowBase >= baseMinForRewards) {
            trackingBorrowIndex += _divBaseWei(
                    COMET_EXT_INTERFACE.baseTrackingBorrowSpeed() * timeElapsed, totalBorrowBase
                ).toUint64();
        }
    }

    //
    // Internal: COMP reward math
    //

    /// @dev Returns the unclaimed COMP balance for `account` for this Comet, i.e. accrued − claimed.
    ///      Replays Comet's reward accrual in pure view (the on-chain `getRewardOwed` mutates state).
    /// @dev Defensive: if the rewards contract is ever reconfigured to emit a token other than
    ///      `REWARD_TOKEN`, returns 0 instead of pricing the new token's amount under
    ///      `REWARD_TOKEN`. NAV would otherwise mis-price rewards on a contract upgrade —
    ///      preferable to redeploy the adapter than silently mislabel the asset.
    function _rewardOwed(address account) internal view returns (uint256) {
        (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier) = _rewardConfig();
        if (token == address(0) || token != address(REWARD_TOKEN)) return 0;

        uint256 claimed = COMPOUND_REWARDS.rewardsClaimed(COMET, account);
        uint256 accrued = _rewardAccrued(account, shouldUpscale, rescaleFactor, multiplier);
        if (accrued > claimed) {
            unchecked {
                return accrued - claimed;
            }
        }
        return 0;
    }

    /// @dev Decodes `rewardConfig(comet)` from CometRewards. Mainnet/L1 returns 3 values
    ///      (token, rescaleFactor, shouldUpscale); newer L2 deployments return 4 (adds a multiplier).
    ///      Unknown formats return (0,0,false,FACTOR_SCALE) — no rewards reported.
    function _rewardConfig()
        internal
        view
        returns (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier)
    {
        (bool ok, bytes memory data) =
            address(COMPOUND_REWARDS).staticcall(abi.encodeWithSelector(ICompoundRewards.rewardConfig.selector, COMET));
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

    /// @dev Total COMP accrued by `account` (pre-claim). Mirrors the protocol's reward accounting.
    function _rewardAccrued(address account, bool shouldUpscale, uint64 rescaleFactor, uint256 multiplier)
        internal
        view
        returns (uint256)
    {
        (uint64 trackingSupplyIndex, uint64 trackingBorrowIndex,,) = _accrue();
        (int104 principal, uint64 baseTrackingIndex, uint64 baseTrackingAccrued,,) =
            COMET_EXT_INTERFACE.userBasic(account);

        uint256 accrued = _updateTrackingAccrued(
            baseTrackingAccrued, principal, baseTrackingIndex, trackingSupplyIndex, trackingBorrowIndex
        );

        if (shouldUpscale) {
            accrued *= rescaleFactor;
        } else if (rescaleFactor != 0) {
            accrued /= rescaleFactor;
        }
        return accrued * multiplier / FACTOR_SCALE;
    }

    /// @dev Adds the user's index-delta share of tracking accrual to their stored `baseTrackingAccrued`.
    ///      Replicates `Comet.updateBasePrincipal` (view-only; no state writes).
    function _updateTrackingAccrued(
        uint64 baseTrackingAccrued,
        int104 principal,
        uint64 baseTrackingIndex,
        uint64 trackingSupplyIndex,
        uint64 trackingBorrowIndex
    ) internal view returns (uint64) {
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
            + (absPrincipal * indexDelta / COMET_EXT_INTERFACE.trackingIndexScale() / ACCRUAL_DESCALE_FACTOR).toUint64();
    }

    //
    // Internal: small math + time helpers
    //

    function _mulFactor(uint256 n, uint256 factor) internal pure returns (uint256) {
        return n * factor / FACTOR_SCALE;
    }

    function _divBaseWei(uint256 n, uint256 baseWei) internal view returns (uint256) {
        return n * COMET_EXT_INTERFACE.baseScale() / baseWei;
    }

    /// @dev Comet stores `lastAccrualTime` as `uint40`; reject timestamps that would overflow that
    ///      width when forming a delta (year ~36000+).
    function _safeNow() internal view returns (uint40) {
        if (block.timestamp >= 2 ** 40) revert InvalidTimestamp(uint64(block.timestamp), uint64(2 ** 40 - 1));
        return uint40(block.timestamp);
    }
}

//
// External interfaces (Comet & CometRewards)
//

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
