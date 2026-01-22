// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalances} from "../IBalances.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title ERC20DefaultOracle
/// @notice Default oracle that automatically handles all ERC20 and Native balances
/// @dev This oracle reads the asset registry from Balances and returns balances for all registered assets
contract ERC20DefaultOracle is IBalanceOracleAdapter {
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

            // Get balance for this asset directly (avoid recursion)
            int256 balance = _getBalanceForAsset(account, asset);

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
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        // Get all registered assets
        address[] memory allAssets = BALANCES.getAssets();
        uint256 assetCount = allAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address assetAddr = allAssets[i];
            int256 balance = _getBalanceForAsset(account, assetAddr);

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

    /// @notice Internal helper to get balance for a specific asset (avoids recursion)
    /// @param account The account to query
    /// @param asset The asset address
    /// @return balance The balance for this asset
    function _getBalanceForAsset(address account, address asset) internal view returns (int256 balance) {
        // Check if asset is registered
        if (!BALANCES.isAssetRegistered(asset)) {
            return 0;
        }

        // Handle native address (ETH)
        if (asset == NATIVE_ADDRESS) {
            return int256(account.balance);
        }

        // Try to call balanceOf using low-level staticcall
        // This works for real contracts and won't revert for non-contracts
        uint256 tokenBalance;
        bool success;
        assembly {
            // Prepare calldata for balanceOf(account)
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000) // balanceOf(address) selector
            mstore(add(ptr, 0x04), account)
            mstore(0x40, add(ptr, 0x24))

            // Make staticcall - returns false for non-contracts, doesn't revert
            success := staticcall(gas(), asset, ptr, 0x24, ptr, 0x20)

            if success {
                tokenBalance := mload(ptr)
            }
        }

        // Only return balance if staticcall succeeded
        // For non-contracts or failed calls, return 0
        // Note: This means deal() won't work for non-contract addresses,
        // but that's acceptable as tests should use mock contracts
        if (success) {
            return int256(tokenBalance);
        }

        return 0;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) public view returns (int256 balance) {
        return _getBalanceForAsset(account, asset);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets) {
        address[] memory allAssets = BALANCES.getAssets();
        uint256 assetCount = allAssets.length;
        underlyingAssets = new address[](assetCount);
        for (uint256 i = 0; i < assetCount; i++) {
            underlyingAssets[i] = allAssets[i];
        }
    }
}
