// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {InvalidArguments} from "src/errors.sol";

/// @title ISavingsUSDS Interface
/// @notice Interface for interacting with the Savings USDS (sUSDS) vault
interface ISavingsUSDS is IERC4626 {
    /// @notice Returns the address of the underlying USDS token
    /// @return Address of the USDS stablecoin
    function usds() external view returns (address);
}

/// @title SavingsUSDS Balance Oracle
/// @notice Balance oracle for Savings USDS (sUSDS), an ERC4626 yield-bearing vault for USDS stablecoin
/// This contract provides balance information by converting sUSDS vault shares to their underlying USDS value
contract SkySavingsUsdsBalanceOracle is IBalanceOracleCustom, IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The underlying USDS stablecoin address
    address public immutable USDS;

    /// @notice The Savings USDS (sUSDS) vault contract
    ISavingsUSDS public immutable SAVINGS_USDS;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable balances;

    //
    // Constructor
    //

    /// @notice Initializes the balance oracle for Savings USDS. Reverts if savingsUsds_ is zero address
    /// @param savingsUsds_ Address of the Savings USDS (sUSDS) vault contract
    /// @param protocol_ Protocol identifier (e.g., "Sky").
    /// @param positionDetail_ Position detail identifier (e.g., "Savings USDS").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(address savingsUsds_, string memory protocol_, string memory positionDetail_, address balances_) {
        if (savingsUsds_ == address(0)) revert InvalidArguments();
        SAVINGS_USDS = ISavingsUSDS(savingsUsds_);
        USDS = SAVINGS_USDS.usds();
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        balances = IBalances(balances_);
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        // Ensure token matches the underlying USDS token
        if (underlyingAsset != USDS) {
            revert InvalidArguments();
        }
        // Get user's sUSDS balance and convert to underlying USDS amount:
        // 1. balanceOf() - Get user's sUSDS vault shares
        // 2. convertToAssets() - Convert shares to USDS based on current exchange rate
        // 3. toInt256() - Convert uint256 to int256 for interface compatibility
        return SAVINGS_USDS.convertToAssets(SAVINGS_USDS.balanceOf(account)).toInt256();
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = USDS; // Only USDS is supported
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
        try balances.getAssetDecimals(asset) returns (uint8 dec) {
            decimals = dec;
        } catch {
            // Asset not registered, return empty
            return new INAVCalculator.Position[](0);
        }
        try balances.getAssetSymbol(asset) returns (string memory sym) {
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
