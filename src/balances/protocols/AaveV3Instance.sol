// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayUtils} from "src/utils/ArrayUtils.sol";

/// @title Aave V3 Instance Balance Oracle
/// @author kpk
/// @notice This contract calculates a user's positions in an Aave v3 Instance by:
/// 1. Retrieving the user's supplied and borrowed amounts for each supported reserve via the Protocol Data Provider
/// 2. Fetching the user's accrued rewards for each asset via the Rewards Distributor
/// 3. Returning separate balance-only positions for supply, borrows, and rewards
/// @dev Returns PositionBalance structs (balance-only data) without pricing information.
/// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
/// @dev For each asset, up to 3 positions may be returned: Supply/Collateral (positive balance), Borrow (negative balance), and Rewards (positive balance).
/// @dev positionDetail is "Supply", "Collateral", "Borrow", or "Rewards" (Collateral when usageAsCollateralEnabled, else Supply for deposits).
contract AaveV3InstanceBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // Type Definitions
    //

    /// @notice User reserve data structure
    struct UserReserveData {
        address asset;
        uint256 currentATokenBalance;
        uint256 currentVariableDebt;
        uint256 rewardBalance;
        bool usageAsCollateralEnabled;
    }

    //
    // State Variables
    //

    /// @notice The address of the Aave v3 Protocol Data Provider contract
    IProtocolDataProvider public immutable DATA_PROVIDER;

    /// @notice The address of the Aave v3 Rewards Distributor contract
    IRewardsDistributor public immutable REWARDS_DISTRIBUTOR;

    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier for this oracle (e.g., "Aave v3")
    string private _protocol;

    //
    // Constructor
    //

    /// @param dataProvider_ The address of the Aave v3 Pool Data Provider contract
    /// @param rewardsDistributor_ The address of the Aave v3 Rewards Distributor contract
    /// @param protocol_ Protocol identifier (e.g., "Aave v3")
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(address dataProvider_, address rewardsDistributor_, string memory protocol_, address navCalculator_) {
        // Validate that addresses are contracts (for production safety)
        // In tests, mocks should be proper contracts, but we handle failures gracefully in view functions
        require(dataProvider_.code.length > 0, "DataProvider must be a contract");
        require(rewardsDistributor_.code.length > 0, "RewardsDistributor must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        DATA_PROVIDER = IProtocolDataProvider(dataProvider_);
        REWARDS_DISTRIBUTOR = IRewardsDistributor(rewardsDistributor_);
        _protocol = protocol_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165 Implementation
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter Implementation
    //

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _getSupportedAssets();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance) {
        // Return zero for zero address
        if (asset == address(0)) {
            return 0;
        }

        // Return zero for unsupported assets
        if (!_isAssetSupported(asset)) {
            return 0;
        }

        // Optimized: directly calculate net balance without building full Position structs
        UserReserveData memory data = _getUserAssetData(account, asset);
        balance = (data.currentATokenBalance.toInt256() - data.currentVariableDebt.toInt256())
            + data.rewardBalance.toInt256();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory balances)
    {
        address[] memory supportedAssets = _getSupportedAssets();

        // Only return assets and balances for tokens with non-zero balances
        UserReserveData[] memory userReserveData = _getUserReservesData(account, supportedAssets);
        assets = new address[](userReserveData.length);
        balances = new int256[](userReserveData.length);
        for (uint256 i = 0; i < userReserveData.length; i++) {
            assets[i] = userReserveData[i].asset;
            UserReserveData memory data = _getUserAssetData(account, assets[i]);
            balances[i] = (data.currentATokenBalance.toInt256() - data.currentVariableDebt.toInt256())
                + data.rewardBalance.toInt256();
        }
        return (assets, balances);
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Aave v3 positions
    /// @dev Returns PositionBalance structs containing deposit, borrow, and reward positions.
    /// @dev Only returns positions for assets that are both supported by Aave and registered in NAVCalculator.
    /// @dev Pricing information is added by NAVCalculator when these positions are enriched.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = _getSupportedAssets();
        address[] memory registeredAssets = NAV_CALCULATOR.assets();

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayUtils.intersection(supportedAssets, registeredAssets);

        UserReserveData[] memory userReservesData;
        if (registeredSupportedAssets.length == 0) {
            userReservesData = new UserReserveData[](0);
        } else if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    userReservesData = new UserReserveData[](1);
                    userReservesData[0] = _getUserAssetData(account, assetFilter);
                    break;
                }
            }
        } else {
            userReservesData = _getUserReservesData(account, registeredSupportedAssets);
        }
        positions = _buildPositions(userReservesData);
    }

    //
    // Internal Functions - Asset Registry & Lookup
    //

    /// @notice Gets asset information from NAVCalculator by iterating through registered assets
    /// @param asset The asset address to look up
    /// @return assetInfo The Asset struct containing asset address, symbol, and decimals
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory assetInfo) {
        uint256 assetCount = NAV_CALCULATOR.assetCount();
        for (uint256 i = 0; i < assetCount; i++) {
            INAVCalculator.Asset memory a = NAV_CALCULATOR.assetAt(i);
            if (a.asset == asset) {
                return a;
            }
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Returns the list of all the underlying assets supported by this oracle
    /// @dev The returned list may be empty if the oracle cannot determine or provide the supported assets
    /// @return underlyingAssets The list of underlying asset addresses supported by this oracle (may be empty)
    function _getSupportedAssets() internal view returns (address[] memory) {
        IProtocolDataProvider.TokenData[] memory reserves = DATA_PROVIDER.getAllReservesTokens();
        address[] memory assets = new address[](reserves.length);

        for (uint256 i = 0; i < reserves.length; i++) {
            assets[i] = reserves[i].tokenAddress;
        }

        return assets;
    }

    /// @notice Checks if an asset is supported by Aave
    /// @param asset The asset address to check
    /// @return supported True if the asset is supported
    function _isAssetSupported(address asset) internal view returns (bool supported) {
        address[] memory supportedAssets = _getSupportedAssets();
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == asset) {
                return true;
            }
        }
        return false;
    }

    //
    // Internal Functions - Aave Protocol Data Retrieval
    //

    /// @notice Retrieves user reserve data for a specific asset
    /// @param user The user address to query
    /// @param asset The asset address to query
    /// @return UserReserveData struct containing aToken balance, variable debt, rewards, and collateral status
    function _getUserAssetData(address user, address asset) internal view returns (UserReserveData memory) {
        (
            uint256 currentATokenBalance,, // currentStableDebt - unused
            uint256 currentVariableDebt,, // principalStableDebt - unused
            , // scaledVariableDebt - unused
            , // stableBorrowRate - unused
            , // liquidityRate - unused
            , // stableRateLastUpdated - unused
            bool usageAsCollateralEnabled
        ) = DATA_PROVIDER.getUserReserveData(asset, user);

        uint256 rewardBalance = _getRewardsData(user, asset);
        return UserReserveData({
            asset: asset,
            currentATokenBalance: currentATokenBalance,
            currentVariableDebt: currentVariableDebt,
            rewardBalance: rewardBalance,
            usageAsCollateralEnabled: usageAsCollateralEnabled
        });
    }

    /// @notice Get the supplied, borrowed amounts, and rewards for multiple tokens and user
    /// @param user The user address
    /// @param tokens Array of token addresses
    /// @return userReserveData Array of UserReserveData for tokens with non-zero balances
    function _getUserReservesData(address user, address[] memory tokens)
        internal
        view
        returns (UserReserveData[] memory userReserveData)
    {
        // Pre-allocate temporary array (max size)
        UserReserveData[] memory tempData = new UserReserveData[](tokens.length);
        uint256 count = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            UserReserveData memory data = _getUserAssetData(user, tokens[i]);
            if (data.currentATokenBalance > 0 || data.currentVariableDebt > 0 || data.rewardBalance > 0) {
                tempData[count] = data;
                count++;
            }
        }

        // Resize to actual count
        userReserveData = new UserReserveData[](count);
        for (uint256 i = 0; i < count; i++) {
            userReserveData[i] = tempData[i];
        }
    }

    /// @notice Retrieves the total accrued rewards for a user and asset
    /// @param user The user address to query
    /// @param asset The asset address to query
    /// @return rewardAmount The total unclaimed rewards (from both aToken and asset rewards)
    function _getRewardsData(address user, address asset) internal view returns (uint256 rewardAmount) {
        IProtocolDataProvider.ReserveData memory reserveData = DATA_PROVIDER.getReserveData(asset);
        address aTokenAddress = reserveData.aTokenAddress;

        if (aTokenAddress != address(0)) {
            rewardAmount = REWARDS_DISTRIBUTOR.getUserAccruedRewards(user, aTokenAddress);
        }

        rewardAmount += REWARDS_DISTRIBUTOR.getUserAccruedRewards(user, asset);

        return rewardAmount;
    }

    //
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this oracle
    /// @param userReservesData Array of UserReserveData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Creates up to 3 positions per asset: Supply/Collateral (if aTokenBalance > 0), Borrow (if variableDebt > 0), and Rewards (if rewardBalance > 0)
    /// @dev Supply positions are labeled as "Collateral" if usageAsCollateralEnabled is true, otherwise "Supply"
    /// @dev All positions are balance-only; pricing is added by NAVCalculator during enrichment
    function _buildPositions(UserReserveData[] memory userReservesData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Pre-allocate array (max 3 positions per asset: deposit, borrow, rewards)
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](userReservesData.length * 3);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < userReservesData.length; i++) {
            address asset = userReservesData[i].asset;

            // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

            // Build supply position (supplied assets)
            // Label as Collateral when used as collateral, otherwise Supply
            if (userReservesData[i].currentATokenBalance > 0) {
                string memory positionDetail = userReservesData[i].usageAsCollateralEnabled ? "Collateral" : "Supply";
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    amount: userReservesData[i].currentATokenBalance,
                    isDebt: false, // Deposits are credit
                    protocol: _protocol,
                    positionDetail: positionDetail
                });
                positionCount++;
            }

            // Build borrowing position (borrowed assets - debt)
            if (userReservesData[i].currentVariableDebt > 0) {
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    amount: userReservesData[i].currentVariableDebt,
                    isDebt: true, // Borrows are debt
                    protocol: _protocol,
                    positionDetail: "Borrow"
                });
                positionCount++;
            }

            // Build rewards position (unclaimed rewards)
            if (userReservesData[i].rewardBalance > 0) {
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    amount: userReservesData[i].rewardBalance,
                    isDebt: false, // Rewards are credit
                    protocol: _protocol,
                    positionDetail: "Rewards"
                });
                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
}

//
// Interfaces
//

/// @title IProtocolDataProvider
/// @notice Defines the interface for Aave v3 Protocol Data Provider
/// @dev This interface matches the current Aave v3 ProtocolDataProvider implementation
interface IProtocolDataProvider {
    /// @notice Returns the user data in a reserve
    /// @param asset The address of the underlying asset of the reserve
    /// @param user The address of the user
    /// @return currentATokenBalance The current AToken balance of the user
    /// @return currentStableDebt The current stable debt of the user
    /// @return currentVariableDebt The current variable debt of the user
    /// @return principalStableDebt The principal stable debt of the user
    /// @return scaledVariableDebt The scaled variable debt of the user
    /// @return stableBorrowRate The stable borrow rate of the user
    /// @return liquidityRate The liquidity rate of the reserve
    /// @return stableRateLastUpdated The timestamp of the last update of the user stable rate
    /// @return usageAsCollateralEnabled True if the user is using the asset as collateral, false otherwise
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );

    /// @notice Struct to hold a token's symbol and its contract address.
    /// @dev Used when returning lists of reserves or aTokens as symbol–address pairs.
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    /// @notice Struct to hold reserve data
    struct ReserveData {
        address aTokenAddress;
    }

    /// @notice Returns the list of the existing reserves in the pool.
    /// @dev Handling MKR and ETH in a different way since they do not have standard `symbol` functions.
    /// @return reserveTokens The list of reserves, pairs of symbols and addresses
    function getAllReservesTokens() external view returns (TokenData[] memory reserveTokens);

    /// @notice Returns the reserve data for a given asset
    /// @param asset The address of the underlying asset
    /// @return The reserve data containing the aToken address
    function getReserveData(address asset) external view returns (ReserveData memory);
}

/// @title IRewardsDistributor
/// @notice Interface for Aave v3 Rewards Distributor contract
/// @dev This interface matches the current Aave v3 RewardsController implementation
interface IRewardsDistributor {
    /// @notice Returns the list of all reward tokens available in the system
    /// @return The list of reward token addresses
    function getRewardsList() external view returns (address[] memory);

    /// @notice Returns the accrued rewards balance of a user for a specific reward token
    /// @param user The address of the user
    /// @param reward The address of the reward token
    /// @return The unclaimed rewards balance, not including virtually accrued rewards since last distribution
    function getUserAccruedRewards(address user, address reward) external view returns (uint256);
}
