// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title Convex Balance Oracle
/// @author kpk
/// @notice Returns pool-token and reward balances for an account's Convex-staked Curve LP position.
/// @dev The Curve LP token address must be passed explicitly as `lpToken_` — `convexRewards.stakingToken()`
///      returns the cvxLP wrapper token, not the underlying Curve LP.
///      Compatible with Curve Stableswap pools (IDs 0, 3, 12) — see CurveBalanceOracle for pool notes.
///      Bounded loop: `_MAX_ITERATIONS = 8`.
///
///      Token flow:
///        Pool tokens: proportional share = (poolBalance × stakedLP) / totalLPSupply
///        CRV:         earned() from main rewarder (more accurate than Curve's integrate_fraction)
///        CVX:         derived from CRV earned via cliff schedule (see _cvxMintAmount)
///        Extra:       earned() from each extra rewarder; stash wrappers are unwrapped transparently
///
/// @dev CVX derivation uses the standard Convex cliff schedule:
///      cliff = CVX.totalSupply / REDUCTION_PER_CLIFF
///      cvxAmount = (crvEarned * remainingCliffs) / TOTAL_CLIFFS, capped at MAX_SUPPLY - totalSupply
contract ConvexBalanceOracle is IBalanceOracleAdapter {
    using SafeCast for uint256;

    //
    // Type Definitions
    //

    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice Curve LP token staked in Convex (provided explicitly via constructor parameter `lpToken_`)
    address public immutable LP_TOKEN;

    /// @notice Convex main rewarder contract
    address public immutable REWARDER;

    /// @notice Canonical Ethereum mainnet CVX token address
    address internal constant _CVX_TOKEN = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    /// @dev Convex emission cliff constants
    uint256 internal constant _CVX_TOTAL_CLIFFS = 1000;
    uint256 internal constant _CVX_REDUCTION_PER_CLIFF = 100_000e18;
    uint256 internal constant _CVX_MAX_SUPPLY = 100_000_000e18;

    /// @notice Bounded iteration limit
    uint256 internal constant _MAX_ITERATIONS = 8;

    /// @notice Protocol identifier for this oracle
    string private _protocol;

    /// @notice JSON metadata base (no closing `}`) for this oracle
    string private _positionDetail;

    /// @notice Stable hex identifier for this adapter instance (gauge/pool address)
    string private _positionId;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param convexRewards_ The Convex BaseRewardPool contract
    /// @param lpToken_ The underlying Curve LP token (NOT the Convex deposit token from stakingToken())
    /// @param protocol_ Protocol identifier (e.g., "Convex")
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (gauge/pool address).
    /// @param navCalculator_ The NAVCalculator contract address
    constructor(
        address convexRewards_,
        address lpToken_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) {
        if (convexRewards_ == address(0) || lpToken_ == address(0)) {
            revert InvalidArguments();
        }
        require(convexRewards_.code.length > 0, "Rewarder must be a contract");
        require(lpToken_.code.length > 0, "LP token must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        REWARDER = convexRewards_;
        LP_TOKEN = lpToken_;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        _positionId = positionId_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    /// @dev Returns pool tokens (from Curve LP coins()) + CRV + CVX + extra rewards, deduplicated.
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _getAllSupportedAssets();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0)) return (0, false);
        return (_calculateBalance(account, asset), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedAssets = _getAllSupportedAssets();
        AssetBalanceData[] memory tempData = new AssetBalanceData[](supportedAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            uint256 balance = _calculateBalance(account, supportedAssets[i]);
            if (balance > 0) {
                tempData[count] = AssetBalanceData({asset: supportedAssets[i], amount: balance, isDebt: false});
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempData[i].asset;
            amounts[i] = tempData[i].amount;
            isDebt[i] = tempData[i].isDebt;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = _getAllSupportedAssets();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        address[] memory eligibleAssets = ArrayLib.intersection(supportedAssets, registeredAssets);
        if (eligibleAssets.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Apply asset filter
        if (assetFilter != address(0)) {
            bool filterFound = false;
            for (uint256 i = 0; i < eligibleAssets.length; i++) {
                if (eligibleAssets[i] == assetFilter) {
                    filterFound = true;
                    break;
                }
            }
            if (!filterFound) return new INAVCalculator.PositionBalance[](0);

            uint256 balance = _calculateBalance(account, assetFilter);
            if (balance == 0) return new INAVCalculator.PositionBalance[](0);

            INAVCalculator.Asset memory filteredAsset = _getAssetInfo(assetFilter);
            positions = new INAVCalculator.PositionBalance[](1);
            positions[0] = INAVCalculator.PositionBalance({
                underlyingAsset: filteredAsset,
                balanceOracle: address(this),
                amount: balance,
                isDebt: false,
                protocol: _protocol,
                positionDetail: string.concat(_positionDetail, ",\"token\":\"", filteredAsset.symbol, "\"}"),
                positionId: _positionId
            });
            return positions;
        }

        // No filter — return all eligible assets with non-zero balance
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](eligibleAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < eligibleAssets.length; i++) {
            uint256 balance = _calculateBalance(account, eligibleAssets[i]);
            if (balance > 0) {
                INAVCalculator.Asset memory eligibleAsset = _getAssetInfo(eligibleAssets[i]);
                tempPositions[count] = INAVCalculator.PositionBalance({
                    underlyingAsset: eligibleAsset,
                    balanceOracle: address(this),
                    amount: balance,
                    isDebt: false,
                    protocol: _protocol,
                    positionDetail: string.concat(_positionDetail, ",\"token\":\"", eligibleAsset.symbol, "\"}"),
                    positionId: _positionId
                });
                count++;
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = tempPositions[i];
        }
    }

    //
    // Internal Helpers
    //

    /// @notice Computes total balance for a given asset: pool position + main reward + extra rewards.
    function _calculateBalance(address account, address asset) internal view returns (uint256) {
        uint256 balance = _getPoolTokenBalance(account, asset);
        balance += _getMainRewardBalance(account, asset);
        balance += _getExtraRewardBalance(account, asset);
        return balance;
    }

    /// @notice Gets the account's proportional Curve pool-token balance from Convex-staked LP.
    function _getPoolTokenBalance(address account, address token) internal view returns (uint256) {
        (bool balSuccess, uint256 stakedLp) =
            _safeCallUint(REWARDER, abi.encodeCall(IConvexRewarder.balanceOf, (account)));
        if (!balSuccess || stakedLp == 0) return 0;

        (bool supplySuccess, uint256 totalSupply) =
            _safeCallUint(LP_TOKEN, abi.encodeCall(ICurveLPToken.totalSupply, ()));
        if (!supplySuccess || totalSupply == 0) return 0;

        for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
            (bool coinSuccess, address poolToken) = _safeCallAddress(LP_TOKEN, abi.encodeCall(ICurveLPToken.coins, (i)));
            if (!coinSuccess) break;

            if (poolToken == token) {
                (bool poolBalSuccess, uint256 poolBalance) =
                    _safeCallUint(LP_TOKEN, abi.encodeCall(ICurveLPToken.balances, (i)));
                if (!poolBalSuccess) return 0;
                return (poolBalance * stakedLp) / totalSupply;
            }
        }
        return 0;
    }

    /// @notice Gets balance for the main Convex reward token (typically CRV) via earned().
    function _getMainRewardBalance(address account, address token) internal view returns (uint256) {
        (bool success, address rewardTokenAddr) =
            _safeCallAddress(REWARDER, abi.encodeCall(IConvexRewarder.rewardToken, ()));
        if (!success || rewardTokenAddr != token) return 0;

        (bool earnedSuccess, uint256 earned) =
            _safeCallUint(REWARDER, abi.encodeCall(IConvexRewarder.earned, (account)));
        return earnedSuccess ? earned : 0;
    }

    /// @notice Gets balance for extra Convex reward tokens (handles stash wrappers → CVX derivation).
    function _getExtraRewardBalance(address account, address token) internal view returns (uint256) {
        (bool lenSuccess, uint256 len) = _safeCallUint(REWARDER, abi.encodeCall(IConvexRewarder.extraRewardsLength, ()));
        if (!lenSuccess) return 0;

        uint256 maxLen = len > _MAX_ITERATIONS ? _MAX_ITERATIONS : len;
        for (uint256 j = 0; j < maxLen; j++) {
            uint256 result = _checkExtraReward(account, token, j);
            if (result > 0) return result;
        }
        return 0;
    }

    /// @notice Checks a single extra rewarder at index for the given token.
    function _checkExtraReward(address account, address token, uint256 index) internal view returns (uint256) {
        (bool extraSuccess, address extraAddr) =
            _safeCallAddress(REWARDER, abi.encodeCall(IConvexRewarder.extraRewards, (index)));
        if (!extraSuccess) return 0;

        (bool tokenSuccess, address rewardToken) =
            _safeCallAddress(extraAddr, abi.encodeCall(IExtraRewardsDistributor.rewardToken, ()));
        if (!tokenSuccess) return 0;

        // Try to unwrap stash wrapper (e.g. CVX stash token)
        (bool underlyingSuccess, address underlying) =
            _safeCallAddress(rewardToken, abi.encodeCall(IStashTokenWrapper.token, ()));

        if (underlyingSuccess && underlying != address(0)) {
            // Stash wrapper: check the underlying token
            if (underlying != token) return 0;
            if (underlying == _CVX_TOKEN) {
                // CVX is derived from CRV earned, not from stash earned
                return _getCvxFromCrvEarned(account);
            }
            (bool earnedSuccess, uint256 earned) =
                _safeCallUint(extraAddr, abi.encodeCall(IExtraRewardsDistributor.earned, (account)));
            return earnedSuccess ? earned : 0;
        } else {
            // Direct ERC20 reward token
            if (rewardToken != token) return 0;
            (bool earnedSuccess, uint256 earned) =
                _safeCallUint(extraAddr, abi.encodeCall(IExtraRewardsDistributor.earned, (account)));
            return earnedSuccess ? earned : 0;
        }
    }

    /// @notice Derives CVX amount from CRV earned via the Convex cliff emission schedule.
    function _getCvxFromCrvEarned(address account) internal view returns (uint256) {
        (bool earnedSuccess, uint256 crvEarned) =
            _safeCallUint(REWARDER, abi.encodeCall(IConvexRewarder.earned, (account)));
        if (!earnedSuccess) return 0;
        return _cvxMintAmount(crvEarned);
    }

    /// @notice Computes how much CVX would be minted for a given amount of CRV earned.
    /// @dev Uses Convex cliff schedule: remaining = TOTAL_CLIFFS - (supply / REDUCTION_PER_CLIFF)
    ///      cvxAmount = (crvEarned × remaining) / TOTAL_CLIFFS, capped at MAX_SUPPLY - supply
    function _cvxMintAmount(uint256 crvEarned) internal view returns (uint256) {
        if (crvEarned == 0) return 0;
        (bool success, uint256 supply) = _safeCallUint(_CVX_TOKEN, abi.encodeCall(IConvexToken.totalSupply, ()));
        if (!success) return 0;

        uint256 cliff = supply / _CVX_REDUCTION_PER_CLIFF;
        if (cliff < _CVX_TOTAL_CLIFFS) {
            uint256 remaining = _CVX_TOTAL_CLIFFS - cliff;
            uint256 cvxAmount = (crvEarned * remaining) / _CVX_TOTAL_CLIFFS;
            uint256 amtTillMax = _CVX_MAX_SUPPLY - supply;
            if (cvxAmount > amtTillMax) cvxAmount = amtTillMax;
            return cvxAmount;
        }
        return 0;
    }

    /// @notice Returns all pool tokens from the underlying Curve pool.
    function _getPoolTokens() internal view returns (address[] memory) {
        address[] memory temp = new address[](_MAX_ITERATIONS);
        uint256 count = 0;
        for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
            (bool success, address token) = _safeCallAddress(LP_TOKEN, abi.encodeCall(ICurveLPToken.coins, (i)));
            if (!success) break;
            temp[count] = token;
            count++;
        }
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Returns all reward tokens (main + extra, unwrapped), deduplicated.
    function _getRewardTokens() internal view returns (address[] memory) {
        address[] memory temp = new address[](_MAX_ITERATIONS + 1);
        uint256 count = 0;

        // Main reward token (typically CRV)
        (bool mainSuccess, address mainToken) =
            _safeCallAddress(REWARDER, abi.encodeCall(IConvexRewarder.rewardToken, ()));
        if (mainSuccess && mainToken != address(0)) {
            temp[count] = mainToken;
            count++;
        }

        // Extra reward tokens (unwrap stash wrappers)
        (bool lenSuccess, uint256 extraCount) =
            _safeCallUint(REWARDER, abi.encodeCall(IConvexRewarder.extraRewardsLength, ()));
        if (lenSuccess) {
            uint256 maxExtra = extraCount > _MAX_ITERATIONS ? _MAX_ITERATIONS : extraCount;
            for (uint256 j = 0; j < maxExtra; j++) {
                address token = _getExtraRewardToken(j);
                if (token == address(0)) continue;

                bool isDuplicate = false;
                for (uint256 k = 0; k < count; k++) {
                    if (temp[k] == token) {
                        isDuplicate = true;
                        break;
                    }
                }
                if (!isDuplicate) {
                    temp[count] = token;
                    count++;
                }
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Returns the underlying token for a single extra rewarder (unwraps stash wrappers).
    function _getExtraRewardToken(uint256 index) internal view returns (address) {
        (bool extraSuccess, address extraAddr) =
            _safeCallAddress(REWARDER, abi.encodeCall(IConvexRewarder.extraRewards, (index)));
        if (!extraSuccess) return address(0);

        (bool tokenSuccess, address rewardToken) =
            _safeCallAddress(extraAddr, abi.encodeCall(IExtraRewardsDistributor.rewardToken, ()));
        if (!tokenSuccess) return address(0);

        (bool underlyingSuccess, address underlying) =
            _safeCallAddress(rewardToken, abi.encodeCall(IStashTokenWrapper.token, ()));

        return (underlyingSuccess && underlying != address(0)) ? underlying : rewardToken;
    }

    /// @notice Returns pool tokens + reward tokens, deduplicated.
    function _getAllSupportedAssets() internal view returns (address[] memory) {
        address[] memory poolTokens = _getPoolTokens();
        address[] memory rewardTokens = _getRewardTokens();

        address[] memory temp = new address[](poolTokens.length + rewardTokens.length);
        uint256 count = 0;

        for (uint256 i = 0; i < poolTokens.length; i++) {
            temp[count] = poolTokens[i];
            count++;
        }

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == rewardTokens[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                temp[count] = rewardTokens[i];
                count++;
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry.
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Safely calls a function that returns uint256.
    function _safeCallUint(address target, bytes memory data) internal view returns (bool success, uint256 result) {
        bytes memory returnData;
        (success, returnData) = target.staticcall(data);
        if (success && returnData.length >= 32) {
            result = abi.decode(returnData, (uint256));
        }
    }

    /// @notice Safely calls a function that returns address.
    function _safeCallAddress(address target, bytes memory data) internal view returns (bool success, address result) {
        bytes memory returnData;
        (success, returnData) = target.staticcall(data);
        if (success && returnData.length >= 32) {
            result = abi.decode(returnData, (address));
        }
    }
}

// ---------------------------
// Interface Section
// ---------------------------

/// @notice Minimal Curve LP token interface (Stableswap pool)
interface ICurveLPToken {
    function coins(uint256 index) external view returns (address);
    function balances(uint256 index) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Minimal Convex BaseRewardPool interface
interface IConvexRewarder {
    function rewardToken() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 index) external view returns (address);
}

/// @notice Interface for Convex extra rewarder contracts
interface IExtraRewardsDistributor {
    function rewardToken() external view returns (address);
    function earned(address account) external view returns (uint256);
}

/// @notice Interface for Convex stash token wrappers (expose underlying token)
interface IStashTokenWrapper {
    function token() external view returns (address);
}

/// @notice Minimal CVX token interface for total supply (used in cliff schedule)
interface IConvexToken {
    function totalSupply() external view returns (uint256);
}
