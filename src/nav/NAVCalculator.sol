// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPrices, Prices} from "src/prices/Prices.sol";
import {Balances} from "src/balances/Balances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAV Calculator
/// @notice Calculates NAV based on on-chain balances and price feeds.
/// @author kpk
contract NAVCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable, INAVCalculator, Prices, Balances {
    //
    // Libraries
    //
    using ERC165Checker for address;

    //
    // State
    //

    /// @notice Asset recoverer. useful solely for recovery of wrongly sent funds to this contract.
    /// @dev This is the recipient address that will receive the assets recovered by a call to the `recoverAssets`
    /// function.
    address public assetRecoverer;

    /// @notice Asset registry (NAV/Pricing) — ordered list of registered assets (address, symbol, decimals)
    INAVCalculator.Asset[] private _registeredAssets;

    /// @notice Index of asset in _registeredAssets (1-based; 0 = not registered)
    mapping(address asset => uint256) private _assetIndex;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for UUPS proxy
    /// @param admin_ The initial admin
    /// @param assetRecoverer_ Asset recoverer. useful solely for recovery of wrongly sent funds
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the chainlink feed for the sequencer uptime
    /// @param nativeTokenSymbol_ The native token symbol (e.g. "ETH", "xDAI") — fixed at init
    function initialize(
        address admin_,
        address assetRecoverer_,
        address chainlinkL2SequencerUptimeFeed_,
        string memory nativeTokenSymbol_
    ) public initializer {
        __AccessControl_init();
        __Prices_init(chainlinkL2SequencerUptimeFeed_);
        __Balances_init();
        _setNativeTokenSymbol(nativeTokenSymbol_);

        // Pre-register native address in NAV/Pricing registry
        _registerAsset(NATIVE_ADDRESS);
        // Deploy ERC20Default oracle with native in inclusion list (constructor avoids callback to proxy during init)
        address[] memory initialAssets = new address[](1);
        initialAssets[0] = NATIVE_ADDRESS;
        ERC20DefaultOracle defaultOracle = new ERC20DefaultOracle(address(this), initialAssets);
        _setErc20DefaultOracle(address(defaultOracle));

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        assetRecoverer = assetRecoverer_;
    }

    //
    // INAVCalculator
    //

    /// @inheritdoc INAVCalculator
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
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

        // Set price feed as part of registration
        _setPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);

        // Add asset to default oracle's inclusion list so wallet balances are reported
        ERC20DefaultOracle(erc20DefaultOracle).addSupportedAsset(asset);

        emit AssetRegistered(asset, getAssetDecimals(asset));
    }

    /// @inheritdoc INAVCalculator
    function setPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(asset);

        _setPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function addBalanceOracle(address oracle) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        _addBalanceOracle(oracle);
    }

    /// @inheritdoc INAVCalculator
    function unsetPriceFeed(address underlyingAsset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);

        _unsetPriceFeed(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function removeBalanceOracle(address oracle) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _removeBalanceOracle(oracle);
    }

    /// @inheritdoc INAVCalculator
    function excludeAssetFromDefaultOracle(address asset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        _requireAssetExists(asset);
        ERC20DefaultOracle(erc20DefaultOracle).removeSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function includeAssetInDefaultOracle(address asset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        _requireAssetExists(asset);
        ERC20DefaultOracle(erc20DefaultOracle).addSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function unregisterAsset(address underlyingAsset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _requireAssetExists(underlyingAsset);

        // Unset price feed if it exists
        if (priceOracles[underlyingAsset].priceFeed != address(0)) {
            _unsetPriceFeed(underlyingAsset);
        }

        // Remove from default oracle's inclusion list (idempotent if not present)
        ERC20DefaultOracle(erc20DefaultOracle).removeSupportedAsset(underlyingAsset);

        // Remove the asset itself
        _unregisterAsset(underlyingAsset);

        emit AssetUnregistered(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2SequencerUptimeFeed) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        address oldChainlinkL2SequencerUptimeFeed = address(chainlinkL2SequencerUptimeFeed);
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(newChainlinkL2SequencerUptimeFeed);
        emit ChainlinkUptimeFeedUpdated(oldChainlinkL2SequencerUptimeFeed, newChainlinkL2SequencerUptimeFeed);
    }

    /// @inheritdoc INAVCalculator
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (address(chainlinkL2SequencerUptimeFeed) == address(0)) {
            revert UptimeFeedNotSet();
        }
        if (newSequencerGracePeriod == 0) {
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
        // Validate quoteAsset has PriceFeedConfig (early validation)
        // Skip validation for address(0) which represents USD (no price feed needed)
        if (quoteAsset != address(0)) {
            _requirePriceFeedConfig(quoteAsset);
        }

        nav.timestamp = uint64(block.timestamp);

        // Build quoteAsset
        INAVCalculator.Asset memory quoteAssetStruct;
        if (quoteAsset != address(0)) {
            uint8 quoteDecimals = _getAssetDecimals(quoteAsset);
            string memory quoteSymbol;
            if (quoteAsset == NATIVE_ADDRESS) {
                quoteSymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(quoteAsset).symbol() returns (string memory symbol_) {
                    quoteSymbol = symbol_;
                } catch {
                    quoteSymbol = "";
                }
            }
            quoteAssetStruct = INAVCalculator.Asset({asset: quoteAsset, symbol: quoteSymbol, decimals: quoteDecimals});
        } else {
            quoteAssetStruct = INAVCalculator.Asset({asset: address(0), symbol: "USD", decimals: NAV_DECIMALS});
        }
        nav.quoteAsset = quoteAssetStruct;

        uint256 length = getAssetCount();

        if (length != 0) {
            // read all of the account's positions
            // NOTE: this can exceed gas limit
            (int256 totalValue, INAVCalculator.Asset[] memory staleAssets, bool sequencerDown) =
                _readPositionsRangeWithQuote(account, 0, length - 1, quoteAsset);
            nav.value = totalValue;
            nav.stalePriceAssets = staleAssets;
            nav.sequencerDown = sequencerDown;
        } else {
            // Initialize empty arrays when no assets
            nav.value = 0;
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.sequencerDown = false;
        }
    }

    /// @inheritdoc INAVCalculator

    /// @notice Reads the holdings of a given account, for a limited range of assets, with quote currency conversion.
    /// @dev Range is expressed in terms of the current asset enumeration (from `getRegisteredAssets()`).
    ///      Implementation is oracle‑centric: iterate over all oracles, aggregate positions, then filter by asset range.
    function _readPositionsRangeWithQuote(address account, uint256 from, uint256 to, address quoteAsset)
        internal
        view
        returns (int256 totalValue, INAVCalculator.Asset[] memory stalePriceAssets, bool sequencerDown)
    {
        uint256 totalAssets = getAssetCount();
        if (from > to) {
            revert InvalidArgumentsWithContext("from > to");
        }
        if (to >= totalAssets) {
            revert InvalidArgumentsWithContext("to >= totalAssets");
        }

        // Check sequencer status once (global issue, affects all assets)
        sequencerDown = _isSequencerDown();

        // Build the slice of assets that this range refers to
        INAVCalculator.Asset[] memory allAssets = _registeredAssets;
        uint256 rangeSize = to - from + 1;
        address[] memory rangeAssets = new address[](rangeSize);
        for (uint256 i = 0; i < rangeSize; i++) {
            rangeAssets[i] = allAssets[from + i].asset;
        }

        // Get all registered oracles from global registry
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;

        // First pass: collect all positions from all oracles, then filter to the rangeAssets set
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](totalOracles * rangeSize); // upper bound estimate
        uint256 positionCount = 0;

        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // All registered oracles should implement IBalanceOracleAdapter
            // Interface validation is done during oracle registration, not here
            // Use try-catch to gracefully handle any oracles that don't implement the interface
            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(oracle);
            INAVCalculator.PositionBalance[] memory oraclePositions;
            try adapter.getOraclePositions(account, address(0)) returns (
                INAVCalculator.PositionBalance[] memory positions
            ) {
                oraclePositions = positions;
            } catch {
                // Oracle doesn't implement IBalanceOracleAdapter, skip it
                continue;
            }

            for (uint256 j = 0; j < oraclePositions.length; j++) {
                address assetAddr = oraclePositions[j].underlyingAsset.asset;

                // Skip unregistered assets
                if (!isAssetRegistered(assetAddr)) {
                    continue;
                }

                // Keep only assets inside [from, to] range
                bool inRange = false;
                for (uint256 k = 0; k < rangeSize; k++) {
                    if (rangeAssets[k] == assetAddr) {
                        inRange = true;
                        break;
                    }
                }
                if (!inRange) {
                    continue;
                }

                tempPositions[positionCount] = oraclePositions[j];
                positionCount++;
            }
        }

        // If no positions in this range, return early
        if (positionCount == 0) {
            totalValue = 0;
            stalePriceAssets = new INAVCalculator.Asset[](0);
            return (totalValue, stalePriceAssets, sequencerDown);
        }

        // Resize to actual count
        INAVCalculator.PositionBalance[] memory positionsInRange = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positionsInRange[i] = tempPositions[i];
        }

        // Collect unique assets from positions for price lookups
        address[] memory assetsWithPositions = _extractUniqueAssets(positionsInRange);

        // Fetch prices for each asset once, track staleness
        PriceFeedCache[] memory priceFeeds = new PriceFeedCache[](assetsWithPositions.length);
        for (uint256 i = 0; i < assetsWithPositions.length; i++) {
            address asset = assetsWithPositions[i];
            (int256 price, uint8 priceDecimals, bool stale) = _latestPrice(asset);
            priceFeeds[i] = PriceFeedCache({asset: asset, price: price, decimals: priceDecimals, stale: stale});
        }

        // Build stalePriceAssets (deduplicated)
        uint256 staleCount = 0;
        address[] memory staleAssetAddrs = new address[](assetsWithPositions.length);
        for (uint256 i = 0; i < priceFeeds.length; i++) {
            if (!priceFeeds[i].stale) continue;

            // Deduplicate
            bool alreadyAdded = false;
            for (uint256 j = 0; j < staleCount; j++) {
                if (staleAssetAddrs[j] == priceFeeds[i].asset) {
                    alreadyAdded = true;
                    break;
                }
            }
            if (!alreadyAdded) {
                staleAssetAddrs[staleCount] = priceFeeds[i].asset;
                staleCount++;
            }
        }

        stalePriceAssets = new INAVCalculator.Asset[](staleCount);
        for (uint256 i = 0; i < staleCount; i++) {
            uint8 decimals = _getAssetDecimals(staleAssetAddrs[i]);
            stalePriceAssets[i] = INAVCalculator.Asset({
                asset: staleAssetAddrs[i],
                symbol: "", // Symbol resolution kept simple here
                decimals: decimals
            });
        }

        // Get quote asset price info if not USD
        int256 quoteAssetPrice = 0;
        uint8 quoteAssetPriceDecimals = 0;
        uint8 quoteAssetDecimals = 0;
        if (quoteAsset != address(0)) {
            _requirePriceFeedConfig(quoteAsset);
            (quoteAssetPrice, quoteAssetPriceDecimals,) = _latestPrice(quoteAsset);
            quoteAssetDecimals = _getAssetDecimals(quoteAsset);
        } else {
            quoteAssetDecimals = NAV_DECIMALS;
        }

        // Sum USD value of all positions in range (use registry decimals for consistency)
        int256 totalUsd = 0;
        for (uint256 i = 0; i < positionsInRange.length; i++) {
            INAVCalculator.PositionBalance memory pos = positionsInRange[i];
            address asset = pos.underlyingAsset.asset;
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, asset);
            uint8 canonicalDecimals = _getAssetDecimals(asset);

            int256 usdValue = _toUsd(pos.amount, pos.isDebt, canonicalDecimals, feed.price, feed.decimals);
            totalUsd += usdValue;
        }

        // Convert USD total to quote asset if needed
        if (quoteAsset != address(0)) {
            totalValue = _fromUsd(totalUsd, quoteAssetPrice, quoteAssetPriceDecimals, quoteAssetDecimals);
        } else {
            totalValue = totalUsd;
        }
    }

    /// @inheritdoc INAVCalculator
    function getAccountNavForRange(address account, uint256 from, uint256 to, address quoteAsset)
        external
        view
        returns (INAVCalculator.NAV memory nav)
    {
        // Validate quoteAsset has PriceFeedConfig (early validation)
        // Skip validation for address(0) which represents USD (no price feed needed)
        if (quoteAsset != address(0)) {
            _requirePriceFeedConfig(quoteAsset);
        }

        nav.timestamp = uint64(block.timestamp);

        // Build quoteAsset
        INAVCalculator.Asset memory quoteAssetStruct;
        if (quoteAsset != address(0)) {
            uint8 quoteDecimals = _getAssetDecimals(quoteAsset);
            string memory quoteSymbol;
            if (quoteAsset == NATIVE_ADDRESS) {
                quoteSymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(quoteAsset).symbol() returns (string memory symbol_) {
                    quoteSymbol = symbol_;
                } catch {
                    quoteSymbol = "";
                }
            }
            quoteAssetStruct = INAVCalculator.Asset({asset: quoteAsset, symbol: quoteSymbol, decimals: quoteDecimals});
        } else {
            quoteAssetStruct = INAVCalculator.Asset({asset: address(0), symbol: "USD", decimals: NAV_DECIMALS});
        }
        nav.quoteAsset = quoteAssetStruct;

        (int256 totalValue, INAVCalculator.Asset[] memory staleAssets, bool sequencerDown) =
            _readPositionsRangeWithQuote(account, from, to, quoteAsset);
        nav.value = totalValue;
        nav.stalePriceAssets = staleAssets;
        nav.sequencerDown = sequencerDown;
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        // Validate quoteAsset has PriceFeedConfig (early validation)
        // Skip validation for address(0) which represents USD (no price feed needed)
        if (quoteAsset != address(0)) {
            _requirePriceFeedConfig(quoteAsset);
        }

        // Get all registered oracles from global registry
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;

        // Pre-allocate arrays for positions (estimate based on oracle count)
        INAVCalculator.PositionBalance[] memory tempPositions = new INAVCalculator.PositionBalance[](totalOracles * 10); // Estimate
        uint256 positionCount = 0;

        // Loop through all oracles (oracle-centric aggregation)
        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // All registered oracles should implement IBalanceOracleAdapter
            // Interface validation is done during oracle registration, not here
            // Call getOraclePositions() on each oracle adapter
            // Each oracle returns all positions it knows about for this account
            // assetFilter = address(0) means "return all assets"
            IBalanceOracleAdapter oracleAdapter = IBalanceOracleAdapter(oracle);
            INAVCalculator.PositionBalance[] memory oraclePositions;
            try oracleAdapter.getOraclePositions(account, address(0)) returns (
                INAVCalculator.PositionBalance[] memory posList
            ) {
                oraclePositions = posList;
            } catch {
                // Oracle doesn't implement IBalanceOracleAdapter, skip it
                continue;
            }

            // Filter positions: only include those with registered assets
            for (uint256 j = 0; j < oraclePositions.length; j++) {
                address asset = oraclePositions[j].underlyingAsset.asset;

                // Skip positions for unregistered assets
                if (!isAssetRegistered(asset)) {
                    continue;
                }

                // Copy position to temp array
                tempPositions[positionCount] = oraclePositions[j];
                positionCount++;
            }
        }

        // Resize to actual count
        INAVCalculator.PositionBalance[] memory allPositions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            allPositions[i] = tempPositions[i];
        }

        // Collect unique assets from all positions for price fetching
        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);

        // Fetch prices once per asset (optimized) - store in struct array
        // Note: All assets here are registered (filtered earlier), so if they don't have price feeds, _latestPrice will revert
        PriceFeedCache[] memory priceFeeds = new PriceFeedCache[](assetsWithPositions.length);
        for (uint256 i = 0; i < assetsWithPositions.length; i++) {
            address asset = assetsWithPositions[i];
            (int256 price, uint8 priceDecimals, bool stale) = _latestPrice(asset);
            priceFeeds[i] = PriceFeedCache({asset: asset, price: price, decimals: priceDecimals, stale: stale});
        }

        // Get quote asset info
        // Note: Quote asset price is fetched separately as it may not be in the positions
        int256 quoteAssetPrice = 0;
        uint8 quoteAssetPriceDecimals = 0;
        uint8 quoteAssetDecimals = 0;
        string memory quoteAssetSymbol = "";

        if (quoteAsset != address(0)) {
            // Quote asset price feed is validated earlier, so we can safely fetch it
            (quoteAssetPrice, quoteAssetPriceDecimals,) = _latestPrice(quoteAsset);
            quoteAssetDecimals = _getAssetDecimals(quoteAsset);
            if (quoteAsset == NATIVE_ADDRESS) {
                quoteAssetSymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(quoteAsset).symbol() returns (string memory symbol_) {
                    quoteAssetSymbol = symbol_;
                } catch {
                    quoteAssetSymbol = "";
                }
            }
        } else {
            quoteAssetDecimals = NAV_DECIMALS;
            quoteAssetSymbol = "USD";
        }

        INAVCalculator.Asset memory quoteAssetStruct =
            INAVCalculator.Asset({asset: quoteAsset, symbol: quoteAssetSymbol, decimals: quoteAssetDecimals});

        // Enrich balance positions with pricing to create full Position structs
        // Complete positions with canonical asset data (decimals, symbol) from registry
        // Note: All positions here are for registered assets (filtered earlier)
        // If a registered asset doesn't have a price feed, _latestPrice will revert above
        INAVCalculator.Position[] memory pricedPositions = new INAVCalculator.Position[](allPositions.length);
        for (uint256 i = 0; i < allPositions.length; i++) {
            address asset = allPositions[i].underlyingAsset.asset;
            PriceFeedCache memory priceFeed = _findPriceFeed(priceFeeds, asset);
            uint8 canonicalDecimals = _getAssetDecimals(asset);
            string memory canonicalSymbol = getAssetSymbol(asset);

            pricedPositions[i] = _enrichPositionWithPricing(
                allPositions[i],
                priceFeed,
                quoteAssetStruct,
                quoteAssetPrice,
                quoteAssetPriceDecimals,
                quoteAssetDecimals,
                canonicalDecimals,
                canonicalSymbol
            );
        }

        return pricedPositions;
    }

    /// @notice Helper struct for price feed caching
    struct PriceFeedCache {
        address asset;
        int256 price;
        uint8 decimals;
        bool stale;
    }

    /// @notice Finds price feed for an asset in the cache array
    /// @param priceFeeds Array of cached price feeds
    /// @param asset The asset to find
    /// @return priceFeed The cached price feed for the asset
    function _findPriceFeed(PriceFeedCache[] memory priceFeeds, address asset)
        internal
        pure
        returns (PriceFeedCache memory priceFeed)
    {
        for (uint256 i = 0; i < priceFeeds.length; i++) {
            if (priceFeeds[i].asset == asset) {
                return priceFeeds[i];
            }
        }
        // Should not happen if assetsWithPositions was built correctly
        revert AssetNotFound();
    }

    /// @notice Extracts unique assets from balance positions array
    /// @param positions Array of balance-only positions
    /// @return uniqueAssets Array of unique asset addresses
    function _extractUniqueAssets(INAVCalculator.PositionBalance[] memory positions)
        internal
        pure
        returns (address[] memory uniqueAssets)
    {
        // Use a simple approach: collect all assets, then deduplicate
        // For gas efficiency, we could use a mapping, but that's not possible in memory
        address[] memory tempAssets = new address[](positions.length);
        uint256 count = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            address asset = positions[i].underlyingAsset.asset;
            bool found = false;

            // Check if already in temp array
            for (uint256 j = 0; j < count; j++) {
                if (tempAssets[j] == asset) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                tempAssets[count] = asset;
                count++;
            }
        }

        // Resize to actual count
        uniqueAssets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            uniqueAssets[i] = tempAssets[i];
        }
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        // Validate quoteAsset has PriceFeedConfig (early validation)
        // Skip validation for address(0) which represents USD (no price feed needed)
        if (quoteAsset != address(0)) {
            _requirePriceFeedConfig(quoteAsset);
        }

        // Validate asset is registered
        _requireAssetExists(asset);

        // Get all registered oracles from global registry
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;

        // Pre-allocate array for positions
        INAVCalculator.PositionBalance[] memory tempPositions = new INAVCalculator.PositionBalance[](totalOracles);
        uint256 positionCount = 0;

        // Loop through all oracles (oracle-centric aggregation)
        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // All registered oracles should implement IBalanceOracleAdapter
            // Interface validation is done during oracle registration, not here
            // Call getOraclePositions with asset filter
            IBalanceOracleAdapter oracleAdapter = IBalanceOracleAdapter(oracle);
            INAVCalculator.PositionBalance[] memory oraclePositions;
            try oracleAdapter.getOraclePositions(account, asset) returns (
                INAVCalculator.PositionBalance[] memory posList
            ) {
                oraclePositions = posList;
            } catch {
                // Oracle doesn't implement IBalanceOracleAdapter, skip it
                continue;
            }

            // Copy positions to temp array (all should be for the requested asset)
            for (uint256 j = 0; j < oraclePositions.length; j++) {
                // Double-check asset matches (safety check)
                if (oraclePositions[j].underlyingAsset.asset == asset) {
                    tempPositions[positionCount] = oraclePositions[j];
                    positionCount++;
                }
            }
        }

        // Resize to actual count
        INAVCalculator.PositionBalance[] memory assetPositions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            assetPositions[i] = tempPositions[i];
        }

        // Fetch price for this asset (optimized - single fetch)
        (int256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(asset);

        // Get quote asset price if needed
        int256 quoteAssetPrice = 0;
        uint8 quoteAssetPriceDecimals = 0;
        uint8 quoteAssetDecimals = 0;
        string memory quoteAssetSymbol = "";

        if (quoteAsset != address(0)) {
            (quoteAssetPrice, quoteAssetPriceDecimals,) = _latestPrice(quoteAsset);
            quoteAssetDecimals = _getAssetDecimals(quoteAsset);
            if (quoteAsset == NATIVE_ADDRESS) {
                quoteAssetSymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(quoteAsset).symbol() returns (string memory symbol_) {
                    quoteAssetSymbol = symbol_;
                } catch {
                    quoteAssetSymbol = "";
                }
            }
        } else {
            quoteAssetDecimals = NAV_DECIMALS;
            quoteAssetSymbol = "USD";
        }

        INAVCalculator.Asset memory quoteAssetStruct =
            INAVCalculator.Asset({asset: quoteAsset, symbol: quoteAssetSymbol, decimals: quoteAssetDecimals});

        // Build price feed cache for this asset
        PriceFeedCache memory priceFeed =
            PriceFeedCache({asset: asset, price: usdRate, decimals: SafeCast.toUint8(usdRateDecimals), stale: stale});

        // Complete positions with canonical asset data from registry; enrich with pricing
        uint8 canonicalDecimals = _getAssetDecimals(asset);
        string memory canonicalSymbol = getAssetSymbol(asset);

        INAVCalculator.Position[] memory pricedPositions = new INAVCalculator.Position[](assetPositions.length);
        for (uint256 i = 0; i < assetPositions.length; i++) {
            pricedPositions[i] = _enrichPositionWithPricing(
                assetPositions[i],
                priceFeed,
                quoteAssetStruct,
                quoteAssetPrice,
                quoteAssetPriceDecimals,
                quoteAssetDecimals,
                canonicalDecimals,
                canonicalSymbol
            );
        }

        return pricedPositions;
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
    function getAssetDecimals(address asset) public view override returns (uint8) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) {
            revert AssetNotFound();
        }
        return _registeredAssets[idx - 1].decimals;
    }

    /// @inheritdoc INAVCalculator
    function getAssetSymbol(address asset) public view override returns (string memory) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) {
            revert AssetNotFound();
        }
        return _registeredAssets[idx - 1].symbol;
    }

    /// @inheritdoc INAVCalculator
    function getPriceData(address underlyingAsset)
        external
        view
        returns (INAVCalculator.PriceFeedData memory priceFeedData)
    {
        _requireAssetExists(underlyingAsset);

        IPrices.PriceFeedConfig storage config = priceOracles[underlyingAsset];
        _requirePriceFeedExists(underlyingAsset);

        (int256 price, uint8 decimals, bool stale) = _latestPrice(underlyingAsset);

        priceFeedData.priceFeed = config.priceFeed;
        priceFeedData.priceType = config.priceType;
        priceFeedData.price = price;
        priceFeedData.decimals = decimals;
        priceFeedData.chainlinkHeartbeat = config.chainlinkHeartbeat;
        priceFeedData.stale = stale;

        // Get Chainlink-specific data
        if (config.priceType == IPrices.PriceType.Chainlink) {
            AggregatorV3Interface chainlinkFeed = AggregatorV3Interface(config.priceFeed);
            (,,, uint256 roundUpdatedAt,) = chainlinkFeed.latestRoundData();
            priceFeedData.updatedAt = roundUpdatedAt;
        }

        // Check L2 sequencer uptime (conditional on L2)
        priceFeedData.sequencerDown = _isSequencerDown();
    }

    /// @inheritdoc INAVCalculator
    function healthCheck() external view returns (bool sequencerDown, address[] memory stalePriceAssets) {
        uint256 totalAssets = getAssetCount();

        // Check sequencer status once
        sequencerDown = _isSequencerDown();

        if (totalAssets == 0) {
            stalePriceAssets = new address[](0);
            return (sequencerDown, stalePriceAssets);
        }

        INAVCalculator.Asset[] memory allAssets = _registeredAssets;
        address[] memory staleAssetsTemp = new address[](totalAssets);
        uint256 staleCount = 0;

        for (uint256 i = 0; i < totalAssets; i++) {
            address assetAddr = allAssets[i].asset;

            _requirePriceFeedExists(assetAddr);

            (,, bool stale) = _latestPrice(assetAddr);
            if (stale) {
                staleAssetsTemp[staleCount] = assetAddr;
                staleCount++;
            }
        }

        if (staleCount == 0) {
            stalePriceAssets = new address[](0);
        } else {
            stalePriceAssets = new address[](staleCount);
            for (uint256 j = 0; j < staleCount; j++) {
                stalePriceAssets[j] = staleAssetsTemp[j];
            }
        }
    }

    /// @inheritdoc INAVCalculator
    function hasPositions(address account) external view override returns (bool has) {
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;
        // Oracle‑centric scan: any non‑zero balance from any oracle on a registered asset counts as "has positions"
        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // All registered oracles should implement IBalanceOracleAdapter
            // Interface validation is done during oracle registration, not here
            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(oracle);
            address[] memory assetsList;
            uint256[] memory amounts;
            try adapter.getOracleBalances(account) returns (
                address[] memory oracleAssets, uint256[] memory amounts_, bool[] memory
            ) {
                assetsList = oracleAssets;
                amounts = amounts_;
            } catch {
                // Oracle doesn't implement IBalanceOracleAdapter, skip it
                continue;
            }

            for (uint256 j = 0; j < assetsList.length; j++) {
                // Skip unregistered assets
                if (!isAssetRegistered(assetsList[j])) {
                    continue;
                }

                if (amounts[j] != 0) {
                    return true;
                }
            }
        }

        return false;
    }

    /// @notice Internal function to get assets with non-zero balances for an account
    /// @param account The address of the account to check
    /// @return assetsWithPositions Array of asset addresses that have at least one non-zero balance
    function _getAssetsWithPositions(address account) internal view returns (address[] memory assetsWithPositions) {
        uint256 totalAssets = getAssetCount();
        if (totalAssets == 0) {
            return new address[](0);
        }

        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;
        if (totalOracles == 0) {
            return new address[](0);
        }

        // Temporary array to collect unique assets with positions.
        // Upper bound for distinct registered assets with positions is totalAssets.
        address[] memory tempAssets = new address[](totalAssets);
        uint256 count = 0;

        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // All registered oracles should implement IBalanceOracleAdapter
            // Interface validation is done during oracle registration, not here
            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(oracle);
            address[] memory assetsList;
            uint256[] memory amounts;
            try adapter.getOracleBalances(account) returns (
                address[] memory oracleAssets, uint256[] memory amounts_, bool[] memory
            ) {
                assetsList = oracleAssets;
                amounts = amounts_;
            } catch {
                // Oracle doesn't implement IBalanceOracleAdapter, skip it
                continue;
            }

            for (uint256 j = 0; j < assetsList.length; j++) {
                address assetAddr = assetsList[j];

                // Skip unregistered assets
                if (!isAssetRegistered(assetAddr)) {
                    continue;
                }

                // Skip zero balances
                if (amounts[j] == 0) {
                    continue;
                }

                // Deduplicate: only add asset once
                bool alreadyAdded = false;
                for (uint256 k = 0; k < count; k++) {
                    if (tempAssets[k] == assetAddr) {
                        alreadyAdded = true;
                        break;
                    }
                }

                if (!alreadyAdded) {
                    tempAssets[count] = assetAddr;
                    count++;

                    // If we've reached the maximum possible distinct assets, we can stop early
                    if (count == totalAssets) {
                        break;
                    }
                }
            }
        }

        if (count == 0) {
            return new address[](0);
        }

        assetsWithPositions = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            assetsWithPositions[i] = tempAssets[i];
        }
    }

    /// @inheritdoc INAVCalculator
    function getAssetsWithPositions(address account) external view override returns (address[] memory) {
        return _getAssetsWithPositions(account);
    }

    /// @inheritdoc INAVCalculator
    function calculateValue(address[] memory assetAddresses, uint256[] memory amounts, address quoteAsset)
        external
        view
        override
        returns (int256 value)
    {
        if (assetAddresses.length != amounts.length) {
            revert InvalidArgumentsWithContext("arrays.length mismatch");
        }

        if (quoteAsset != address(0)) {
            _requireAssetExists(quoteAsset);
            _requirePriceFeedExists(quoteAsset);
        }

        int256 quoteAssetPrice = 0;
        uint8 quoteAssetPriceDecimals = 0;
        uint8 quoteAssetDecimals = 0;
        if (quoteAsset != address(0)) {
            (quoteAssetPrice, quoteAssetPriceDecimals,) = _latestPrice(quoteAsset);
            quoteAssetDecimals = _getAssetDecimals(quoteAsset);
        } else {
            quoteAssetDecimals = NAV_DECIMALS;
        }

        int256 totalUsd = 0;
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;

            address asset = assetAddresses[i];
            _requireAssetExists(asset);
            _requirePriceFeedExists(asset);
            uint8 assetDecimals = _getAssetDecimals(asset);
            (int256 usdRate, uint256 usdRateDecimals,) = _latestPrice(asset);
            // All amounts are positive balances (credit only)
            totalUsd += _toUsd(amount, false, assetDecimals, usdRate, usdRateDecimals);
        }

        if (quoteAsset != address(0)) {
            if (quoteAssetPrice <= 0) {
                revert InvalidArgumentsWithContext("quoteAssetPrice <= 0");
            }
            value = _fromUsd(totalUsd, quoteAssetPrice, quoteAssetPriceDecimals, quoteAssetDecimals);
        } else {
            value = totalUsd;
        }
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
        if (_assetIndex[asset] != 0) {
            revert InvalidArguments(); // Asset already registered
        }
        uint8 decimals;
        string memory symbol;
        if (asset == NATIVE_ADDRESS) {
            decimals = 18;
            symbol = _nativeTokenSymbol;
        } else {
            try IERC20Metadata(asset).decimals() returns (uint8 d) {
                decimals = d;
            } catch {
                revert InvalidArguments(); // Not ERC20 compatible
            }
            try IERC20Metadata(asset).symbol() returns (string memory s) {
                symbol = s;
            } catch {
                revert InvalidArguments(); // Not ERC20 compatible
            }
        }
        _registeredAssets.push(INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals}));
        _assetIndex[asset] = _registeredAssets.length;
    }

    /// @notice Unregisters an asset from the NAV/Pricing registry
    function _unregisterAsset(address asset) internal {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) {
            revert AssetNotFound();
        }
        uint256 lastIdx = _registeredAssets.length;
        if (idx != lastIdx) {
            INAVCalculator.Asset memory lastAsset = _registeredAssets[lastIdx - 1];
            _registeredAssets[idx - 1] = lastAsset;
            _assetIndex[lastAsset.asset] = idx;
        }
        _registeredAssets.pop();
        delete _assetIndex[asset];
    }

    /// @notice Gets asset decimals from NAV/Pricing registry
    function _getAssetDecimals(address asset) internal view returns (uint8) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) {
            revert AssetNotFound();
        }
        return _registeredAssets[idx - 1].decimals;
    }

    /// @notice Gets asset symbol from NAV/Pricing registry
    function _getAssetSymbol(address asset) internal view returns (string memory) {
        uint256 idx = _assetIndex[asset];
        if (idx == 0) {
            revert AssetNotFound();
        }
        return _registeredAssets[idx - 1].symbol;
    }

    //
    // Internal API
    //

    /// @notice Validates that an asset exists, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requireAssetExists(address underlyingAsset) internal view {
        if (!isAssetRegistered(underlyingAsset)) {
            revert AssetNotFound();
        }
    }

    /// @notice Validates that a price feed exists for an asset, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requirePriceFeedExists(address underlyingAsset) internal view {
        if (priceOracles[underlyingAsset].priceFeed == address(0)) {
            revert PriceFeedNotSet(underlyingAsset);
        }
    }

    /// @notice Validates that a price feed is configured for an asset (quoteAsset validation)
    /// @param quoteAsset The quote asset to validate
    function _requirePriceFeedConfig(address quoteAsset) internal view {
        if (priceOracles[quoteAsset].priceFeed == address(0)) {
            revert PriceFeedNotSet(quoteAsset);
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

    /// @notice Enriches a PositionBalance with pricing information to create a Position
    /// @param balance The balance-only position from an oracle
    /// @param priceFeed The cached price feed information for the asset
    /// @param quoteAssetStruct The quote asset struct
    /// @param quoteAssetPrice The price of the quote asset in USD (0 if USD)
    /// @param quoteAssetPriceDecimals The decimals of the quote asset price
    /// @param quoteAssetDecimals The decimals of the quote asset itself
    /// @param canonicalDecimals Decimals from NAV calculator registry
    /// @param canonicalSymbol Symbol from NAV calculator registry
    /// @return position The enriched Position with pricing information and canonical asset metadata
    function _enrichPositionWithPricing(
        INAVCalculator.PositionBalance memory balance,
        PriceFeedCache memory priceFeed,
        INAVCalculator.Asset memory quoteAssetStruct,
        int256 quoteAssetPrice,
        uint8 quoteAssetPriceDecimals,
        uint8 quoteAssetDecimals,
        uint8 canonicalDecimals,
        string memory canonicalSymbol
    ) internal pure returns (INAVCalculator.Position memory position) {
        // Calculate USD value using canonical decimals from registry
        int256 usdValue = _toUsd(balance.amount, balance.isDebt, canonicalDecimals, priceFeed.price, priceFeed.decimals);

        // Calculate value in quote asset
        int256 value;
        if (quoteAssetStruct.asset == address(0)) {
            // USD quote: direct conversion
            value = usdValue;
        } else {
            // Non-USD quote: convert via USD
            value = _fromUsd(usdValue, quoteAssetPrice, quoteAssetPriceDecimals, quoteAssetDecimals);
        }

        // Build enriched position with canonical asset metadata (decimals, symbol from registry)
        INAVCalculator.Asset memory underlyingAsset = INAVCalculator.Asset({
            asset: balance.underlyingAsset.asset, symbol: canonicalSymbol, decimals: canonicalDecimals
        });
        position = INAVCalculator.Position({
            underlyingAsset: underlyingAsset,
            balanceOracle: balance.balanceOracle,
            amount: balance.amount,
            isDebt: balance.isDebt,
            protocol: balance.protocol,
            positionDetail: balance.positionDetail,
            quoteAsset: quoteAssetStruct,
            value: value,
            price: priceFeed.price,
            priceDecimals: priceFeed.decimals,
            stale: priceFeed.stale
        });
    }

    /// @notice Converts an asset's amount to USD
    /// @param amount The amount of the asset (always positive)
    /// @param isDebt Whether this amount represents debt (true) or credit (false)
    /// @param decimals The number of decimals of the asset
    /// @param usdRate The USD rate of the asset (int256; positive for normal prices)
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @return usd The computed amount in USD (negative for debt, positive for credit)
    function _toUsd(uint256 amount, bool isDebt, uint8 decimals, int256 usdRate, uint256 usdRateDecimals)
        internal
        pure
        returns (int256 usd)
    {
        // Ensure we don't underflow the exponent calculation
        // This prevents invalid decimal combinations that would cause exponentiation issues
        if (decimals + usdRateDecimals < NAV_DECIMALS) {
            revert InvalidArgumentsWithContext("decimals + usdRateDecimals < NAV_DECIMALS");
        }

        uint256 denominator = decimals + usdRateDecimals - NAV_DECIMALS;
        // Prevent exponent that's too large (max uint8 is 255, but we use uint256 for safety)
        if (denominator > MAX_DECIMAL_EXPONENT) {
            revert InvalidArgumentsWithContext("denominator > MAX_DECIMAL_EXPONENT");
        }
        // 10^denominator is cast to int256 in the division; int256 max ~5.7e76, so denominator must be <= 76
        if (denominator > MAX_DECIMAL_EXPONENT_INT256) {
            revert InvalidArgumentsWithContext("denominator > MAX_DECIMAL_EXPONENT_INT256");
        }

        // Signed amount: negative for debt, positive for credit
        int256 signedAmount = isDebt ? -SafeCast.toInt256(amount) : SafeCast.toInt256(amount);
        // USD value = signedAmount * usdRate / 10^denominator
        usd = (signedAmount * usdRate) / SafeCast.toInt256(10 ** denominator);
    }

    /// @notice Converts USD value to quote asset value
    /// @param usdValue The USD value with NAV_DECIMALS decimals
    /// @param quoteAssetPrice The USD price of the quote asset (int256; must be positive)
    /// @param quoteAssetPriceDecimals The number of decimals of the quote asset price
    /// @param quoteAssetDecimals The number of decimals of the quote asset
    /// @return quoteAssetValue The computed value in the quote asset with quoteAssetDecimals
    function _fromUsd(int256 usdValue, int256 quoteAssetPrice, uint8 quoteAssetPriceDecimals, uint8 quoteAssetDecimals)
        internal
        pure
        returns (int256 quoteAssetValue)
    {
        if (quoteAssetPrice <= 0) {
            revert InvalidArgumentsWithContext("quoteAssetPrice <= 0");
        }

        // Calculate the scaling factor needed
        // We need: (usdValue * 10^(quoteAssetDecimals + quoteAssetPriceDecimals)) / (quoteAssetPrice * 10^NAV_DECIMALS)
        // This ensures the result is in quoteAssetDecimals

        // Check for potential overflow in exponent calculation
        uint256 totalDecimals = uint256(quoteAssetDecimals) + uint256(quoteAssetPriceDecimals);
        if (totalDecimals > MAX_DECIMAL_EXPONENT) {
            revert InvalidArgumentsWithContext("totalDecimals > MAX_DECIMAL_EXPONENT");
        }
        if (totalDecimals > MAX_DECIMAL_EXPONENT_INT256) {
            revert InvalidArgumentsWithContext("totalDecimals > MAX_DECIMAL_EXPONENT_INT256");
        }

        // Calculate numerator: usdValue * 10^(quoteAssetDecimals + quoteAssetPriceDecimals)
        int256 numerator = usdValue * SafeCast.toInt256(10 ** totalDecimals);

        // Calculate denominator: quoteAssetPrice * 10^NAV_DECIMALS
        int256 denominator = quoteAssetPrice * SafeCast.toInt256(10 ** NAV_DECIMALS);

        quoteAssetValue = numerator / denominator;
    }
}
