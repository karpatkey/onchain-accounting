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
import {ArrayLib} from "src/utils/ArrayLib.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAV Calculator
/// @notice NAV Calculator.
/// @author kpk
contract NAVCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable, INAVCalculator, Prices, Balances {
    //
    // Libraries
    //
    using ERC165Checker for address;

    //
    // Helper functions for array operations
    //

    /// @notice Returns an empty Asset array
    function _emptyAssetArray() private pure returns (INAVCalculator.Asset[] memory) {
        return new INAVCalculator.Asset[](0);
    }

    /// @notice Returns an empty PositionBalance array
    function _emptyPositionBalanceArray() private pure returns (INAVCalculator.PositionBalance[] memory) {
        return new INAVCalculator.PositionBalance[](0);
    }

    /// @notice Returns an empty Position array
    function _emptyPositionArray() private pure returns (INAVCalculator.Position[] memory) {
        return new INAVCalculator.Position[](0);
    }

    /// @notice Returns an empty address array
    function _emptyAddressArray() private pure returns (address[] memory) {
        return new address[](0);
    }

    /// @notice Copies the first `count` elements of `src` into a new array
    function _copySlicePositionBalance(INAVCalculator.PositionBalance[] memory src, uint256 count)
        private
        pure
        returns (INAVCalculator.PositionBalance[] memory dst)
    {
        dst = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            dst[i] = src[i];
        }
    }

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
        public
        initializer
    {
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

        // Set price feed as part of registration
        _setPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);

        // Add asset to default oracle's inclusion list so wallet balances are reported
        ERC20DefaultOracle(erc20DefaultOracle).addSupportedAsset(asset);

        emit AssetRegistered(asset, _getRegisteredAsset(asset).decimals);
    }

    /// @inheritdoc INAVCalculator
    function setPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        _requireManager();
        if (priceFeed == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(asset);

        _setPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function addBalanceOracle(address oracle) external {
        _requireManager();
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        _addBalanceOracle(oracle);
    }

    /// @inheritdoc INAVCalculator
    function unsetPriceFeed(address underlyingAsset) external {
        _requireManager();

        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);

        _unsetPriceFeed(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function removeBalanceOracle(address oracle) external {
        _requireManager();

        _removeBalanceOracle(oracle);
    }

    /// @inheritdoc INAVCalculator
    function excludeAssetFromDefaultOracle(address asset) external {
        _requireManager();
        _requireAssetExists(asset);
        ERC20DefaultOracle(erc20DefaultOracle).removeSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function includeAssetInDefaultOracle(address asset) external {
        _requireManager();
        _requireAssetExists(asset);
        ERC20DefaultOracle(erc20DefaultOracle).addSupportedAsset(asset);
    }

    /// @inheritdoc INAVCalculator
    function unregisterAsset(address underlyingAsset) external {
        _requireManager();

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
        _requireManager();
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
        _validateQuoteAsset(quoteAsset);

        nav.timestamp = uint64(block.timestamp);
        QuoteAssetInfo memory quoteInfo = _getQuoteAssetInfo(quoteAsset);
        nav.quoteAsset = quoteInfo.assetStruct;

        uint256 length = getAssetCount();

        if (length != 0) {
            // read all of the account's positions
            // NOTE: this can exceed gas limit
            (int256 totalValue, INAVCalculator.Asset[] memory staleAssets, bool sequencerDown) =
                _readPositionsWithQuote(account, quoteAsset);
            nav.value = totalValue;
            nav.stalePriceAssets = staleAssets;
            nav.sequencerDown = sequencerDown;
        } else {
            nav.value = 0;
            nav.stalePriceAssets = _emptyAssetArray();
            nav.sequencerDown = false;
        }
    }

    /// @notice Reads all holdings of a given account with quote currency conversion (no range filtering).
    function _readPositionsWithQuote(address account, address quoteAsset)
        internal
        view
        returns (int256 totalValue, INAVCalculator.Asset[] memory stalePriceAssets, bool sequencerDown)
    {
        sequencerDown = _isSequencerDown();

        INAVCalculator.PositionBalance[] memory allPositions = _getAllPositionBalancesForAccount(account);
        if (allPositions.length == 0) {
            totalValue = 0;
            stalePriceAssets = _emptyAssetArray();
            return (totalValue, stalePriceAssets, sequencerDown);
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds = _buildPriceFeedCache(assetsWithPositions);
        stalePriceAssets = _buildStaleAssetsFromPriceFeeds(priceFeeds);

        QuoteAssetInfo memory quoteInfo = _getQuoteAssetInfo(quoteAsset);

        totalValue = 0;
        uint256 positionsLength = allPositions.length;
        for (uint256 i = 0; i < positionsLength; i++) {
            INAVCalculator.PositionBalance memory pos = allPositions[i];
            address asset = pos.underlyingAsset.asset;
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, asset);
            uint8 canonicalDecimals = _getRegisteredAsset(asset).decimals;
            totalValue += _priceConversion(
                pos.amount,
                pos.isDebt,
                canonicalDecimals,
                feed.price,
                feed.decimals,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.assetDecimals
            );
        }
    }

    /// @notice Calls adapter via interface; returns INAVCalculator.PositionBalance[] (same layout as INAVCalculator structs).
    function _getOraclePositionsView(address oracle, address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        try IBalanceOracleAdapter(oracle).getOraclePositions(account, assetFilter) returns (
            INAVCalculator.PositionBalance[] memory pos
        ) {
            return pos;
        } catch {
            return _emptyPositionBalanceArray();
        }
    }

    /// @notice Returns position balances for an account, optionally filtered by asset (address(0) = all assets).
    /// @param account Account address
    /// @param assetFilter Asset to filter by (address(0) for all assets)
    /// @return positions Filtered position balances (registered assets only)
    function _getPositionBalances(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;
        uint256 maxPositions = assetFilter == address(0) ? totalOracles * getAssetCount() : totalOracles;
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](maxPositions);
        uint256 count = 0;

        for (uint256 i = 0; i < totalOracles; i++) {
            INAVCalculator.PositionBalance[] memory oraclePositions =
                _getOraclePositionsView(allOracles[i], account, assetFilter);

            for (uint256 j = 0; j < oraclePositions.length; j++) {
                address asset = oraclePositions[j].underlyingAsset.asset;
                if (!isAssetRegistered(asset)) continue;
                if (assetFilter != address(0) && asset != assetFilter) continue;
                temp[count++] = oraclePositions[j];
            }
        }

        positions = _copySlicePositionBalance(temp, count);
    }

    /// @notice Returns all position balances for an account from oracles (registered assets only).
    function _getAllPositionBalancesForAccount(address account)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return _getPositionBalances(account, address(0));
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        return _getAccountPositionsInternal(account, address(0), quoteAsset);
    }

    /// @notice Returns positions for an account, optionally filtered by a single asset. assetFilter == address(0) means all assets.
    function _getAccountPositionsInternal(address account, address assetFilter, address quoteAsset)
        internal
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        _validateQuoteAsset(quoteAsset);
        _validateAssetFilter(assetFilter);

        INAVCalculator.PositionBalance[] memory positionBalances;
        address[] memory assetsWithPositions;

        if (assetFilter == address(0)) {
            positionBalances = _getAllPositionBalancesForAccount(account);
            assetsWithPositions = _extractUniqueAssets(positionBalances);
        } else {
            positionBalances = _getPositionBalances(account, assetFilter);
            if (positionBalances.length == 0) {
                return _emptyPositionArray();
            }
            assetsWithPositions = new address[](1);
            assetsWithPositions[0] = assetFilter;
        }

        PriceFeedCache[] memory priceFeeds = _buildPriceFeedCache(assetsWithPositions);
        QuoteAssetInfo memory quoteInfo = _getQuoteAssetInfo(quoteAsset);
        return _enrichPositionsWithPricing(
            positionBalances,
            priceFeeds,
            quoteInfo.assetStruct,
            quoteInfo.price,
            quoteInfo.priceDecimals,
            quoteInfo.assetDecimals
        );
    }

    /// @notice Enriches position balances with pricing; shared by getAccountPositions and getAccountPositionsForAsset.
    function _enrichPositionsWithPricing(
        INAVCalculator.PositionBalance[] memory positionBalances,
        PriceFeedCache[] memory priceFeeds,
        INAVCalculator.Asset memory quoteAssetStruct,
        int256 quoteAssetPrice,
        uint8 quoteAssetPriceDecimals,
        uint8 quoteAssetDecimals
    ) internal view returns (INAVCalculator.Position[] memory positions) {
        uint256 length = positionBalances.length;
        positions = new INAVCalculator.Position[](length);
        for (uint256 i = 0; i < length; i++) {
            INAVCalculator.PositionBalance memory balance = positionBalances[i];
            address asset = balance.underlyingAsset.asset;
            INAVCalculator.Asset memory registered = _getRegisteredAsset(asset);
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, asset);
            positions[i] = _enrichPositionWithPricing(
                balance,
                feed,
                quoteAssetStruct,
                quoteAssetPrice,
                quoteAssetPriceDecimals,
                quoteAssetDecimals,
                registered.decimals,
                registered.symbol
            );
        }
    }

    /// @notice Helper struct for price feed caching
    struct PriceFeedCache {
        address asset;
        int256 price;
        uint8 decimals;
        bool stale;
    }

    /// @notice Helper struct combining quote asset info (struct + price data)
    struct QuoteAssetInfo {
        INAVCalculator.Asset assetStruct;
        int256 price;
        uint8 priceDecimals;
        uint8 assetDecimals;
    }

    /// @notice Finds price feed for an asset in the cache array
    function _findPriceFeed(PriceFeedCache[] memory priceFeeds, address asset)
        internal
        pure
        returns (PriceFeedCache memory priceFeed)
    {
        uint256 length = priceFeeds.length;
        for (uint256 i = 0; i < length; i++) {
            priceFeed = priceFeeds[i];
            if (priceFeed.asset == asset) return priceFeed;
        }
        revert AssetNotFound();
    }

    /// @notice Builds price feed cache for a list of assets (shared by NAV and positions flows).
    function _buildPriceFeedCache(address[] memory assets) internal view returns (PriceFeedCache[] memory priceFeeds) {
        uint256 length = assets.length;
        priceFeeds = new PriceFeedCache[](length);
        for (uint256 i = 0; i < length; i++) {
            address asset = assets[i];
            (int256 price, uint8 decimals, bool stale) = _latestPrice(asset);
            priceFeeds[i] = PriceFeedCache({asset: asset, price: price, decimals: decimals, stale: stale});
        }
    }

    /// @notice Builds stale-price Asset[] from price feed cache (deduplicated).
    function _buildStaleAssetsFromPriceFeeds(PriceFeedCache[] memory priceFeeds)
        internal
        view
        returns (INAVCalculator.Asset[] memory staleAssets)
    {
        uint256 feedsLength = priceFeeds.length;
        address[] memory temp = new address[](feedsLength);
        uint256 count = 0;
        for (uint256 i = 0; i < feedsLength; i++) {
            PriceFeedCache memory feed = priceFeeds[i];
            if (feed.stale) {
                temp[count++] = feed.asset;
            }
        }
        address[] memory staleAddrs = ArrayLib.copySliceAddress(temp, count);
        staleAddrs = ArrayLib.deduplicateAddresses(staleAddrs);

        uint256 staleLength = staleAddrs.length;
        staleAssets = new INAVCalculator.Asset[](staleLength);
        for (uint256 i = 0; i < staleLength; i++) {
            staleAssets[i] = _getRegisteredAsset(staleAddrs[i]);
        }
    }

    /// @notice Returns complete quote asset information (struct + price data); address(0) = USD.
    function _getQuoteAssetInfo(address quoteAsset) internal view returns (QuoteAssetInfo memory info) {
        if (quoteAsset == address(0)) {
            info.assetStruct = INAVCalculator.Asset({asset: address(0), symbol: "USD", decimals: NAV_DECIMALS});
            info.price = 0;
            info.priceDecimals = 0;
            info.assetDecimals = NAV_DECIMALS;
        } else {
            _requirePriceFeedExists(quoteAsset);
            (info.price, info.priceDecimals,) = _latestPrice(quoteAsset);
            INAVCalculator.Asset memory reg = _getRegisteredAsset(quoteAsset);
            info.assetStruct = INAVCalculator.Asset({
                asset: quoteAsset,
                symbol: quoteAsset == NATIVE_ADDRESS ? _nativeTokenSymbol : reg.symbol,
                decimals: reg.decimals
            });
            info.assetDecimals = reg.decimals;
        }
    }

    /// @notice Extracts unique assets from balance positions array
    /// @param positions Array of balance-only positions
    /// @return uniqueAssets Array of unique asset addresses
    function _extractUniqueAssets(INAVCalculator.PositionBalance[] memory positions)
        internal
        pure
        returns (address[] memory uniqueAssets)
    {
        uint256 length = positions.length;
        address[] memory allAssets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            allAssets[i] = positions[i].underlyingAsset.asset;
        }
        uniqueAssets = ArrayLib.deduplicateAddresses(allAssets);
    }

    /// @inheritdoc INAVCalculator
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        return _getAccountPositionsInternal(account, asset, quoteAsset);
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

        sequencerDown = _isSequencerDown();

        if (totalAssets == 0) {
            stalePriceAssets = _emptyAddressArray();
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
            stalePriceAssets = _emptyAddressArray();
        } else {
            stalePriceAssets = ArrayLib.copySliceAddress(staleAssetsTemp, staleCount);
        }
    }

    /// @inheritdoc INAVCalculator
    function hasPositions(address account) external view override returns (bool has) {
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;
        // Oracle‑centric scan: any non‑zero balance from any oracle on a registered asset counts as "has positions"
        for (uint256 i = 0; i < totalOracles; i++) {
            (address[] memory assetsList, uint256[] memory amounts,) =
                IBalanceOracleAdapter(allOracles[i]).getOracleBalances(account);
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

    /// @inheritdoc INAVCalculator
    function getAssetsWithPositions(address account) external view override returns (address[] memory) {
        return _extractUniqueAssets(_getAllPositionBalancesForAccount(account));
    }

    /// @inheritdoc INAVCalculator
    function calculateValue(address[] memory assetAddresses, uint256[] memory amounts, address quoteAsset)
        external
        view
        override
        returns (int256 value)
    {
        if (assetAddresses.length != amounts.length) {
            revert ArrayLengthMismatch();
        }

        if (quoteAsset != address(0)) {
            _requireAssetExists(quoteAsset);
        }
        _validateQuoteAsset(quoteAsset);

        QuoteAssetInfo memory quoteInfo = _getQuoteAssetInfo(quoteAsset);

        value = 0;
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;

            address asset = assetAddresses[i];
            _requireAssetExists(asset);
            _requirePriceFeedExists(asset);
            uint8 assetDecimals = _getRegisteredAsset(asset).decimals;
            (int256 usdRate, uint256 usdRateDecimals,) = _latestPrice(asset);
            value += _priceConversion(
                amount,
                false,
                assetDecimals,
                usdRate,
                usdRateDecimals,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.assetDecimals
            );
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

    /// @notice Validates that a price feed exists for an asset, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requirePriceFeedExists(address underlyingAsset) internal view {
        if (priceOracles[underlyingAsset].priceFeed == address(0)) {
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
        int256 value = _priceConversion(
            balance.amount,
            balance.isDebt,
            canonicalDecimals,
            priceFeed.price,
            priceFeed.decimals,
            quoteAssetPrice,
            quoteAssetPriceDecimals,
            quoteAssetDecimals
        );

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

    /// @notice Converts an amount of one asset to value in quote (USD when quotePrice is 0).
    /// @param amount Amount of the asset (positive)
    /// @param isDebt True if debt (result will be negative)
    /// @param assetDecimals Decimals of the asset
    /// @param assetPrice USD price of the asset
    /// @param assetPriceDecimals Decimals of assetPrice
    /// @param quotePrice USD price of quote asset (0 for USD)
    /// @param quotePriceDecimals Decimals of quotePrice
    /// @param quoteDecimals Decimals of the quote asset (use NAV_DECIMALS when quote is USD)
    /// @return value Value in quote asset (or USD when quotePrice is 0)
    function _priceConversion(
        uint256 amount,
        bool isDebt,
        uint8 assetDecimals,
        int256 assetPrice,
        uint256 assetPriceDecimals,
        int256 quotePrice,
        uint8 quotePriceDecimals,
        uint8 quoteDecimals
    ) internal pure returns (int256 value) {
        if (assetDecimals + assetPriceDecimals < NAV_DECIMALS) {
            revert InvalidAssetDecimals();
        }
        uint256 denom1 = assetDecimals + assetPriceDecimals - NAV_DECIMALS;
        if (denom1 > MAX_DECIMAL_EXPONENT || denom1 > MAX_DECIMAL_EXPONENT_INT256) {
            revert InvalidDecimalExponent();
        }

        int256 signedAmount = isDebt ? -SafeCast.toInt256(amount) : SafeCast.toInt256(amount);
        int256 usdValue = (signedAmount * assetPrice) / SafeCast.toInt256(10 ** denom1);

        if (quotePrice <= 0) {
            return usdValue; // USD (NAV_DECIMALS)
        }

        uint256 totalDecimals = uint256(quoteDecimals) + uint256(quotePriceDecimals);
        if (totalDecimals > MAX_DECIMAL_EXPONENT || totalDecimals > MAX_DECIMAL_EXPONENT_INT256) {
            revert InvalidDecimalExponent();
        }
        int256 numerator = usdValue * SafeCast.toInt256(10 ** totalDecimals);
        int256 denom2 = quotePrice * SafeCast.toInt256(10 ** NAV_DECIMALS);
        return numerator / denom2;
    }
}
