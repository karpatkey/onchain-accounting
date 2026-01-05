// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import "src/errors.sol";

/// @title Aave v3 Safety Module Balance Oracle
/// @author kpk
/// @notice Tracks user positions in the Aave v3 Safety Module, calculating balances for both staked token and rewards
/// accrued. Returned balances are denominated in terms of the underlying staked token.
contract AaveV3SafetyModuleBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The stake token (e.g. stkAAVE, stkABPT) contract
    IStakeToken public immutable stakeContract;

    /// @notice The reward token address
    address public immutable rewardToken;

    /// @notice The underlying token address which is staked
    address public immutable stakedToken;

    /// @notice Position metadata tags describing the DeFi position this oracle is associated to
    PositionMetadata private _positionMetadata;

    //
    // Constructor
    //

    /// @notice Creates a new Aave v3 Safety Module balance oracle.
    /// @param stakeToken Address of the stake token (e.g. stkAAVE) contract.
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(address stakeToken, PositionMetadata memory positionMetadata_) {
        if (stakeToken == address(0)) revert InvalidArguments();

        stakeContract = IStakeToken(stakeToken);
        rewardToken = stakeContract.REWARD_TOKEN();
        stakedToken = stakeContract.STAKED_TOKEN();

        if (rewardToken == address(0) || stakedToken == address(0)) revert InvalidArguments();

        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    /// @dev Returns equivalent balance for either:
    /// - Staked tokens: Returns the withdrawable amount of underlying tokens
    /// - Reward tokens: Returns the current unclaimed rewards plus newly accrued rewards
    /// The staked token can be the same as the reward token (i.e. with stkAAVE, underlyingAsset = AAVE = stakedToken =
    /// rewardToken).
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        if (underlyingAsset != address(stakedToken) && underlyingAsset != address(rewardToken)) {
            revert InvalidArguments();
        }

        int256 total = 0;

        // If querying staked token balance
        if (underlyingAsset == stakedToken) {
            total += stakeContract.previewRedeem(stakeContract.balanceOf(account)).toInt256();
        }

        // If querying reward token balance. In some cases the staked token can be the same as the reward token (i.e
        // stkAAVE).
        if (underlyingAsset == rewardToken) {
            total += stakeContract.getTotalRewardsBalance(account).toInt256();
        }

        return total;
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        if (stakedToken == rewardToken) {
            // If staked and reward tokens are the same, return only one address
            address[] memory assets = new address[](1);
            assets[0] = stakedToken;
            return assets;
        } else {
            address[] memory assets = new address[](2);
            assets[0] = stakedToken;
            assets[1] = rewardToken;
            return assets;
        }
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

/// @notice Interface for the Aave StakeToken contract
/// https://etherscan.io/address/0x50f9d4e28309303f0cdcac8af0b569e8b75ab857#code
interface IStakeToken {
    /// @notice Address of the reward token
    /// @return address The contract address of the reward token
    //solhint-disable-next-line func-name-mixedcase
    function REWARD_TOKEN() external view returns (address);

    /// @notice Address of the underlying staked token
    /// @return address The contract address of the staked token
    //solhint-disable-next-line func-name-mixedcase
    function STAKED_TOKEN() external view returns (address);

    /// @notice Get the balance of tokens for an account
    /// @param account Address to check balance for
    /// @return Amount of tokens held
    function balanceOf(address account) external view returns (uint256);

    /// @notice Preview amount of underlying tokens for shares
    /// @param shares Amount of shares to preview
    /// @return Amount of underlying tokens
    function previewRedeem(uint256 shares) external view returns (uint256);

    /// @dev Return the total rewards pending to claim by an staker
    /// @param staker The staker address
    /// @return The rewards
    function getTotalRewardsBalance(address staker) external view returns (uint256);
}
