// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ERC20DefaultOracle
/// @notice Default oracle that automatically handles all ERC20 and Native balances
/// @dev This oracle reads the asset registry from NAVCalculator and returns balance-only positions for all registered assets
/// @dev Returns PositionBalance structs (balance-only data) without pricing information.
/// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
contract ERC20DefaultOracle is IBalanceOracleAdapter {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Inclusion list: only assets in this set are reported by this oracle
    EnumerableSet.AddressSet private _supportedAssets;

    /// @notice ERC-7528 convention for ETH address representation
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice Protocol identifier for this oracle
    string private constant PROTOCOL = "wallet";

    /// @notice JSON metadata base (no closing `}`) for wallet positions
    string private constant _POSITION_DETAIL = "{\"protocol\":\"wallet\",\"product\":\"Holding\"";

    /// @notice Stable hex identifier for the default oracle (zero address sentinel)
    string private constant _POSITION_ID = "0x0000000000000000000000000000000000000000";

    /// @param navCalculator_ NAVCalculator address (must be non-zero)
    /// @param initialAssets Optional assets to add to the inclusion list during construction (e.g. NATIVE_ADDRESS).
    ///        Used so NAVCalculator.initialize can pre-add native without calling back to the proxy during init.
    constructor(address navCalculator_, address[] memory initialAssets) {
        require(navCalculator_ != address(0), "NAVCalculator cannot be zero address");
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        for (uint256 i = 0; i < initialAssets.length; i++) {
            _supportedAssets.add(initialAssets[i]);
        }
    }

    //
    // Inclusion list (callable only by NAVCalculator)
    //

    /// @notice Add an asset to the default oracle's inclusion list so it reports wallet balances for it
    /// @param asset The asset address (must be registered in NAVCalculator)
    function addSupportedAsset(address asset) external {
        if (msg.sender != address(NAV_CALCULATOR)) revert OnlyNAVCalculator();
        if (!NAV_CALCULATOR.isAssetRegistered(asset)) revert AssetNotFound();
        _supportedAssets.add(asset);
    }

    /// @notice Remove an asset from the default oracle's inclusion list (e.g. to avoid double accounting with a custom oracle)
    /// @param asset The asset address to remove
    function removeSupportedAsset(address asset) external {
        if (msg.sender != address(NAV_CALCULATOR)) revert OnlyNAVCalculator();
        _supportedAssets.remove(asset);
    }

    /// @notice Returns whether the default oracle reports balances for this asset
    function isSupportedByDefault(address asset) external view returns (bool) {
        return _supportedAssets.contains(asset);
    }

    //
    // IBalanceOracleAdapter Implementation
    //

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's ERC20 and native token balances
    /// @dev Returns PositionBalance structs containing wallet balances.
    /// @dev Only returns positions for assets in the inclusion list (_supportedAssets).
    /// @dev Pricing information is added by NAVCalculator when these positions are enriched.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory assetsToProcess;
        if (assetFilter != address(0)) {
            if (!_supportedAssets.contains(assetFilter)) {
                return new INAVCalculator.PositionBalance[](0);
            }
            assetsToProcess = new address[](1);
            assetsToProcess[0] = assetFilter;
        } else {
            assetsToProcess = _getSupportedAssetsArray();
        }

        positions = _buildPositions(account, assetsToProcess);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedList = _getSupportedAssetsArray();
        uint256 assetCount = supportedList.length;

        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address assetAddr = supportedList[i];
            uint256 amount = _getBalanceForAsset(account, assetAddr);

            if (amount != 0) {
                tempAssets[count] = assetAddr;
                tempAmounts[count] = amount;
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
            isDebt[i] = false; // ERC20 balances are always credit
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        public
        view
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0)) {
            return (0, false);
        }
        if (!_supportedAssets.contains(asset)) {
            return (0, false);
        }
        return (_getBalanceForAsset(account, asset), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets) {
        return _getSupportedAssetsArray();
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

    /// @notice Returns the inclusion list as an address array (for enumeration)
    function _getSupportedAssetsArray() internal view returns (address[] memory) {
        uint256 len = _supportedAssets.length();
        address[] memory arr = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            arr[i] = _supportedAssets.at(i);
        }
        return arr;
    }

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

            // Get balance for this asset (always non-negative for this oracle)
            uint256 balance = _getBalanceForAsset(account, asset);

            // Only include non-zero balances
            if (balance != 0) {
                // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
                INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

                // Build position (balance-only, pricing will be added by NAVCalculator)
                // ERC20DefaultOracle always returns credit positions: isDebt = false, amount in uint256
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    amount: balance,
                    isDebt: false,
                    protocol: PROTOCOL,
                    positionDetail: string.concat(_POSITION_DETAIL, "}"),
                    positionId: _POSITION_ID
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
    /// @return balance The balance for this asset as uint256 (always non-negative for ERC20DefaultOracle)
    function _getBalanceForAsset(address account, address asset) internal view returns (uint256 balance) {
        // Handle native address (ETH)
        if (asset == NATIVE_ADDRESS) {
            return account.balance;
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
            return tokenBalance;
        }

        return 0;
    }
}
