// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "src/errors.sol";

/// @title Aave V3 Instance Balance Oracle
/// @author kpk
/// @notice This contract calculates a user's net position in an Aave v3 Instance by:
/// 1. Retrieving the user's supplied and borrowed amounts for each supported reserve via the Protocol Data Provider
/// 2. Computing net balance as (supplied - borrowed)
/// 3. Fetching the user's accrued rewards for the asset via the Rewards Distributor
/// 4. Returning the sum of net balance and unclaimed rewards
/// The final balance is denominated in the underlying asset of the reserve.
contract AaveV3InstanceBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using Math for uint256;
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The address of the data provider
    IProtocolDataProvider public immutable DATA_PROVIDER;
    /// @notice The address of the incentives controller
    IRewardsDistributor public immutable REWARDS_DISTRIBUTOR;
    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Constructor
    //

    /// @param dataProvider_ The address of the Aave v3 Pool Data Provider contract.
    /// @param rewardsDistributor_ The address of the Aave v3 Rewards Distributor contract.
    /// @param protocol_ Protocol identifier (e.g., "Aave v3").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(address dataProvider_, address rewardsDistributor_, string memory protocol_, address balances_) {
        DATA_PROVIDER = IProtocolDataProvider(dataProvider_);
        REWARDS_DISTRIBUTOR = IRewardsDistributor(rewardsDistributor_);
        _protocol = protocol_;
        BALANCES = IBalances(balances_);
    }

    /// @notice Get the supplied, borrowed amounts, and rewards for a specific token and user
    /// @param user The user address
    /// @param token The token address
    /// @return suppliedAmount The amount of the token supplied by the user
    /// @return borrowedAmount The amount of the token borrowed by the user
    /// @return totalRewards The total rewards accrued by the user
    function _getUserData(address user, address token)
        internal
        view
        returns (int256 suppliedAmount, int256 borrowedAmount, int256 totalRewards)
    {
        try DATA_PROVIDER.getUserReserveData(token, user) returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256,
            uint256,
            uint256,
            uint256,
            uint40,
            bool
        ) {
            suppliedAmount = currentATokenBalance.toInt256();
            borrowedAmount = (currentStableDebt + currentVariableDebt).toInt256();
        } catch {
            suppliedAmount = 0;
            borrowedAmount = 0;
        }

        totalRewards = int256(REWARDS_DISTRIBUTOR.getUserAccruedRewards(user, token));
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _underlyingAssetsSupported();
    }

    /// @notice Returns the list of all the underlying assets supported by this oracle.
    /// @dev The returned list may be empty if the oracle cannot determine or provide the supported assets.
    /// @return underlyingAssets The list of underlying asset addresses supported by this oracle (may be empty).
    function _underlyingAssetsSupported() internal view returns (address[] memory) {
        IProtocolDataProvider.TokenData[] memory reserves = DATA_PROVIDER.getAllReservesTokens();

        address[] memory assets = new address[](reserves.length);

        for (uint256 i = 0; i < reserves.length; i++) {
            assets[i] = reserves[i].tokenAddress;
        }

        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance) {
        // Sum all balances for this asset across all positions
        // _buildPositions with asset filter already returns only positions for this asset
        INAVCalculator.Position[] memory positions = _buildPositions(account, asset);
        for (uint256 i = 0; i < positions.length; i++) {
            balance += positions[i].balance;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        address[] memory supportedAssets = _underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            int256 balance = this.getOracleBalanceForAsset(account, asset);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = balance;
                count++;
            }
        }

        // Resize to actual count
        assets = new address[](count);
        amounts = new int256[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
        }
    }

    /// @notice Internal helper that builds all positions for this oracle
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of Position structs from this oracle
    function _buildPositions(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        address[] memory supportedAssets = _underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        if (assetCount == 0) {
            return new INAVCalculator.Position[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](assetCount);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];

            // Apply asset filter if specified
            if (assetFilter != address(0) && asset != assetFilter) {
                continue;
            }

            // Get balance for this asset
            (int256 suppliedAmount, int256 borrowedAmount, int256 totalRewards) = _getUserData(account, asset);
            int256 balance = suppliedAmount - borrowedAmount + totalRewards;

            // Only include non-zero balances
            if (balance != 0) {
                // Get asset info from registry (if registered)
                uint8 decimals;
                string memory symbol;
                try BALANCES.getAssetDecimals(asset) returns (uint8 dec) {
                    decimals = dec;
                } catch {
                    // Asset not registered, skip it (NAVCalculator will filter anyway)
                    continue;
                }
                try BALANCES.getAssetSymbol(asset) returns (string memory sym) {
                    symbol = sym;
                } catch {
                    symbol = "";
                }

                // Build underlying asset struct
                INAVCalculator.Asset memory underlyingAsset =
                    INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});

                // Build position (pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.Position({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    balance: balance,
                    quoteAsset: INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), // Will be set by NAVCalculator
                    value: 0, // Will be calculated by NAVCalculator
                    price: 0, // Will be set by NAVCalculator
                    priceDecimals: 0, // Will be set by NAVCalculator
                    stale: false, // Will be set by NAVCalculator
                    protocol: _protocol,
                    positionDetail: symbol
                });

                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.Position[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        return _buildPositions(account, assetFilter);
    }
}

///@title IPoolDataProvider
///@notice Defines the basic interface of a PoolDataProvider
interface IProtocolDataProvider {
    ///@notice Returns the user data in a reserve
    ///@param asset The address of the underlying asset of the reserve
    ///@param user The address of the user
    ///@return currentATokenBalance The current AToken balance of the user
    ///@return currentStableDebt The current stable debt of the user
    ///@return currentVariableDebt The current variable debt of the user
    ///@return principalStableDebt The principal stable debt of the user
    ///@return scaledVariableDebt The scaled variable debt of the user
    ///@return stableBorrowRate The stable borrow rate of the user
    ///@return liquidityRate The liquidity rate of the reserve
    ///@return stableRateLastUpdated The timestamp of the last update of the user stable rate
    ///@return usageAsCollateralEnabled True if the user is using the asset as collateral, false
    ///        otherwise
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

    /// @notice Struct to hold a token’s symbol and its contract address.
    /// @dev Used when returning lists of reserves or aTokens as symbol–address pairs.
    /// @param symbol The symbol of the token (e.g., "AAVE", "USDC")
    /// @param tokenAddress The address of the token contract
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    /// @notice Returns the list of the existing reserves in the pool.
    /// @dev Handling MKR and ETH in a different way since they do not have standard `symbol` functions.
    /// @return reserveTokens The list of reserves, pairs of symbols and addresses
    function getAllReservesTokens() external view returns (TokenData[] memory reserveTokens);
}

///@title RewardsDistributor
///@notice Accounting contract to manage multiple staking distributions with multiple rewards
interface IRewardsDistributor {
    ///@dev Returns the accrued rewards balance of a user, not including virtually accrued rewards since last
    /// distribution.
    ///@param user The address of the user
    ///@param reward The address of the reward token
    ///@return Unclaimed rewards, not including new distributions
    function getUserAccruedRewards(address user, address reward) external view returns (uint256);
}
