// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Aave V3 Instance Balance Oracle
/// @author kpk
/// @notice This contract calculates a user's positions in an Aave v3 Instance by:
/// 1. Retrieving the user's supplied and borrowed amounts for each supported reserve via the Protocol Data Provider
/// 2. Returning separate balance-only positions for supply and borrows
/// @dev Returns PositionBalance structs (balance-only data) without pricing information.
/// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
/// @dev For each asset, up to 2 positions may be returned: Supply/Collateral (positive balance) and Borrow (negative balance).
/// @dev positionDetail is "Supply", "Collateral", or "Borrow" (Collateral when usageAsCollateralEnabled, else Supply for deposits).
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
        bool usageAsCollateralEnabled;
    }

    //
    // State Variables
    //

    /// @notice The address of the Aave v3 Protocol Data Provider contract
    IProtocolDataProvider public immutable DATA_PROVIDER;

    /// @notice The Pool address derived from DATA_PROVIDER at construction (used as positionId anchor).
    address public immutable POOL;

    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3_LENDING;

    function _protocolId() internal pure virtual returns (bytes32) { return PROTOCOL_ID; }

    //
    // Constructor
    //

    /// @param dataProvider_ The address of the Aave v3 Pool Data Provider contract
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(address dataProvider_, address navCalculator_) {
        require(dataProvider_.code.length > 0, "DataProvider must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        DATA_PROVIDER = IProtocolDataProvider(dataProvider_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        POOL = _poolFrom(dataProvider_);
    }

    /// @notice Resolves the Pool address from a DataProvider. Virtual so V2 subclass can use getLendingPool().
    function _poolFrom(address dataProvider_) internal view virtual returns (address) {
        return IAavePoolAddressesProvider(IAaveAddressesProviderSource(dataProvider_).ADDRESSES_PROVIDER()).getPool();
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

    /// @notice Converts net balance (supply - debt) to (amount, isDebt)
    function _netToAmountAndDebt(uint256 supply, uint256 debt) internal pure returns (uint256 amount, bool isDebt) {
        if (supply >= debt) {
            return (supply - debt, false);
        }
        return (debt - supply, true);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0)) {
            return (0, false);
        }
        if (!_isAssetSupported(asset)) {
            return (0, false);
        }
        UserReserveData memory data = _getUserAssetData(account, asset);
        return _netToAmountAndDebt(data.currentATokenBalance, data.currentVariableDebt);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedAssets = _getSupportedAssets();
        UserReserveData[] memory userReserveData = _getUserReservesData(account, supportedAssets);

        address[] memory tempAssets = new address[](userReserveData.length);
        uint256[] memory tempAmounts = new uint256[](userReserveData.length);
        bool[] memory tempIsDebt = new bool[](userReserveData.length);
        uint256 count = 0;

        for (uint256 i = 0; i < userReserveData.length; i++) {
            (uint256 amount, bool isDebt_) =
                _netToAmountAndDebt(userReserveData[i].currentATokenBalance, userReserveData[i].currentVariableDebt);
            if (amount != 0) {
                tempAssets[count] = userReserveData[i].asset;
                tempAmounts[count] = amount;
                tempIsDebt[count] = isDebt_;
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
            isDebt[i] = tempIsDebt[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Aave v3 positions
    /// @dev Returns PositionBalance structs containing deposit and borrow positions.
    /// @dev Only returns positions for assets that are both supported by Aave and registered in NAVCalculator.
    /// @dev Pricing information is added by NAVCalculator when these positions are enriched.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = _getSupportedAssets();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

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
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) {
                return reg[i];
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
    /// @return UserReserveData struct containing aToken balance, variable debt, and collateral status
    function _getUserAssetData(address user, address asset) internal view returns (UserReserveData memory) {
        (
            uint256 currentATokenBalance,, // currentStableDebt - omitted: Aave v3 deprecated stable borrow (frozen/paused); all active positions use variable debt only
            uint256 currentVariableDebt,, // principalStableDebt - unused
            , // scaledVariableDebt - unused
            , // stableBorrowRate - unused
            , // liquidityRate - unused
            , // stableRateLastUpdated - unused
            bool usageAsCollateralEnabled
        ) = DATA_PROVIDER.getUserReserveData(asset, user);

        return UserReserveData({
            asset: asset,
            currentATokenBalance: currentATokenBalance,
            currentVariableDebt: currentVariableDebt,
            usageAsCollateralEnabled: usageAsCollateralEnabled
        });
    }

    /// @notice Get the supplied and borrowed amounts for multiple tokens and user
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
            if (data.currentATokenBalance > 0 || data.currentVariableDebt > 0) {
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

    //
    // Internal Functions - Position Building
    //

    function protocolName() external pure virtual returns (string memory) { return "Aave V3"; }
    function describePosition(bytes calldata) external pure returns (string memory) { return "lending position"; }

    /// @notice Internal helper that builds all positions for this oracle
    /// @param userReservesData Array of UserReserveData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Creates up to 2 positions per asset: Supply/Collateral (if aTokenBalance > 0) and Borrow (if variableDebt > 0)
    /// @dev Supply positions are labeled as "Collateral" if usageAsCollateralEnabled is true, otherwise "Supply"
    /// @dev All positions are balance-only; pricing is added by NAVCalculator during enrichment
    function _buildPositions(UserReserveData[] memory userReservesData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Pre-allocate array (max 2 positions per asset: deposit, borrow)
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](userReservesData.length * 2);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < userReservesData.length; i++) {
            address asset = userReservesData[i].asset;

            // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
            INAVCalculator.Asset memory assetMeta = _getAssetInfo(asset);

            // Build supply position (supplied assets)
            // Label as Collateral when used as collateral, otherwise Supplied
            if (userReservesData[i].currentATokenBalance > 0) {
                PositionKind kind = userReservesData[i].usageAsCollateralEnabled
                    ? PositionKind.Collateral
                    : PositionKind.Supplied;
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    balanceAsset: assetMeta,
                    balanceOracle: address(this),
                    amount: userReservesData[i].currentATokenBalance,
                    isDebt: false, // Deposits are credit
                    protocolId: _protocolId(),
                    positionId: abi.encode(POOL, asset),
                    positionKind: kind
                });
                positionCount++;
            }

            // Build borrowing position (borrowed assets - debt)
            if (userReservesData[i].currentVariableDebt > 0) {
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    balanceAsset: assetMeta,
                    balanceOracle: address(this),
                    amount: userReservesData[i].currentVariableDebt,
                    isDebt: true, // Borrows are debt
                    protocolId: _protocolId(),
                    positionId: abi.encode(POOL, asset),
                    positionKind: PositionKind.Borrowed
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

    /// @notice Returns the list of the existing reserves in the pool.
    /// @dev Handling MKR and ETH in a different way since they do not have standard `symbol` functions.
    /// @return reserveTokens The list of reserves, pairs of symbols and addresses
    function getAllReservesTokens() external view returns (TokenData[] memory reserveTokens);
}

interface IAaveAddressesProviderSource {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}
