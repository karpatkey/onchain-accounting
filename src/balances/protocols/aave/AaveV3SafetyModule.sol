// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "../../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

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
    // Type Definitions
    //

    /// @notice Asset balance data structure
    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State Variables
    //

    /// @notice The stake token (e.g. stkAAVE, stkABPT) contract
    IStakeToken public immutable STAKE_CONTRACT;

    /// @notice The reward token address
    address public immutable REWARD_TOKEN;

    /// @notice The underlying token address which is staked
    address public immutable STAKED_TOKEN;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;

    //
    // Constructor
    //

    /// @notice Creates a new Aave v3 Safety Module balance oracle.
    /// @param stakeToken Address of the stake token (e.g. stkAAVE) contract.
    /// @param protocol_ Protocol identifier (e.g., "Aave v3").
    /// @param positionDetail_ Position detail identifier (e.g., "Safety Module").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access.
    constructor(address stakeToken, string memory protocol_, string memory positionDetail_, address navCalculator_) {
        if (stakeToken == address(0)) revert InvalidArguments();
        require(stakeToken.code.length > 0, "StakeToken must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        STAKE_CONTRACT = IStakeToken(stakeToken);
        REWARD_TOKEN = STAKE_CONTRACT.REWARD_TOKEN();
        STAKED_TOKEN = STAKE_CONTRACT.STAKED_TOKEN();

        if (REWARD_TOKEN == address(0) || STAKED_TOKEN == address(0)) revert InvalidArguments();

        _protocol = protocol_;
        _positionDetail = positionDetail_;
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

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        // Return zero for zero account or unsupported/invalid tokens (adapter convention)
        if (
            account == address(0) || asset == address(0)
                || (asset != address(STAKED_TOKEN) && asset != address(REWARD_TOKEN))
        ) {
            return (0, false);
        }
        return (_calculateBalance(asset, account), false); // Safety Module positions are always credit
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            uint256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = balance;
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
            isDebt[i] = false;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Aave v3 Safety Module positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev Only returns positions for assets that are both supported by the protocol and registered in NAVCalculator.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }
        // Get supported assets from this oracle
        address[] memory supportedAssets = this.underlyingAssetsSupported();

        // Get registered assets from NAVCalculator
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        // Apply asset filter if specified
        address[] memory filteredAssets;
        if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            bool found = false;
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    found = true;
                    break;
                }
            }
            if (found) {
                filteredAssets = new address[](1);
                filteredAssets[0] = assetFilter;
            } else {
                filteredAssets = new address[](0);
            }
        } else {
            filteredAssets = registeredSupportedAssets;
        }

        // Pre-fetch balance data for filtered assets
        AssetBalanceData[] memory assetBalanceData = new AssetBalanceData[](filteredAssets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < filteredAssets.length; i++) {
            address asset = filteredAssets[i];
            uint256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances (credits-only: amount = balance, isDebt = false)
            if (balance != 0) {
                assetBalanceData[count] = AssetBalanceData({asset: asset, amount: balance, isDebt: false});
                count++;
            }
        }

        // Resize to actual count
        AssetBalanceData[] memory finalAssetBalanceData = new AssetBalanceData[](count);
        for (uint256 i = 0; i < count; i++) {
            finalAssetBalanceData[i] = assetBalanceData[i];
        }

        // Build positions from pre-fetched data
        positions = _buildPositions(finalAssetBalanceData);
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

    //
    // Internal Functions - Aave Safety Module Data Retrieval
    //

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance as uint256 (always non-negative for safety module)
    /// @dev Returns equivalent balance for either:
    /// - Staked tokens: Returns the withdrawable amount of underlying tokens
    /// - Reward tokens: Returns the current unclaimed rewards plus newly accrued rewards
    /// The staked token can be the same as the reward token (i.e. with stkAAVE, underlyingAsset = AAVE = STAKED_TOKEN =
    /// REWARD_TOKEN).
    function _calculateBalance(address underlyingAsset, address account) internal view returns (uint256 balance) {
        if (underlyingAsset != address(STAKED_TOKEN) && underlyingAsset != address(REWARD_TOKEN)) {
            revert InvalidArguments();
        }

        uint256 total = 0;

        // If querying staked token balance
        if (underlyingAsset == STAKED_TOKEN) {
            total += STAKE_CONTRACT.previewRedeem(STAKE_CONTRACT.balanceOf(account));
        }

        // If querying reward token balance. In some cases the staked token can be the same as the reward token (i.e
        // stkAAVE).
        if (underlyingAsset == REWARD_TOKEN) {
            total += STAKE_CONTRACT.getTotalRewardsBalance(account);
        }

        return total; // Safety module positions are always credit (positive)
    }

    //
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this oracle
    /// @param assetBalanceData Array of AssetBalanceData with pre-fetched balance data
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets in assetBalanceData are guaranteed to be registered in NAVCalculator.
    function _buildPositions(AssetBalanceData[] memory assetBalanceData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetBalanceData.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array (one position per asset)
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](assetBalanceData.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetBalanceData.length; i++) {
            address asset = assetBalanceData[i].asset;
            // AssetBalanceData already has amount and isDebt, no need to extract

            // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

            // Build position (balance-only, pricing will be added by NAVCalculator)
            tempPositions[positionCount] = INAVCalculator.PositionBalance({
                underlyingAsset: underlyingAsset,
                balanceOracle: address(this),
                amount: assetBalanceData[i].amount,
                isDebt: assetBalanceData[i].isDebt,
                protocol: _protocol,
                positionDetail: _positionDetail
            });

            positionCount++;
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
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
