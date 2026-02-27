// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title StakeWise osToken Balance Oracle
/// @author kpk
/// @notice Returns the underlying token equivalent balance for a given amount of StakeWise osTokens held by an account.
/// @dev Queries the osToken contract for the user's share balance, then uses the vault controller's `convertToAssets`
///      to compute the equivalent amount of the underlying asset.
contract StakeWiseV3OsTokenBalanceOracle is IBalanceOracleAdapter {
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
    // State
    //

    /// @notice The osToken whose balance this oracle wraps.
    address public immutable OS_TOKEN;

    /// @notice The underlying token of the osToken for which we compute equivalent balances.
    address public immutable UNDERLYING_TOKEN;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice The StakeWise vault controller contract interface
    IOsTokenVaultController public immutable OS_TOKEN_VAULT_CONTROLLER;

    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param osToken_ The address of the osToken.
    /// @param underlyingToken_ The address of the underlying asset.
    /// @param osTokenvaultController_ The address of the OsTokenVaultController.
    /// @param protocol_ Protocol identifier (e.g., "Stakewise v3").
    /// @param positionDetail_ Position detail identifier (e.g., "osToken").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(
        address osToken_,
        address underlyingToken_,
        address osTokenvaultController_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        if (osToken_ == address(0) || underlyingToken_ == address(0) || osTokenvaultController_ == address(0)) {
            revert InvalidArguments();
        }
        require(osTokenvaultController_.code.length > 0, "OsTokenVaultController must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        OS_TOKEN = osToken_;
        UNDERLYING_TOKEN = underlyingToken_;
        OS_TOKEN_VAULT_CONTROLLER = IOsTokenVaultController(osTokenvaultController_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance as uint256 (always non-negative for osToken)
    function _calculateBalance(address underlyingAsset, address account) internal view returns (uint256 balance) {
        if (underlyingAsset != UNDERLYING_TOKEN) {
            revert InvalidArguments();
        }
        uint256 sharesAmount = IERC20(OS_TOKEN).balanceOf(account);
        return OS_TOKEN_VAULT_CONTROLLER.convertToAssets(sharesAmount); // osToken is always credit (positive)
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
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
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        // Return zero for unsupported or invalid tokens (adapter convention)
        if (asset == address(0) || asset != UNDERLYING_TOKEN) {
            return (0, false);
        }
        return (_calculateBalance(asset, account), false); // osToken balance is always credit
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
        bool[] memory tempIsDebt = new bool[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            uint256 balance = _calculateBalance(asset, account);
            if (balance != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = balance;
                tempIsDebt[count] = false; // osToken balance is always credit
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
    /// @notice Returns balance-only positions for the account's StakeWise V3 OsToken positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by StakeWise and registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData;
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    uint256 balance = _calculateBalance(assetFilter, account);
                    if (balance != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: balance, isDebt: false});
                    } else {
                        assetBalanceData = new AssetBalanceData[](0);
                    }
                    break;
                }
            }
        } else {
            // Pre-allocate temporary array (max size)
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                uint256 balance = _calculateBalance(registeredSupportedAssets[i], account);
                if (balance != 0) {
                    tempData[count] =
                        AssetBalanceData({asset: registeredSupportedAssets[i], amount: balance, isDebt: false});
                    count++;
                }
            }

            // Resize to actual count
            assetBalanceData = new AssetBalanceData[](count);
            for (uint256 i = 0; i < count; i++) {
                assetBalanceData[i] = tempData[i];
            }
        }
        positions = _buildPositions(assetBalanceData);
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
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this oracle
    /// @param assetBalanceData Array of AssetBalanceData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets are guaranteed to be registered (filtered in getOraclePositions).
    function _buildPositions(AssetBalanceData[] memory assetBalanceData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetBalanceData.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](assetBalanceData.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetBalanceData.length; i++) {
            address asset = assetBalanceData[i].asset;

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

/// @notice Interface for interacting with StakeWise v3 osToken Vault Controllers
interface IOsTokenVaultController {
    /// @notice Converts a given amount of vault shares to the underlying asset amount
    /// @param shares The amount of shares to convert
    /// @return assets The equivalent amount of underlying assets
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
