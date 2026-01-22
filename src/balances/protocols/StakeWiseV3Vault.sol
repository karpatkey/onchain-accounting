// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "src/errors.sol";

/// @title StakeWise Vault Balance Oracle
/// @author kpk
/// @notice This contract tracks user positions in StakeWise vaults, calculating their net balance
/// by considering both their direct vault shares and any osToken debt positions.
/// The balance calculation works as follows:
/// 1. Gets the user's direct vault shares and converts them to underlying asset value
/// 2. Gets the user's osToken minted debt position (if any) and converts it to underlying asset value
/// 3. Returns the net balance as: vaultAssets - osTokenDebt
contract StakeWiseV3VaultBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The underlying token address
    address public immutable UNDERLYING_TOKEN;

    /// @notice The vault
    IStakeWiseVault public immutable VAULT;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice List of underlying assets supported by this oracle.
    address[] internal _underlyingAssetsSupported;
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Constructor
    //

    /// @param underlyingToken_ The address of the underlying token for this oracle.
    /// @param vault_ The address of the vault.
    /// @param protocol_ Protocol identifier (e.g., "Stakewise v3").
    /// @param positionDetail_ Position detail identifier (e.g., "Some vault").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(
        address underlyingToken_,
        address vault_,
        string memory protocol_,
        string memory positionDetail_,
        address balances_
    ) {
        if (underlyingToken_ == address(0) || vault_ == address(0)) {
            revert InvalidArguments();
        }
        UNDERLYING_TOKEN = underlyingToken_;
        VAULT = IStakeWiseVault(vault_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        BALANCES = IBalances(balances_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance
    function _calculateBalance(address underlyingAsset, address account) internal view returns (int256 balance) {
        if (underlyingAsset != address(UNDERLYING_TOKEN)) {
            revert InvalidArguments();
        }

        uint256 directBalance = VAULT.getShares(account);
        uint256 osTokenPosition = VAULT.osTokenPositions(account);

        uint256 vaultAssets = VAULT.convertToAssets(directBalance);
        uint256 mintedOs = VAULT.convertToAssets(osTokenPosition);

        return vaultAssets.toInt256() - mintedOs.toInt256();
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
        int256 balance = this.getOracleBalanceForAsset(account, supportedAssets[0]);

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
        int256 balance = _calculateBalance(asset, account);

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

/// @notice Interface for interacting with StakeWise v3 vaults
interface IStakeWiseVault {
    /// @notice Converts a given amount of vault shares to the underlying asset amount
    /// @param shares The amount of shares to convert
    /// @return The equivalent amount of underlying assets
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Gets the amount of vault shares owned by an account
    /// @param account The address to check shares for
    /// @return The amount of vault shares owned by the account
    function getShares(address account) external view returns (uint256);

    /// @notice Gets the amount of osTokens minted against an account's position
    /// @param account The address to check osToken positions for
    /// @return The amount of osTokens minted by the account (debt position)
    function osTokenPositions(address account) external view returns (uint256);
}
