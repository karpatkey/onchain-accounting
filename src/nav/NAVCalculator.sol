// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPrices, Prices} from "src/prices/Prices.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {Balances} from "src/balances/Balances.sol";
import {ERC20DefaultAdapter} from "src/balances/protocols/ERC20DefaultAdapter.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {NavRegistryLib} from "./NavRegistryLib.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAV Calculator
/// @notice NAV Calculator.
/// @author kpk
/// @dev EIP-170 budget: this contract runs close to the 24,576-byte runtime limit (CI's `forge build --sizes`
///      enforces it). The read/compute engine (NAV, positions, health, value) and the registry storage-mutation
///      loops are deliberately delegated to the external libraries `PriceFeedLib` and `NavRegistryLib`
///      (DELEGATECALL) to stay under it — NAVCalculator keeps only storage, admin mutations, and thin
///      view wrappers. When adding code here, watch the margin and prefer moving substantial loops into a
///      library; the entry point should build and consume any heavy PositionBalance[]/Position[] arrays
///      *inside* the library, because returning them across the ABI boundary (and piecemeal helper extraction
///      generally) can cost more than the inlined body under `via_ir`. Always measure with a clean
///      `forge build --sizes`.
contract NAVCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable, INAVCalculator, Prices, Balances {
    //
    // State
    //

    /// @notice Asset registry (NAV/Pricing) — ordered list of registered assets (address, symbol, decimals)
    INAVCalculator.Asset[] private _registeredAssets;

    /// @notice Index of asset in _registeredAssets (1-based; 0 = not registered)
    mapping(address asset => uint256) private _assetIndex;

    /// @notice Gap for upgradeability (reserve storage for new state in upgrades)
    uint256[50] private _gap;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for UUPS proxy
    /// @param admin_ The initial admin
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the chainlink feed for the sequencer uptime
    /// @param nativeTokenSymbol_ The native token symbol (e.g. "ETH", "xDAI") — fixed at init
    function initialize(address admin_, address chainlinkL2SequencerUptimeFeed_, string memory nativeTokenSymbol_)
        external
        initializer
    {
        __AccessControl_init();
        __Prices_init(chainlinkL2SequencerUptimeFeed_);
        __Balances_init();
        _setNativeTokenSymbol(nativeTokenSymbol_);

        // Pre-register native address in NAV/Pricing registry
        _registerAsset(NATIVE_ADDRESS);
        // Deploy ERC20Default adapter with native in inclusion list (constructor avoids callback to proxy during init)
        address[] memory initialAssets = new address[](1);
        initialAssets[0] = NATIVE_ADDRESS;
        ERC20DefaultAdapter defaultAdapter = new ERC20DefaultAdapter(address(this), initialAssets);
        _setErc20DefaultAdapter(address(defaultAdapter));

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    //
    // INAVCalculator
    //

    /// @inheritdoc INAVCalculator
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        _requireManager();
        if (asset == address(0)) {
            revert InvalidArguments();
        }
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }

        // Check if asset already exists
        if (isAssetRegistered(asset)) {
            revert InvalidArguments(); // Asset already registered
        }

        // Register asset in NAV/Pricing registry; fetches decimals/symbol from ERC20 (or native); reverts if not ERC20 compatible
        _registerAsset(asset);

        // Register first price feed as part of asset registration
        _addPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);

        // Add asset to default adapter's inclusion list so wallet balances are reported
        ERC20DefaultAdapter(erc20DefaultAdapter).addSupportedAsset(asset);

        emit AssetRegistered(asset, _getRegisteredAsset(asset).decimals);
    }

    /// @inheritdoc INAVCalculator
    function addPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        _requireManager();
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(asset);

        _addPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function addBalanceAdapters(address[] calldata adapters) external {
        _requireManager();
        _addBalanceAdapters(adapters);
    }

    /// @inheritdoc INAVCalculator
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external {
        _requireManager();
        if (adapter == address(0)) {
            revert InvalidArguments();
        }
        _addMetaBalanceAdapter(adapter, instances);
    }

    /// @inheritdoc INAVCalculator
    function removePriceFeedAt(address asset, uint256 index) external {
        _requireManager();
        _requireAssetExists(asset);
        _removePriceFeedAt(asset, index);
    }

    /// @inheritdoc INAVCalculator
    function removePriceFeed(address asset, address priceFeed) external {
        _requireManager();
        _requireAssetExists(asset);
        _removePriceFeed(asset, priceFeed);
    }

    /// @inheritdoc INAVCalculator
    function removeBalanceAdapters(address[] calldata adapters) external {
        _requireManager();
        _removeBalanceAdapters(adapters);
    }

    /// @inheritdoc INAVCalculator
    function addMetaInstances(address adapter, bytes32[] calldata instances) external {
        _requireManager();
        _addMetaInstances(adapter, instances);
    }

    /// @inheritdoc INAVCalculator
    function removeMetaInstances(address adapter, bytes32[] calldata instances) external {
        _requireManager();
        _removeMetaInstances(adapter, instances);
    }

    /// @inheritdoc INAVCalculator
    function excludeAssetFromDefaultAdapter(address asset) external {
        _requireManager();
        _requireAssetExists(asset);
        ERC20DefaultAdapter(erc20DefaultAdapter).removeSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function includeAssetInDefaultAdapter(address asset) external {
        _requireManager();
        _requireAssetExists(asset);
        ERC20DefaultAdapter(erc20DefaultAdapter).addSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function unregisterAsset(address underlyingAsset) external {
        _requireManager();

        _requireAssetExists(underlyingAsset);

        // Remove all price feeds if any exist
        if (_priceFeedCount(underlyingAsset) > 0) {
            _removeAllPriceFeeds(underlyingAsset);
        }

        // Remove from default adapter's inclusion list (idempotent if not present)
        ERC20DefaultAdapter(erc20DefaultAdapter).removeSupportedAsset(underlyingAsset);

        // Remove the asset itself
        _unregisterAsset(underlyingAsset);

        emit AssetUnregistered(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2SequencerUptimeFeed) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        address oldChainlinkL2SequencerUptimeFeed = address(chainlinkL2SequencerUptimeFeed);
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(newChainlinkL2SequencerUptimeFeed);
        emit ChainlinkUptimeFeedUpdated(oldChainlinkL2SequencerUptimeFeed, newChainlinkL2SequencerUptimeFeed);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external {
        _requireManager();
        if (address(chainlinkL2SequencerUptimeFeed) == address(0)) {
            revert UptimeFeedNotSet();
        }
        if (newSequencerGracePeriod < 1 hours) {
            revert InvalidArguments();
        }
        uint256 oldSequencerGracePeriod = chainlinkL2SequencerGracePeriod;
        chainlinkL2SequencerGracePeriod = newSequencerGracePeriod;
        emit L2SequencerGracePeriodUpdated(oldSequencerGracePeriod, newSequencerGracePeriod);
    }

    /// @inheritdoc INAVCalculator
    function version() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    /// @inheritdoc INAVCalculator
    function assetCount() external view returns (uint256) {
        return getAssetCount();
    }

    /// @inheritdoc INAVCalculator
    function getAccountNav(address account, address quoteAsset) external view returns (INAVCalculator.NAV memory nav) {
        _validateQuoteAsset(quoteAsset);

        // The full read/compute path (adapter scan → unique assets → price cache → summation) is delegated to
        // PriceFeedLib to keep NAVCalculator under EIP-170; the heavy PositionBalance[] arrays are built and
        // consumed inside the library and never cross the ABI boundary. Sequencer status depends on this
        // contract's config, so it is computed here and passed in.
        return PriceFeedLib.computeNav(
            _priceOracles,
            _assetIndex,
            _registeredAssets,
            getAllAdapters(),
            _metaInstanceTotal,
            account,
            quoteAsset,
            _isSequencerDown(),
            _nativeTokenSymbol
        );
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        _validateQuoteAsset(quoteAsset);
        return PriceFeedLib.computeAccountPositions(
            _priceOracles,
            _assetIndex,
            _registeredAssets,
            getAllAdapters(),
            _metaInstanceTotal,
            account,
            address(0),
            quoteAsset,
            _nativeTokenSymbol
        );
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        _validateQuoteAsset(quoteAsset);
        _validateAssetFilter(asset);
        return PriceFeedLib.computeAccountPositions(
            _priceOracles,
            _assetIndex,
            _registeredAssets,
            getAllAdapters(),
            _metaInstanceTotal,
            account,
            asset,
            quoteAsset,
            _nativeTokenSymbol
        );
    }

    /// @inheritdoc INAVCalculator
    function usdDecimals() external pure returns (uint8) {
        return NAV_DECIMALS;
    }

    /// @inheritdoc INAVCalculator
    function getRegisteredAssets() external view override returns (INAVCalculator.Asset[] memory) {
        return _registeredAssets;
    }

    /// @inheritdoc INAVCalculator
    function getAssetCount() public view override returns (uint256) {
        return _registeredAssets.length;
    }

    /// @inheritdoc INAVCalculator
    function isAssetRegistered(address asset) public view override returns (bool) {
        return _assetIndex[asset] != 0;
    }

    /// @inheritdoc INAVCalculator
    function getPriceData(address underlyingAsset)
        external
        view
        returns (INAVCalculator.PriceFeedData memory priceFeedData)
    {
        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);

        // Heavy assembly (feed selection + config read + AggregatorV3 updatedAt fetch) is delegated to
        // PriceFeedLib to keep NAVCalculator under EIP-170; sequencer status depends on this contract's config so
        // it is computed here and passed in.
        return PriceFeedLib.buildPriceData(_priceOracles, underlyingAsset, _isSequencerDown());
    }

    /// @inheritdoc INAVCalculator
    function healthCheck() external view returns (bool sequencerDown, address[] memory stalePriceAssets) {
        // Sequencer status depends on this contract's config; the per-asset staleness scan is delegated to
        // PriceFeedLib to keep NAVCalculator under EIP-170.
        return PriceFeedLib.healthCheck(_priceOracles, _registeredAssets, _isSequencerDown());
    }

    /// @inheritdoc INAVCalculator
    /// @dev Delegates to PriceFeedLib, which scans the same positions path used by getAccountPositions and wraps
    ///      every per-adapter call in try/catch (fail-open) so a single reverting adapter cannot DoS the scan.
    function hasPositions(address account) external view override returns (bool has) {
        return PriceFeedLib.hasPositions(getAllAdapters(), _metaInstanceTotal, _assetIndex, getAssetCount(), account);
    }

    /// @inheritdoc INAVCalculator
    function getAssetsWithPositions(address account) external view override returns (address[] memory) {
        return PriceFeedLib.getAssetsWithPositions(
            getAllAdapters(), _metaInstanceTotal, _assetIndex, getAssetCount(), account
        );
    }

    /// @inheritdoc INAVCalculator
    function calculateValue(address[] memory assetAddresses, uint256[] memory amounts, address quoteAsset)
        external
        view
        override
        returns (int256 value)
    {
        return PriceFeedLib.calculateValue(
            _priceOracles, _assetIndex, _registeredAssets, assetAddresses, amounts, quoteAsset, _nativeTokenSymbol
        );
    }

    //
    // UUPSUpgradeable
    //

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address /* newImpl */
    )
        internal
        view
        override(UUPSUpgradeable)
    {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
    }

    //
    // Internal API - Asset registry (NAV/Pricing)
    //

    /// @notice Registers an asset in the NAV/Pricing registry.
    /// Fetches decimals and symbol: for NATIVE_ADDRESS uses 18 and _nativeTokenSymbol;
    /// otherwise requires ERC20-compatible (decimals() and symbol()) and reverts if not.
    function _registerAsset(address asset) internal {
        NavRegistryLib.registerAsset(_registeredAssets, _assetIndex, asset, _nativeTokenSymbol);
    }

    /// @notice Unregisters an asset from the NAV/Pricing registry
    function _unregisterAsset(address asset) internal {
        NavRegistryLib.unregisterAsset(_registeredAssets, _assetIndex, asset);
    }

    /// @notice Returns the registered Asset struct from the NAV/Pricing registry (single lookup for decimals + symbol).
    function _getRegisteredAsset(address asset) internal view returns (INAVCalculator.Asset memory) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) revert AssetNotFound();
        return _registeredAssets[idx - 1];
    }

    //
    // Internal API
    //

    /// @notice Validates that the caller has the MANAGER role, reverts if not
    function _requireManager() internal view {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
    }

    /// @notice Validates that an asset exists, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requireAssetExists(address underlyingAsset) internal view {
        if (!isAssetRegistered(underlyingAsset)) {
            revert AssetNotFound();
        }
    }

    /// @notice Validates that at least one price feed exists for an asset, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requirePriceFeedExists(address underlyingAsset) internal view {
        if (_priceFeedCount(underlyingAsset) == 0) {
            revert PriceFeedNotSet(underlyingAsset);
        }
    }

    /// @notice Validates quote asset (skips validation for address(0) which represents USD)
    /// @param quoteAsset The quote asset to validate
    function _validateQuoteAsset(address quoteAsset) internal view {
        if (quoteAsset != address(0)) {
            _requirePriceFeedExists(quoteAsset);
        }
    }

    /// @notice Validates asset filter (skips validation for address(0) which means all assets)
    /// @param assetFilter The asset filter to validate
    function _validateAssetFilter(address assetFilter) internal view {
        if (assetFilter != address(0)) {
            _requireAssetExists(assetFilter);
        }
    }

    /// @notice Checks if the L2 sequencer is down
    /// @dev Only checks sequencer status if on L2 (uptime feed is set). On L1, always returns false.
    /// @notice Sequencer downtime is a global issue affecting all prices, not asset-specific. It should be tracked
    /// separately from stale prices.
    /// @return sequencerDown True if the L2 sequencer is down or within grace period, false otherwise
    function _isSequencerDown() internal view returns (bool sequencerDown) {
        // Only check sequencer if on L2 (uptime feed is set)
        if (address(chainlinkL2SequencerUptimeFeed) != address(0)) {
            return checkL2SequencerUptime();
        }
        return false;
    }
}
