// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "../BalanceAdapterBase.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ERC20DefaultBalanceAdapter
/// @notice Default adapter that automatically handles all ERC20 and Native balances
/// @dev This adapter reads the asset registry from NAVCalculator and returns balance-only positions for all registered assets
/// @dev Returns PositionBalance structs (balance-only data) without pricing information.
/// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
/// @author KPK
contract ERC20DefaultBalanceAdapter is BalanceAdapterBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Inclusion list: only assets in this set are reported by this adapter
    EnumerableSet.AddressSet private _supportedAssets;

    /// @notice ERC-7528 convention for ETH address representation
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice 3-level protocol taxonomy for wallet positions. Wallet is a single-product ecosystem, so all three
    ///         levels (brand / id / sub-id) collapse to the same `ProtocolIds.WALLET` slug.
    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.WALLET;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.WALLET;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.WALLET;

    /// @param navCalculator_ NAVCalculator address (must be non-zero)
    /// @param initialAssets Optional assets to add to the inclusion list during construction (e.g. NATIVE_ADDRESS).
    ///        Used so NAVCalculator.initialize can pre-add native without calling back to the proxy during init.
    constructor(address navCalculator_, address[] memory initialAssets) {
        if (navCalculator_ == address(0)) revert InvalidArguments();
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
        // The seed list is NOT registry-checked here: this constructor is invoked by
        // NAVRegistryLib.deployDefaultAdapter *during NAVCalculator.initialize*, which runs inside the proxy's
        // own constructor — at that point the proxy has no deployed code yet, so an external
        // NAV_CALCULATOR.isAssetRegistered(...) callback would revert with "call to non-contract". The only
        // caller seeds exactly [NATIVE_ADDRESS], which initialize registers one line before deploying this
        // adapter, so a misconfigured seed is not reachable. Post-deploy entries go through addSupportedAsset,
        // which does enforce isAssetRegistered.
        for (uint256 i = 0; i < initialAssets.length; i++) {
            _supportedAssets.add(initialAssets[i]);
        }
    }

    //
    // Inclusion list (callable only by NAVCalculator)
    //

    /// @notice Add an asset to the default adapter's inclusion list so it reports wallet balances for it
    /// @param asset The asset address (must be registered in NAVCalculator)
    function addSupportedAsset(address asset) external {
        if (msg.sender != address(NAV_CALCULATOR)) revert OnlyNAVCalculator();
        if (!NAV_CALCULATOR.isAssetRegistered(asset)) revert AssetNotFound();
        _supportedAssets.add(asset);
    }

    /// @notice Remove an asset from the default adapter's inclusion list (e.g. to avoid double accounting with a custom adapter)
    /// @param asset The asset address to remove
    function removeSupportedAsset(address asset) external {
        if (msg.sender != address(NAV_CALCULATOR)) revert OnlyNAVCalculator();
        _supportedAssets.remove(asset);
    }

    /// @notice Returns whether the default adapter reports balances for this asset
    function isSupportedByDefault(address asset) external view returns (bool) {
        return _supportedAssets.contains(asset);
    }

    //
    // IBalanceAdapter Implementation
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns balance-only positions for the account's ERC20 and native token balances
    /// @dev Returns PositionBalance structs containing wallet balances.
    /// @dev Only returns positions for assets in the inclusion list (_supportedAssets).
    /// @dev Pricing information is added by NAVCalculator when these positions are enriched.
    function getAdapterPositions(address account, address assetFilter)
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

        // Build via an external self-staticcall so the row-building runs in a fresh frame whose only params are
        // `(account, assets)` — this keeps `getAdapterPositions`'s `account`/`assetFilter` params (which sit at the
        // stack bottom for its whole body) off the build loop's stack, which otherwise overflows the via_ir limit.
        // Mirrors the assisted adapters' `this.positionLegs(...)` / NAVCalculator's `this.decodeStringArray` pattern.
        positions = this.buildPositionsSelf(account, assetsToProcess);
    }

    /// @notice External self-call entrypoint for `_buildPositions` (see the call site in `getAdapterPositions`).
    /// @dev `msg.sender`-guarded to `address(this)` so it is not a usable external surface — it exists only to give
    ///      the build loop its own stack frame. `view`, so the self-call is a staticcall.
    function buildPositionsSelf(address account, address[] calldata assets)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        return _buildPositions(account, assets);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
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

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
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

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets) {
        return _getSupportedAssetsArray();
    }

    //
    // IERC165 Implementation
    //

    function protocolName() external pure returns (string memory) {
        return "Wallet";
    }

    function positionLabels(bytes calldata positionId) external view override returns (string[] memory) {
        string memory leaf;
        if (positionId.length == 0) {
            leaf = "";
        } else {
            address addr = abi.decode(positionId, (address));
            if (addr == NATIVE_ADDRESS) {
                leaf = "native";
            } else {
                leaf = LabelLib.symbol(addr, "");
            }
        }
        // Fail-open: no derivable label → empty array (IPositionDescribable convention), not `[""]`,
        // so consumers don't render a blank breadcrumb segment.
        if (bytes(leaf).length == 0) return new string[](0);
        string[] memory out = new string[](1);
        out[0] = leaf;
        return out;
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
        bool found;
        (assetInfo, found) = RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), asset);
        if (!found) revert AssetNotFound();
    }

    /// @notice Internal helper that builds all positions for this adapter
    /// @param account The account to query
    /// @param assets Array of assets to build positions for
    /// @return positions Array of balance-only PositionBalance structs from this adapter
    /// @dev Creates one position per asset with non-zero balance
    /// @dev All positions are balance-only; pricing is added by NAVCalculator during enrichment
    function _buildPositions(address account, address[] memory assets)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        uint256 len = assets.length;
        if (len == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pass 1: collect the assets with a non-zero balance. This is the only pass that needs `account`; it builds
        // no structs, so the loop stays light. (Kept separate from the row-building pass to stay under the via_ir
        // stack limit — building the 11-field PositionBalance while `account`/`assetFilter` are still live overflows.)
        address[] memory hitAssets = new address[](len);
        uint256[] memory hitBalances = new uint256[](len);
        uint256 positionCount = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 balance = _getBalanceForAsset(account, assets[i]);
            if (balance != 0) {
                hitAssets[positionCount] = assets[i];
                hitBalances[positionCount] = balance;
                positionCount++;
            }
        }

        // Pass 2: build the rows in a dedicated function. Keeping it separate (params are only the hit arrays + count)
        // ensures the row-building loop's stack does NOT also carry `getAdapterPositions`'s `account`/`assetFilter`
        // params — which sit at the stack bottom for that function's whole body and were tipping the via_ir limit.
        positions = _rows(hitAssets, hitBalances, positionCount);
    }

    /// @dev Builds `count` credit rows from the collected (asset, balance) hits. Separate from the collection pass so
    ///      its loop's stack is free of the outer `account`/`assetFilter` params (via_ir stack limit).
    function _rows(address[] memory hitAssets, uint256[] memory hitBalances, uint256 count)
        private
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = _row(_getAssetInfo(hitAssets[i]), hitBalances[i], hitAssets[i]);
        }
    }

    /// @dev Builds one wallet PositionBalance field-by-field (avoids an 11-field literal inside the per-asset loop,
    ///      which overflows the via_ir stack). positionId = abi.encode(asset); positionInstanceId defaults to bytes32(0).
    function _row(INAVCalculator.Asset memory underlyingAsset, uint256 balance, address asset)
        private
        view
        returns (INAVCalculator.PositionBalance memory row)
    {
        row.balanceAsset = underlyingAsset;
        row.balanceAdapter = address(this);
        row.amount = balance;
        row.protocolBrand = PROTOCOL_BRAND;
        row.protocolId = PROTOCOL_ID;
        row.protocolSubId = PROTOCOL_SUB_ID;
        row.positionId = abi.encode(asset);
        row.positionKind = PositionKind.Wallet;
        // isDebt, isLocked default false; positionInstanceId defaults to bytes32(0).
    }

    /// @notice Internal helper to get balance for a specific asset (avoids recursion)
    /// @param account The account to query
    /// @param asset The asset address
    /// @return balance The balance for this asset as uint256 (always non-negative for ERC20DefaultBalanceAdapter)
    function _getBalanceForAsset(address account, address asset) internal view returns (uint256 balance) {
        // Handle native address (ETH)
        if (asset == NATIVE_ADDRESS) {
            return account.balance;
        }

        // Read balanceOf(account) via low-level staticcall so a non-standard/non-contract asset cannot revert
        // the NAV scan. IMPORTANT: a staticcall to a code-less address (or a token whose balanceOf returns
        // void/short data) returns success=true with returndatasize() < 32 — the EVM then leaves the output
        // region untouched. We therefore (a) write the return into a FRESH, zeroed scratch word distinct from
        // the calldata buffer, and (b) only treat it as a balance when a full 32-byte word was actually
        // returned. Without this, the leftover calldata (the balanceOf selector word) would be misread as a
        // huge phantom balance, corrupting NAV.
        uint256 tokenBalance;
        bool success;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000) // balanceOf(address) selector
            mstore(add(ptr, 0x04), account)
            // Output goes in a separate, 32-byte-aligned scratch word at ptr+0x40 (clear of the 0x24-byte
            // calldata at ptr..ptr+0x24). The free-memory pointer is advanced to ptr+0x60 — kept 32-byte
            // aligned so later Solidity allocations in this call (e.g. _buildPositions arrays) are not corrupted.
            let outPtr := add(ptr, 0x40)
            mstore(outPtr, 0) // zero the output word so a short/empty return reads as 0, never stale memory
            mstore(0x40, add(outPtr, 0x20))

            success := staticcall(gas(), asset, ptr, 0x24, outPtr, 0x20)

            // Only a full-word return is a real balance; code-less/void/short returns stay 0.
            if and(success, gt(returndatasize(), 0x1f)) { tokenBalance := mload(outPtr) }
        }

        return tokenBalance;
    }
}
