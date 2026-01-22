// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Aave v3 Safety Module Balance Oracle
/// @author kpk
/// @notice Tracks user positions in the Aave v3 Safety Module, calculating BALANCES for both staked token and rewards
/// accrued. Returned BALANCES are denominated in terms of the underlying staked token.
contract AaveV3SafetyModuleBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The stake token (e.g. stkAAVE, stkABPT) contract
    IStakeToken public immutable STAKE_CONTRACT;

    /// @notice The reward token address
    address public immutable REWARD_TOKEN;

    /// @notice The underlying token address which is staked
    address public immutable STAKED_TOKEN;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Constructor
    //

    /// @notice Creates a new Aave v3 Safety Module balance oracle.
    /// @param stakeToken Address of the stake token (e.g. stkAAVE) contract.
    /// @param protocol_ Protocol identifier (e.g., "Aave v3").
    /// @param positionDetail_ Position detail identifier (e.g., "Safety Module").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(address stakeToken, string memory protocol_, string memory positionDetail_, address balances_) {
        if (stakeToken == address(0)) revert InvalidArguments();

        STAKE_CONTRACT = IStakeToken(stakeToken);
        REWARD_TOKEN = STAKE_CONTRACT.REWARD_TOKEN();
        STAKED_TOKEN = STAKE_CONTRACT.STAKED_TOKEN();

        if (REWARD_TOKEN == address(0) || STAKED_TOKEN == address(0)) revert InvalidArguments();

        _protocol = protocol_;
        _positionDetail = positionDetail_;
        BALANCES = IBalances(balances_);
    }

    //
    //

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance
    /// @dev Returns equivalent balance for either:
    /// - Staked tokens: Returns the withdrawable amount of underlying tokens
    /// - Reward tokens: Returns the current unclaimed rewards plus newly accrued rewards
    /// The staked token can be the same as the reward token (i.e. with stkAAVE, underlyingAsset = AAVE = STAKED_TOKEN =
    /// REWARD_TOKEN).
    function _calculateBalance(address underlyingAsset, address account) internal view returns (int256) {
        if (underlyingAsset != address(STAKED_TOKEN) && underlyingAsset != address(REWARD_TOKEN)) {
            revert InvalidArguments();
        }

        int256 total = 0;

        // If querying staked token balance
        if (underlyingAsset == STAKED_TOKEN) {
            total += STAKE_CONTRACT.previewRedeem(STAKE_CONTRACT.balanceOf(account)).toInt256();
        }

        // If querying reward token balance. In some cases the staked token can be the same as the reward token (i.e
        // stkAAVE).
        if (underlyingAsset == REWARD_TOKEN) {
            total += STAKE_CONTRACT.getTotalRewardsBalance(account).toInt256();
        }

        return total;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        if (STAKED_TOKEN == REWARD_TOKEN) {
            // If staked and reward tokens are the same, return only one address
            address[] memory assets = new address[](1);
            assets[0] = STAKED_TOKEN;
            return assets;
        } else {
            address[] memory assets = new address[](2);
            assets[0] = STAKED_TOKEN;
            assets[1] = REWARD_TOKEN;
            return assets;
        }
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
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero BALANCES
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
        address[] memory supportedAssets = this.underlyingAssetsSupported();
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
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero BALANCES
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
                    positionDetail: _positionDetail
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
