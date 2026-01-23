// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title ERC20DefaultOracle
/// @notice Default oracle that automatically handles all ERC20 and Native balances
/// @dev This oracle reads the asset registry from NAVCalculator and returns balance-only positions for all registered assets
/// @dev Returns PositionBalance structs (balance-only data) without pricing information.
/// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
contract ERC20DefaultOracle is IBalanceOracleAdapter {
    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice ERC-7528 convention for ETH address representation
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice Protocol identifier for this oracle
    string private constant PROTOCOL = "wallet";

    constructor(address navCalculator_) {
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IBalanceOracleAdapter Implementation
    //

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's ERC20 and native token balances
    /// @dev Returns PositionBalance structs containing wallet balances.
    /// @dev Only returns positions for assets that are registered in NAVCalculator.
    /// @dev Pricing information is added by NAVCalculator when these positions are enriched.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // Get all registered assets from NAVCalculator
        address[] memory registeredAssets = NAV_CALCULATOR.assets();

        address[] memory assetsToProcess;
        if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered assets
            for (uint256 i = 0; i < registeredAssets.length; i++) {
                if (registeredAssets[i] == assetFilter) {
                    assetsToProcess = new address[](1);
                    assetsToProcess[0] = assetFilter;
                    break;
                }
            }
            // If assetFilter not found, return empty array
            if (assetsToProcess.length == 0) {
                return new INAVCalculator.PositionBalance[](0);
            }
        } else {
            assetsToProcess = registeredAssets;
        }

        positions = _buildPositions(account, assetsToProcess);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        // Get all registered assets from NAVCalculator
        address[] memory registeredAssets = NAV_CALCULATOR.assets();
        uint256 assetCount = registeredAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address assetAddr = registeredAssets[i];
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

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) public view returns (int256 balance) {
        return _getBalanceForAsset(account, asset);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets) {
        return NAV_CALCULATOR.assets();
    }

    //
    // IERC165 Implementation
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // Internal Functions
    //

    /// @notice Gets asset information from NAVCalculator by iterating through registered assets
    /// @param asset The asset address to look up
    /// @return assetInfo The Asset struct containing asset address, symbol, and decimals
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory assetInfo) {
        uint256 assetCount = NAV_CALCULATOR.assetCount();
        for (uint256 i = 0; i < assetCount; i++) {
            INAVCalculator.Asset memory a = NAV_CALCULATOR.assetAt(i);
            if (a.asset == asset) {
                return a;
            }
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Internal helper that builds all positions for this oracle
    /// @param account The account to query
    /// @param assets Array of assets to build positions for
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Creates one position per asset with non-zero balance
    /// @dev All positions are balance-only; pricing is added by NAVCalculator during enrichment
    function _buildPositions(address account, address[] memory assets)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assets.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.PositionBalance[] memory tempPositions = new INAVCalculator.PositionBalance[](assets.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            // Get balance for this asset directly (avoid recursion)
            int256 balance = _getBalanceForAsset(account, asset);

            // Only include non-zero balances
            if (balance != 0) {
                // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
                INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

                // Build position (balance-only, pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    balance: balance,
                    protocol: PROTOCOL,
                    positionDetail: "Idle"
                });

                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @notice Internal helper to get balance for a specific asset (avoids recursion)
    /// @param account The account to query
    /// @param asset The asset address
    /// @return balance The balance for this asset
    function _getBalanceForAsset(address account, address asset) internal view returns (int256 balance) {
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
}
