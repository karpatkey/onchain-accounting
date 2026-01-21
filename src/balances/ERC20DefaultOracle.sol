// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalances} from "./IBalances.sol";
import {IBalanceOracleAdapter} from "./IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title ERC20DefaultOracle
/// @notice Default oracle that automatically handles all ERC20 and Native balances
/// @dev This oracle reads the asset registry from Balances and returns balances for all registered assets
contract ERC20DefaultOracle is IBalanceOracleAdapter, IERC165 {
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    /// @notice ERC-7528 convention for ETH address representation
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice Protocol identifier for this oracle
    string private constant PROTOCOL = "wallet";

    constructor(address balances_) {
        BALANCES = IBalances(balances_);
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
        // Get all registered assets
        address[] memory allAssets = BALANCES.getAssets();
        uint256 assetCount = allAssets.length;

        if (assetCount == 0) {
            return new INAVCalculator.Position[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](assetCount);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = allAssets[i];

            // Apply asset filter if specified
            if (assetFilter != address(0) && asset != assetFilter) {
                continue;
            }

            // Get balance for this asset
            int256 balance = getOracleBalanceForAsset(account, asset);

            // Only include non-zero balances
            if (balance != 0) {
                // Get asset info
                uint8 decimals = BALANCES.getAssetDecimals(asset);
                string memory symbol = BALANCES.getAssetSymbol(asset);

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
                    protocol: PROTOCOL,
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

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account, address asset)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        if (asset != address(0)) {
            // Return empty arrays when asset filter is specified
            // Caller should use getOracleBalanceForAsset() instead
            return (new address[](0), new int256[](0));
        }

        // Get all registered assets
        address[] memory allAssets = BALANCES.getAssets();
        uint256 assetCount = allAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address assetAddr = allAssets[i];
            int256 balance = getOracleBalanceForAsset(account, assetAddr);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = assetAddr;
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

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) public view returns (int256 balance) {
        if (asset == NATIVE_ADDRESS) {
            // Native balance
            balance = int256(account.balance);
        } else {
            // ERC20 balance
            balance = int256(IERC20(asset).balanceOf(account));
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
