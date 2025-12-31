// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
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
contract AaveV3InstanceBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using Math for uint256;
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The address of the data provider
    IProtocolDataProvider public immutable dataProvider;
    /// @notice The address of the incentives controller
    IRewardsDistributor public immutable rewardsDistributor;
    /// @notice Position metadata tags describing the DeFi position this oracle is associated to.
    PositionMetadata private _positionMetadata;

    //
    // Constructor
    //

    /// @param dataProvider_ The address of the Aave v3 Pool Data Provider contract.
    /// @param rewardsDistributor_ The address of the Aave v3 Rewards Distributor contract.
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(address dataProvider_, address rewardsDistributor_, PositionMetadata memory positionMetadata_) {
        dataProvider = IProtocolDataProvider(dataProvider_);
        rewardsDistributor = IRewardsDistributor(rewardsDistributor_);
        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        address[] memory supportedAssets = _underlyingAssetsSupported();
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == underlyingAsset) {
                (int256 suppliedAmount, int256 borrowedAmount, int256 totalRewards) =
                    _getUserData(account, underlyingAsset);
                int256 balance = suppliedAmount - borrowedAmount;
                return balance + totalRewards;
            }
        }
        revert InvalidArguments();
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
        try dataProvider.getUserReserveData(token, user) returns (
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

        totalRewards = int256(rewardsDistributor.getUserAccruedRewards(user, token));
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        return _underlyingAssetsSupported();
    }

    /// @notice Returns the list of all the underlying assets supported by this oracle.
    /// @dev The returned list may be empty if the oracle cannot determine or provide the supported assets.
    /// @return underlyingAssets The list of underlying asset addresses supported by this oracle (may be empty).
    function _underlyingAssetsSupported() internal view returns (address[] memory) {
        IProtocolDataProvider.TokenData[] memory reserves = dataProvider.getAllReservesTokens();

        address[] memory assets = new address[](reserves.length);

        for (uint256 i = 0; i < reserves.length; i++) {
            assets[i] = reserves[i].tokenAddress;
        }

        return assets;
    }

    /// @inheritdoc IBalanceOracleCustom
    function positionMetadata() external view override returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
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
