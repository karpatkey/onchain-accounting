// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title StakeWise osToken Balance Oracle
/// @author kpk
/// @notice Returns the underlying token equivalent balance for a given amount of StakeWise osTokens held by an account.
/// @dev Queries the osToken contract for the user's share balance, then uses the vault controller's `convertToAssets`
///      to compute the equivalent amount of the underlying asset.
contract StakeWiseV3OsTokenBalanceOracle is IBalanceOracleCustom, IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;

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

    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Constructor
    //

    /// @param osToken_ The address of the osToken.
    /// @param underlyingToken_ The address of the underlying asset.
    /// @param osTokenvaultController_ The address of the OsTokenVaultController.
    /// @param protocol_ Protocol identifier (e.g., "Stakewise v3").
    /// @param positionDetail_ Position detail identifier (e.g., "osToken").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(
        address osToken_,
        address underlyingToken_,
        address osTokenvaultController_,
        string memory protocol_,
        string memory positionDetail_,
        address balances_
    ) {
        if (osToken_ == address(0) || underlyingToken_ == address(0) || osTokenvaultController_ == address(0)) {
            revert InvalidArguments();
        }
        OS_TOKEN = osToken_;
        UNDERLYING_TOKEN = underlyingToken_;
        OS_TOKEN_VAULT_CONTROLLER = IOsTokenVaultController(osTokenvaultController_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        BALANCES = IBalances(balances_);
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        if (underlyingAsset != UNDERLYING_TOKEN) {
            revert InvalidArguments();
        }
        uint256 sharesAmount = IERC20(OS_TOKEN).balanceOf(account);
        uint256 underlyingAmount = OS_TOKEN_VAULT_CONTROLLER.convertToAssets(sharesAmount);
        return underlyingAmount.toInt256();
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId
            || interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance) {
        return this.balanceOf(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account, address assetFilter)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        if (assetFilter != address(0)) {
            return (new address[](0), new int256[](0));
        }

        address[] memory supportedAssets = this.underlyingAssetsSupported();
        int256 balance = this.balanceOf(supportedAssets[0], account);

        if (balance == 0) {
            return (new address[](0), new int256[](0));
        }

        assets = new address[](1);
        amounts = new int256[](1);
        assets[0] = supportedAssets[0];
        amounts[0] = balance;
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
        address asset = supportedAssets[0];

        // Apply asset filter if specified
        if (assetFilter != address(0) && asset != assetFilter) {
            return new INAVCalculator.Position[](0);
        }

        // Get balance for this asset
        int256 balance = this.balanceOf(asset, account);

        // Only include non-zero balances
        if (balance == 0) {
            return new INAVCalculator.Position[](0);
        }

        // Get asset info from registry (if registered)
        uint8 decimals;
        string memory symbol;
        try BALANCES.getAssetDecimals(asset) returns (uint8 dec) {
            decimals = dec;
        } catch {
            // Asset not registered, return empty
            return new INAVCalculator.Position[](0);
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
        positions = new INAVCalculator.Position[](1);
        positions[0] = INAVCalculator.Position({
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

/// @notice Interface for interacting with StakeWise v3 osToken Vault Controllers
interface IOsTokenVaultController {
    /// @notice Converts a given amount of vault shares to the underlying asset amount
    /// @param shares The amount of shares to convert
    /// @return assets The equivalent amount of underlying assets
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
