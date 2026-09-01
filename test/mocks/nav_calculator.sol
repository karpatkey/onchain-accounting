// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {PriceFeedNotSet} from "src/errors.sol";

/// @title Mock_NAVCalculator
/// @notice Mock implementation of INAVCalculator for adapter testing
/// @dev Only implements the minimal interface methods needed by adapters (ERC20DefaultBalanceAdapter)
contract Mock_NAVCalculator is INAVCalculator {
    /// @notice Registered assets with their metadata
    /// @dev Field order mirrors `INAVCalculator.Asset` exactly, and that is load-bearing rather than cosmetic:
    ///      `{address, string, uint8}` cannot pack, so it occupies THREE storage slots per asset, where the
    ///      tidier `{address, uint8, string}` packs the address and decimals together and occupies two. Any test
    ///      measuring what a `getRegisteredAssets()` fetch costs — the label leaves that resolve a symbol through
    ///      the registry scale linearly in it — would understate the real contract by one cold SLOAD per
    ///      registered asset if this mock packed more tightly than the thing it stands in for.
    struct AssetInfo {
        address asset;
        string symbol;
        uint8 decimals;
    }

    AssetInfo[] private _assets;
    mapping(address => bool) private _isRegistered;

    /// @notice Optional default adapter; when set, registering an asset also adds it to this adapter's inclusion list
    address public defaultAdapter;

    /// @notice Set the default adapter so that registerAsset* also add assets to it (for adapter tests)
    function setDefaultAdapter(address defaultAdapter_) external {
        defaultAdapter = defaultAdapter_;
    }

    /// @notice Register an asset
    function registerAsset(address asset, uint8 decimals, string memory symbol) external {
        require(!_isRegistered[asset], "Asset already registered");
        _assets.push(AssetInfo({asset: asset, decimals: decimals, symbol: symbol}));
        _isRegistered[asset] = true;
        if (defaultAdapter != address(0)) {
            ERC20DefaultBalanceAdapter(defaultAdapter).addSupportedAsset(asset);
        }
    }

    /// @notice Register an asset using ERC20 metadata
    function registerAssetFromERC20(address asset) external {
        require(!_isRegistered[asset], "Asset already registered");
        uint8 decimals = IERC20Metadata(asset).decimals();
        string memory symbol = IERC20Metadata(asset).symbol();
        _assets.push(AssetInfo({asset: asset, decimals: decimals, symbol: symbol}));
        _isRegistered[asset] = true;
        if (defaultAdapter != address(0)) {
            ERC20DefaultBalanceAdapter(defaultAdapter).addSupportedAsset(asset);
        }
    }

    /// @notice Unregister an asset (helper method, not part of interface)
    function unregisterAssetHelper(address asset) external {
        require(_isRegistered[asset], "Asset not registered");
        _isRegistered[asset] = false;

        // Remove from array
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) {
                // Swap with last element and pop
                _assets[i] = _assets[_assets.length - 1];
                _assets.pop();
                break;
            }
        }
    }

    /// @inheritdoc INAVCalculator
    function getRegisteredAssets() external view override returns (Asset[] memory) {
        Asset[] memory result = new Asset[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            result[i] = Asset({asset: _assets[i].asset, symbol: _assets[i].symbol, decimals: _assets[i].decimals});
        }
        return result;
    }

    /// @inheritdoc INAVCalculator
    /// @dev Must be a WORKING implementation, not a `revert("Not implemented in mock")` stub like the unused
    ///      members below: `MetaBalanceAdapter._getAssetInfo` routes through this, so every meta-adapter unit test
    ///      resolves its assets here. Linear-scans because the mock has no index map — the real contract is O(1)
    ///      via `_assetIndex`, and the difference does not matter at mock scale.
    function getRegisteredAsset(address asset) external view override returns (Asset memory assetInfo, bool found) {
        if (!_isRegistered[asset]) return (assetInfo, false);
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) {
                return
                    (Asset({asset: _assets[i].asset, symbol: _assets[i].symbol, decimals: _assets[i].decimals}), true);
            }
        }
        return (assetInfo, false);
    }

    /// @inheritdoc INAVCalculator
    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }

    /// @notice Check if an asset is registered (IBalances)
    function isAssetRegistered(address asset) external view override returns (bool) {
        return _isRegistered[asset];
    }

    function getAssetCount() external view override returns (uint256) {
        return _assets.length;
    }

    function getAssetDecimals(address asset) external view returns (uint8) {
        require(_isRegistered[asset], "Asset not registered");
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) return _assets[i].decimals;
        }
        revert("Asset not registered");
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        require(_isRegistered[asset], "Asset not registered");
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) return _assets[i].symbol;
        }
        revert("Asset not registered");
    }

    function checkBalanceAdapterSupport(address) external pure override {}

    function getAllAdapters() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterCount() external pure override returns (uint256) {
        return 0;
    }

    function isAdapterRegistered(address) external pure override returns (bool) {
        return false;
    }

    function getAdapterType(address) external pure override returns (AdapterType) {
        return AdapterType.Default;
    }

    function getAdaptersForAsset(address) external pure override returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Backing store for `getMetaInstances`. Defaults to empty for every adapter, so callers that never set
    ///      it see the previous hardcoded-empty behaviour; `setMetaInstances` lets a test stand in for the
    ///      governed instance set that `MetaBalanceAdapter.positionIds()` enumerates.
    mapping(address => bytes32[]) private _metaInstances;

    function setMetaInstances(address adapter, bytes32[] memory instances) external {
        _metaInstances[adapter] = instances;
    }

    function getMetaInstances(address adapter) external view override returns (bytes32[] memory) {
        return _metaInstances[adapter];
    }

    function addMetaInstances(address, bytes32[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    function removeMetaInstances(address, bytes32[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    // Stub implementations for other INAVCalculator methods (not used by adapters)
    function getAccountNav(address, address) external pure override returns (NAV memory) {
        revert("Not implemented in mock");
    }

    function getAccountNavForAdapters(address, address, address[] calldata)
        external
        pure
        override
        returns (PartialNAV memory)
    {
        revert("Not implemented in mock");
    }

    function getAccountPositions(address, address) external pure override returns (Position[] memory) {
        revert("Not implemented in mock");
    }

    /// @dev Stub for the display surface; this mock has no adapter registry.
    ///
    ///      The inner arrays are deliberately left at their default. A review flagged this as a possible
    ///      malformed-ABI hazard ("zero inner pointers"); it was MEASURED and is not one. Solidity initialises
    ///      `new string[][](n)`'s inner pointers to the canonical empty-array slot (0x60), not address 0, so an
    ///      external call returns a well-formed encoding of N empty arrays: `0x20 | n | 0x60 0x80 0xa0 | 0 0 0`
    ///      for n = 3, 256 bytes, no revert. Nothing calls this stub today either — every
    ///      `getAdapterDisplayInfo` call site in the suite targets the real `NAVCalculator`.
    function getAdapterDisplayInfo(address[] calldata adapters)
        external
        pure
        override
        returns (string[] memory names, string[][] memory labels)
    {
        names = new string[](adapters.length);
        labels = new string[][](adapters.length);
    }

    function calculateValue(address[] memory, uint256[] memory, address) external pure override returns (int256, bool) {
        revert("Not implemented in mock");
    }

    function registerAsset(address, address, IPrices.PriceType, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function addOrModifyPriceFeed(address, address, IPrices.PriceType, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function addMonitorFeed(address, address, IPrices.PriceType, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function setDivergenceTolerance(address, uint32) external pure override {
        revert("Not implemented in mock");
    }

    function setPegTolerance(address, uint32) external pure override {
        revert("Not implemented in mock");
    }

    function removeMonitorFeedAt(address, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function removeMonitorFeed(address, address) external pure override {
        revert("Not implemented in mock");
    }

    function getPriceDivergence(address)
        external
        pure
        override
        returns (int256, int256, uint256, bool, uint256, bool, bool)
    {
        revert("Not implemented in mock");
    }

    function addBalanceAdapters(address[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    function addMetaBalanceAdapter(address, bytes32[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    function removeBalanceAdapters(address[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    function excludeAssetFromDefaultAdapter(address) external pure override {
        revert("Not implemented in mock");
    }

    function includeAssetInDefaultAdapter(address) external pure override {
        revert("Not implemented in mock");
    }

    function healthCheck() external pure override returns (bool, address[] memory, address[] memory) {
        revert("Not implemented in mock");
    }

    function hasPositions(address) external pure override returns (bool) {
        revert("Not implemented in mock");
    }

    function version() external pure override returns (uint64) {
        return 1;
    }

    function usdDecimals() external pure override returns (uint8) {
        return 8;
    }

    /// @notice Settable price surface for adapters that read oracle prices.
    ///         Unset assets return price 0 / stale=false → treated as unpriceable by such adapters.
    mapping(address => PriceFeedData) private _priceData;
    mapping(address => bool) private _priceReverts;

    function setAssetPrice(address asset, int256 price, uint8 decimals) external {
        PriceFeedData memory d;
        d.price = price;
        d.decimals = decimals;
        d.stale = false;
        d.updatedAt = block.timestamp;
        _priceData[asset] = d;
    }

    /// @notice Set an asset's price data with an explicit stale flag (updatedAt defaults to block.timestamp).
    ///         Used by the custom-price-feed unit tests to register a base asset (e.g. WETH) with an ETH/USD price
    ///         and to exercise the "base stale" branch (stale=true).
    function setAssetPrice(address asset, int256 price, uint8 decimals, bool stale) external {
        PriceFeedData memory d;
        d.price = price;
        d.decimals = decimals;
        d.stale = stale;
        d.updatedAt = block.timestamp;
        _priceData[asset] = d;
    }

    /// @notice Flip the stale flag on an already-registered asset's price data (keeps price/decimals/updatedAt).
    function setAssetStale(address asset, bool stale) external {
        _priceData[asset].stale = stale;
    }

    /// @notice Set an asset's leg freshness (updatedAt + configured heartbeat) explicitly. Used by custom-feed unit
    ///         tests to exercise `ICustomPriceFeed.governingFeedFreshness` via `NavBaseUsdLib.baseFreshness`, which
    ///         reads `getPriceDataNoDivergence(baseAsset).{updatedAt, chainlinkHeartbeat}`.
    function setAssetFreshness(address asset, uint256 updatedAt, uint256 heartbeat) external {
        _priceData[asset].updatedAt = updatedAt;
        _priceData[asset].chainlinkHeartbeat = heartbeat;
    }

    /// @notice Emulate the NAV's L2 sequencer state. Only sets the raw `sequencerDown` flag; the `stale` fold
    ///         (`stale = feedStale || sequencerDown`, per `PriceFeedLib.buildPriceData`) is applied at read time in
    ///         `getPriceData`, so toggling this back to `false` cleanly emulates a sequencer RECOVERY on an otherwise
    ///         -fresh feed (the stored feed-stale intent is preserved, not clobbered).
    function setSequencerDown(address asset, bool down) external {
        _priceData[asset].sequencerDown = down;
    }

    /// @notice Make getPriceData(asset) REVERT, emulating the real NAVCalculator's PriceFeedNotSet for a registered
    ///         asset whose feeds were all removed (exercises consumers' try/catch around getPriceData).
    function setPriceReverts(address asset, bool reverts_) external {
        _priceReverts[asset] = reverts_;
    }

    function getPriceData(address asset) external view override returns (PriceFeedData memory pd) {
        if (_priceReverts[asset]) revert PriceFeedNotSet(asset);
        pd = _priceData[asset];
        // Faithfully mirror PriceFeedLib: a stale FEED selection returns price 0 (`_selectFeedCore` only sets
        // stale=true via the all-feeds-stale branch, which returns price 0). Sequencer-down alone does NOT zero the
        // price — `buildPriceData` only ORs it into `stale`. So zero the price from the STORED feed-stale first, then
        // fold sequencer-down into the returned flag. This keeps the mock from producing the (stale=true, price>0)
        // state the real engine can never emit — which `NavBaseUsdLib`'s `pd.price <= 0` guard relies on.
        if (pd.stale) pd.price = 0;
        pd.stale = pd.stale || pd.sequencerDown;
    }

    function getPriceDataNoDivergence(address asset) external view override returns (PriceFeedData memory pd) {
        if (_priceReverts[asset]) revert PriceFeedNotSet(asset);
        pd = _priceData[asset];
        if (pd.stale) pd.price = 0;
        pd.stale = pd.stale || pd.sequencerDown;
        // No-divergence variant: leave the divergence signal at defaults (mirrors buildPriceData(..., false)).
        pd.irregular = false;
        pd.divergenceBps = 0;
        pd.monitorFeedCount = 0;
    }

    function getAccountPositionsForAsset(address, address, address) external pure override returns (Position[] memory) {
        revert("Not implemented in mock");
    }

    function getAccountPositionsVerbose(address, address) external pure override returns (VerbosePosition[] memory) {
        revert("Not implemented in mock");
    }

    function getAccountPositionsForAssetVerbose(address, address, address)
        external
        pure
        override
        returns (VerbosePosition[] memory)
    {
        revert("Not implemented in mock");
    }

    function getAccountNavVerbose(address, address) external pure override returns (VerboseNAV memory) {
        revert("Not implemented in mock");
    }

    function getAssetsWithPositions(address) external pure override returns (address[] memory) {
        revert("Not implemented in mock");
    }

    function removePriceFeedAt(address, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function removePriceFeed(address, address) external pure override {
        revert("Not implemented in mock");
    }

    function unregisterAsset(address) external pure override {
        revert("Not implemented in mock");
    }

    function setChainlinkL2SequencerUptimeFeed(address) external pure override {
        revert("Not implemented in mock");
    }

    function setChainlinkL2SequencerGracePeriod(uint256) external pure override {
        revert("Not implemented in mock");
    }
}
