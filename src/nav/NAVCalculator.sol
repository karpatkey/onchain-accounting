// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPrices, Prices} from "src/prices/Prices.sol";
import {IBalances, Balances} from "src/balances/Balances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {ERC20DefaultOracle} from "src/balances/ERC20DefaultOracle.sol";
import {INAVCalculator} from "./INAVCalculator.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAV Calculator
/// @notice Calculates NAV based on on-chain balances and price oracles.
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
    function initialize(address admin_, address assetRecoverer_, address chainlinkL2SequencerUptimeFeed_)
        public
        initializer
    {
        __AccessControl_init();
        __Prices_init(chainlinkL2SequencerUptimeFeed_);
        __Balances_init();

        // Deploy and register ERC20Default oracle
        ERC20DefaultOracle defaultOracle = new ERC20DefaultOracle(address(this));
        _setErc20DefaultOracle(address(defaultOracle));

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        assetRecoverer = assetRecoverer_;
    }

    //
    // INAVCalculator
    //

    /// @inheritdoc INAVCalculator
    function registerAsset(address asset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (asset == address(0)) {
            revert InvalidArguments();
        }
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        // Check if asset already exists
        if (isAssetRegistered(asset)) {
            revert InvalidArguments(); // Asset already registered
        }

        // Assumption: All native assets use 18 decimals (EVM standard)
        // If deploying on a chain with different native decimals, this must be made configurable
        uint8 decimals = asset == NATIVE_ADDRESS ? 18 : IERC20Metadata(asset).decimals();
        _registerAsset(asset, decimals);

        // Try to fetch and cache symbol
        string memory symbol;
        if (asset == NATIVE_ADDRESS) {
            symbol = _nativeTokenSymbol;
        } else {
            try IERC20Metadata(asset).symbol() returns (string memory symbol_) {
                symbol = symbol_;
            } catch {
                symbol = "";
            }
        }
        _setAssetSymbol(asset, symbol);

        // Set price feed as part of registration
        _setPriceFeed(asset, oracle, chainlinkHeartbeat, priceType);

        emit AssetRegistered(asset, decimals);
    }

    /// @inheritdoc INAVCalculator
    function setPriceFeed(address asset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(asset);

        _setPriceFeed(asset, oracle, chainlinkHeartbeat, priceType);
    }

    /// @inheritdoc INAVCalculator
    function addBalanceOracle(address underlyingAsset, address oracle, IBalances.OracleType balanceType) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(underlyingAsset);

        _addBalanceOracle(underlyingAsset, oracle, balanceType);
    }

    /// @inheritdoc INAVCalculator
    function unsetPriceFeed(address underlyingAsset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _requireAssetExists(underlyingAsset);
        _requirePriceFeedExists(underlyingAsset);

        _unsetPriceFeed(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function removeBalanceOracle(address underlyingAsset, address oracle) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _requireAssetExists(underlyingAsset);

        _removeBalanceOracle(underlyingAsset, oracle);
    }

    /// @inheritdoc INAVCalculator
    function unregisterAsset(address underlyingAsset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _requireAssetExists(underlyingAsset);

        // Unset price feed if it exists
        if (priceOracles[underlyingAsset].oracle != address(0)) {
            _unsetPriceFeed(underlyingAsset);
        }

        // Unset all balance oracles
        address[] memory oraclesToRemove = balanceOracles(underlyingAsset);

        // Remove all balance oracles
        for (uint256 i = 0; i < oraclesToRemove.length; i++) {
            // Skip native address oracle as it cannot be removed
            if (underlyingAsset == NATIVE_ADDRESS && oraclesToRemove[i] == NATIVE_ADDRESS) {
                continue;
            }
            _removeBalanceOracle(underlyingAsset, oraclesToRemove[i]);
        }

        // Remove the asset itself
        _unregisterAsset(underlyingAsset);

        emit AssetUnregistered(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function setNativeTokenSymbol(string memory nativeTokenSymbol) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        _nativeTokenSymbol = nativeTokenSymbol;
        emit NativeTokenSymbolSet(nativeTokenSymbol);
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
    function getAccountNav(address account, address baseAsset) external view returns (INAVCalculator.NAV memory nav) {
        // Validate quoteAsset has PriceFeedConfig (early validation)
        // Skip validation for address(0) which represents USD (no price feed needed)
        if (baseAsset != address(0)) {
            _requirePriceFeedConfig(baseAsset);
        }

        nav.timestamp = uint64(block.timestamp);

        // Build quoteAsset
        INAVCalculator.Asset memory quoteAsset;
        if (baseAsset != address(0)) {
            uint8 quoteDecimals = _getAssetDecimals(baseAsset);
            string memory quoteSymbol;
            if (baseAsset == NATIVE_ADDRESS) {
                quoteSymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(baseAsset).symbol() returns (string memory symbol_) {
                    quoteSymbol = symbol_;
                } catch {
                    quoteSymbol = "";
                }
            }
            quoteAsset = INAVCalculator.Asset({asset: baseAsset, symbol: quoteSymbol, decimals: quoteDecimals});
        } else {
            quoteAsset = INAVCalculator.Asset({asset: address(0), symbol: "USD", decimals: NAV_DECIMALS});
        }
        nav.quoteAsset = quoteAsset;

        uint256 length = getAssetCount();

        if (length != 0) {
            // read all of the account's positions
            // NOTE: this can exceed gas limit
            (int256 totalValue, INAVCalculator.Asset[] memory staleAssets, bool sequencerDown) =
                _readPositionsRangeWithQuote(account, 0, length - 1, baseAsset);
            nav.value = totalValue;
            nav.issues = INAVCalculator.HealthCheck({stalePriceAssets: staleAssets, sequencerDown: sequencerDown});
        } else {
            // Initialize empty arrays when no assets
            nav.value = 0;
            nav.issues =
                INAVCalculator.HealthCheck({stalePriceAssets: new INAVCalculator.Asset[](0), sequencerDown: false});
        }
    }

    /// @inheritdoc INAVCalculator

    /// @notice Reads the holdings of a given account, for a limited range of assets, with quote currency conversion.
    /// @dev Range is expressed in terms of the current asset enumeration (from `assets()`).
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
        address[] memory allAssets = getAssets();
        uint256 rangeSize = to - from + 1;
        address[] memory rangeAssets = new address[](rangeSize);
        for (uint256 i = 0; i < rangeSize; i++) {
            rangeAssets[i] = allAssets[from + i];
        }

        // Get all registered oracles from global registry
        address[] memory allOracles = getAllOracles();
        uint256 totalOracles = allOracles.length;

        // First pass: collect all positions from all oracles, then filter to the rangeAssets set
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](totalOracles * rangeSize); // upper bound estimate
        uint256 positionCount = 0;

        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // Skip oracles that don't implement IBalanceOracleAdapter
            // ERC20 tokens added as balance oracles don't implement this interface
            // They are handled by ERC20DefaultOracle instead
            // Use try-catch since some contracts don't implement IERC165 and will revert
            bool supportsAdapter;
            try IERC165(oracle).supportsInterface(type(IBalanceOracleAdapter).interfaceId) returns (bool result) {
                supportsAdapter = result;
            } catch {
                supportsAdapter = false;
            }
            if (!supportsAdapter) {
                continue;
            }

            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(oracle);

            // assetFilter = address(0) → oracle returns all assets it knows for this account
            INAVCalculator.Position[] memory oraclePositions = adapter.getOraclePositions(account, address(0));

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
        INAVCalculator.Position[] memory positionsInRange = new INAVCalculator.Position[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positionsInRange[i] = tempPositions[i];
        }

        // Collect unique assets from positions for price lookups
        address[] memory assetsWithPositions = _extractUniqueAssets(positionsInRange);

        // Fetch prices for each asset once, track staleness
        PriceFeedCache[] memory priceFeeds = new PriceFeedCache[](assetsWithPositions.length);
        for (uint256 i = 0; i < assetsWithPositions.length; i++) {
            address asset = assetsWithPositions[i];
            (uint256 price, uint8 priceDecimals, bool stale) = _latestPrice(asset);
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

        // Get quote currency price info if not USD
        uint256 quoteCurrencyPrice = 0;
        uint8 quoteCurrencyPriceDecimals = 0;
        uint8 quoteCurrencyDecimals = 0;
        if (quoteAsset != address(0)) {
            _requirePriceFeedConfig(quoteAsset);
            (quoteCurrencyPrice, quoteCurrencyPriceDecimals,) = _latestPrice(quoteAsset);
            quoteCurrencyDecimals = _getAssetDecimals(quoteAsset);
        } else {
            quoteCurrencyDecimals = NAV_DECIMALS;
        }

        // Sum USD value of all positions in range
        int256 totalUsd = 0;
        for (uint256 i = 0; i < positionsInRange.length; i++) {
            INAVCalculator.Position memory pos = positionsInRange[i];
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, pos.underlyingAsset.asset);

            int256 usdValue = _toUsd(pos.balance, pos.underlyingAsset.decimals, feed.price, feed.decimals);
            totalUsd += usdValue;
        }

        // Convert USD total to quote currency if needed
        if (quoteAsset != address(0)) {
            totalValue = _fromUsd(totalUsd, quoteCurrencyPrice, quoteCurrencyPriceDecimals, quoteCurrencyDecimals);
        } else {
            totalValue = totalUsd;
        }
    }

    /// @inheritdoc INAVCalculator
    function getAccountNavForRange(address account, uint256 from, uint256 to, address baseAsset)
        external
        view
        returns (INAVCalculator.NAV memory nav)
    {
        // Validate quoteAsset has PriceFeedConfig (early validation)
        // Skip validation for address(0) which represents USD (no price feed needed)
        if (baseAsset != address(0)) {
            _requirePriceFeedConfig(baseAsset);
        }

        nav.timestamp = uint64(block.timestamp);

        // Build quoteAsset
        INAVCalculator.Asset memory quoteAsset;
        if (baseAsset != address(0)) {
            uint8 quoteDecimals = _getAssetDecimals(baseAsset);
            string memory quoteSymbol;
            if (baseAsset == NATIVE_ADDRESS) {
                quoteSymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(baseAsset).symbol() returns (string memory symbol_) {
                    quoteSymbol = symbol_;
                } catch {
                    quoteSymbol = "";
                }
            }
            quoteAsset = INAVCalculator.Asset({asset: baseAsset, symbol: quoteSymbol, decimals: quoteDecimals});
        } else {
            quoteAsset = INAVCalculator.Asset({asset: address(0), symbol: "USD", decimals: NAV_DECIMALS});
        }
        nav.quoteAsset = quoteAsset;

        (int256 totalValue, INAVCalculator.Asset[] memory staleAssets, bool sequencerDown) =
            _readPositionsRangeWithQuote(account, from, to, baseAsset);
        nav.value = totalValue;
        nav.issues = INAVCalculator.HealthCheck({stalePriceAssets: staleAssets, sequencerDown: sequencerDown});
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
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](totalOracles * 10); // Estimate
        uint256 positionCount = 0;

        // Loop through all oracles (oracle-centric aggregation)
        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // Skip oracles that don't implement IBalanceOracleAdapter
            // ERC20 tokens added as balance oracles don't implement this interface
            // They are handled by ERC20DefaultOracle instead
            if (!oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId)) {
                continue;
            }

            // Call getOraclePositions() on each oracle adapter
            // Each oracle returns all positions it knows about for this account
            // assetFilter = address(0) means "return all assets"
            IBalanceOracleAdapter oracleAdapter = IBalanceOracleAdapter(oracle);
            INAVCalculator.Position[] memory oraclePositions = oracleAdapter.getOraclePositions(account, address(0));

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
        INAVCalculator.Position[] memory allPositions = new INAVCalculator.Position[](positionCount);
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
            (uint256 price, uint8 priceDecimals, bool stale) = _latestPrice(asset);
            priceFeeds[i] = PriceFeedCache({asset: asset, price: price, decimals: priceDecimals, stale: stale});
        }

        // Get quote currency info
        // Note: Quote asset price is fetched separately as it may not be in the positions
        uint256 quoteCurrencyPrice = 0;
        uint8 quoteCurrencyPriceDecimals = 0;
        uint8 quoteCurrencyDecimals = 0;
        string memory quoteCurrencySymbol = "";

        if (quoteAsset != address(0)) {
            // Quote asset price feed is validated earlier, so we can safely fetch it
            (quoteCurrencyPrice, quoteCurrencyPriceDecimals,) = _latestPrice(quoteAsset);
            quoteCurrencyDecimals = _getAssetDecimals(quoteAsset);
            if (quoteAsset == NATIVE_ADDRESS) {
                quoteCurrencySymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(quoteAsset).symbol() returns (string memory symbol_) {
                    quoteCurrencySymbol = symbol_;
                } catch {
                    quoteCurrencySymbol = "";
                }
            }
        } else {
            quoteCurrencyDecimals = NAV_DECIMALS;
            quoteCurrencySymbol = "USD";
        }

        INAVCalculator.Asset memory quoteAssetStruct =
            INAVCalculator.Asset({asset: quoteAsset, symbol: quoteCurrencySymbol, decimals: quoteCurrencyDecimals});

        // Attach pricing to positions and calculate values
        // Note: All positions here are for registered assets (filtered earlier at line 516)
        // If a registered asset doesn't have a price feed, _latestPrice will revert above
        for (uint256 i = 0; i < allPositions.length; i++) {
            address asset = allPositions[i].underlyingAsset.asset;
            PriceFeedCache memory priceFeed = _findPriceFeed(priceFeeds, asset);

            // Update position with pricing
            allPositions[i].price = priceFeed.price;
            allPositions[i].priceDecimals = priceFeed.decimals;
            allPositions[i].stale = priceFeed.stale;
            allPositions[i].quoteAsset = quoteAssetStruct;

            // Calculate value: Convert balance (in underlying asset) to value (in quote asset)
            int256 usdValue = _toUsd(
                allPositions[i].balance, allPositions[i].underlyingAsset.decimals, priceFeed.price, priceFeed.decimals
            );

            if (quoteAsset == address(0)) {
                // USD quote: direct conversion
                allPositions[i].value = usdValue;
            } else {
                // Non-USD quote: convert via USD
                allPositions[i].value =
                    _fromUsd(usdValue, quoteCurrencyPrice, quoteCurrencyPriceDecimals, quoteCurrencyDecimals);
            }
        }

        return allPositions;
    }

    /// @notice Helper struct for price feed caching
    struct PriceFeedCache {
        address asset;
        uint256 price;
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

    /// @notice Extracts unique assets from positions array
    /// @param positions Array of positions
    /// @return uniqueAssets Array of unique asset addresses
    function _extractUniqueAssets(INAVCalculator.Position[] memory positions)
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
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](totalOracles);
        uint256 positionCount = 0;

        // Loop through all oracles (oracle-centric aggregation)
        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // Skip oracles that don't implement IBalanceOracleAdapter
            // ERC20 tokens added as balance oracles don't implement this interface
            // They are handled by ERC20DefaultOracle instead
            if (!oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId)) {
                continue;
            }

            // Call getOraclePositions with asset filter
            IBalanceOracleAdapter oracleAdapter = IBalanceOracleAdapter(oracle);
            INAVCalculator.Position[] memory oraclePositions = oracleAdapter.getOraclePositions(account, asset);

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
        INAVCalculator.Position[] memory assetPositions = new INAVCalculator.Position[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            assetPositions[i] = tempPositions[i];
        }

        // Fetch price for this asset (optimized - single fetch)
        (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(asset);

        // Get quote currency price if needed
        uint256 quoteCurrencyPrice = 0;
        uint8 quoteCurrencyPriceDecimals = 0;
        uint8 quoteCurrencyDecimals = 0;
        string memory quoteCurrencySymbol = "";

        if (quoteAsset != address(0)) {
            (quoteCurrencyPrice, quoteCurrencyPriceDecimals,) = _latestPrice(quoteAsset);
            quoteCurrencyDecimals = _getAssetDecimals(quoteAsset);
            if (quoteAsset == NATIVE_ADDRESS) {
                quoteCurrencySymbol = _nativeTokenSymbol;
            } else {
                try IERC20Metadata(quoteAsset).symbol() returns (string memory symbol_) {
                    quoteCurrencySymbol = symbol_;
                } catch {
                    quoteCurrencySymbol = "";
                }
            }
        } else {
            quoteCurrencyDecimals = NAV_DECIMALS;
            quoteCurrencySymbol = "USD";
        }

        INAVCalculator.Asset memory quoteAssetStruct =
            INAVCalculator.Asset({asset: quoteAsset, symbol: quoteCurrencySymbol, decimals: quoteCurrencyDecimals});

        // Attach pricing to positions and calculate values
        for (uint256 i = 0; i < assetPositions.length; i++) {
            assetPositions[i].price = usdRate;
            // casting to 'uint8' is safe because price decimals are always in range 0-255
            // forge-lint: disable-next-line(unsafe-typecast)
            assetPositions[i].priceDecimals = uint8(usdRateDecimals);
            assetPositions[i].stale = stale;
            assetPositions[i].quoteAsset = quoteAssetStruct;

            // Calculate value
            int256 usdValue =
                _toUsd(assetPositions[i].balance, assetPositions[i].underlyingAsset.decimals, usdRate, usdRateDecimals);

            if (quoteAsset == address(0)) {
                assetPositions[i].value = usdValue;
            } else {
                assetPositions[i].value =
                    _fromUsd(usdValue, quoteCurrencyPrice, quoteCurrencyPriceDecimals, quoteCurrencyDecimals);
            }
        }

        return assetPositions;
    }

    /// @inheritdoc INAVCalculator
    function usdDecimals() external pure returns (uint8) {
        return NAV_DECIMALS;
    }

    /// @inheritdoc INAVCalculator
    function assetAt(uint256 idx) external view returns (INAVCalculator.Asset memory a) {
        address[] memory allAssets = getAssets();
        if (idx >= allAssets.length) {
            revert AssetNotFound();
        }
        address asset = allAssets[idx];
        a.asset = asset;
        a.decimals = getAssetDecimals(asset);
        // Get symbol from registry
        a.symbol = getAssetSymbol(asset);
    }

    /// @inheritdoc INAVCalculator
    function assets() external view returns (address[] memory) {
        return getAssets();
    }

    /// @inheritdoc INAVCalculator
    function getPriceData(address underlyingAsset) external view returns (INAVCalculator.PriceFeed memory priceFeed) {
        _requireAssetExists(underlyingAsset);

        IPrices.PriceFeedConfig storage oracle = priceOracles[underlyingAsset];
        _requirePriceFeedExists(underlyingAsset);

        (uint256 price, uint8 decimals, bool stale) = _latestPrice(underlyingAsset);

        priceFeed.oracle = oracle.oracle;
        priceFeed.priceType = oracle.priceType;
        priceFeed.price = price;
        priceFeed.decimals = decimals;
        priceFeed.chainlinkHeartbeat = oracle.chainlinkHeartbeat;
        priceFeed.stale = stale;

        // Get Chainlink-specific data
        if (oracle.priceType == IPrices.PriceType.Chainlink) {
            AggregatorV3Interface chainlinkOracle = AggregatorV3Interface(oracle.oracle);
            (,,, uint256 roundUpdatedAt,) = chainlinkOracle.latestRoundData();
            priceFeed.updatedAt = roundUpdatedAt;
        }

        // Check L2 sequencer uptime (conditional on L2)
        priceFeed.sequencerDown = _isSequencerDown();
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

        address[] memory allAssets = getAssets();
        address[] memory staleAssetsTemp = new address[](totalAssets);
        uint256 staleCount = 0;

        for (uint256 i = 0; i < totalAssets; i++) {
            address assetAddr = allAssets[i];

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

            // Skip oracles that don't implement IBalanceOracleAdapter
            // ERC20 tokens added as balance oracles don't implement this interface
            // They are handled by ERC20DefaultOracle instead
            // Use try-catch since some contracts don't implement IERC165 and will revert
            bool supportsAdapter;
            try IERC165(oracle).supportsInterface(type(IBalanceOracleAdapter).interfaceId) returns (bool result) {
                supportsAdapter = result;
            } catch {
                supportsAdapter = false;
            }
            if (!supportsAdapter) {
                continue;
            }

            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(oracle);

            (address[] memory assetsList, int256[] memory amounts) = adapter.getOracleBalance(account, address(0));

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
        uint256 assetCount = 0;

        for (uint256 i = 0; i < totalOracles; i++) {
            address oracle = allOracles[i];

            // Skip oracles that don't implement IBalanceOracleAdapter
            // ERC20 tokens added as balance oracles don't implement this interface
            // They are handled by ERC20DefaultOracle instead
            // Use try-catch since some contracts don't implement IERC165 and will revert
            bool supportsAdapter;
            try IERC165(oracle).supportsInterface(type(IBalanceOracleAdapter).interfaceId) returns (bool result) {
                supportsAdapter = result;
            } catch {
                supportsAdapter = false;
            }
            if (!supportsAdapter) {
                continue;
            }

            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(oracle);

            (address[] memory assetsList, int256[] memory amounts) = adapter.getOracleBalance(account, address(0));

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
                for (uint256 k = 0; k < assetCount; k++) {
                    if (tempAssets[k] == assetAddr) {
                        alreadyAdded = true;
                        break;
                    }
                }

                if (!alreadyAdded) {
                    tempAssets[assetCount] = assetAddr;
                    assetCount++;

                    // If we've reached the maximum possible distinct assets, we can stop early
                    if (assetCount == totalAssets) {
                        break;
                    }
                }
            }
        }

        if (assetCount == 0) {
            return new address[](0);
        }

        assetsWithPositions = new address[](assetCount);
        for (uint256 i = 0; i < assetCount; i++) {
            assetsWithPositions[i] = tempAssets[i];
        }
    }

    /// @inheritdoc INAVCalculator
    function getAssetsWithPositions(address account) external view override returns (address[] memory) {
        return _getAssetsWithPositions(account);
    }

    /// @inheritdoc INAVCalculator
    function calculateValue(address[] memory assets, int256[] memory balances, address quoteCurrency)
        external
        view
        returns (int256 value)
    {
        if (assets.length != balances.length) {
            revert InvalidArgumentsWithContext("assets.length != balances.length");
        }

        // Get quote currency info if not USD
        uint256 quoteCurrencyPrice = 0;
        uint8 quoteCurrencyPriceDecimals = 0;
        uint8 quoteCurrencyDecimals = 0;

        if (quoteCurrency != address(0)) {
            _requireAssetExists(quoteCurrency);
            _requirePriceFeedExists(quoteCurrency);
            (quoteCurrencyPrice, quoteCurrencyPriceDecimals,) = _latestPrice(quoteCurrency);
            quoteCurrencyDecimals = _getAssetDecimals(quoteCurrency);
        } else {
            quoteCurrencyDecimals = NAV_DECIMALS;
        }

        int256 totalUsd = 0;

        // Calculate USD value for each asset/balance pair
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            int256 balance = balances[i];

            // Skip zero balances
            if (balance == 0) {
                continue;
            }

            // Validate asset exists and has price oracle
            _requireAssetExists(asset);
            _requirePriceFeedExists(asset);

            // Get asset decimals
            uint8 assetDecimals = _getAssetDecimals(asset);

            // Get USD price
            (uint256 usdRate, uint256 usdRateDecimals,) = _latestPrice(asset);

            // Calculate USD value
            int256 usdValue = _toUsd(balance, assetDecimals, usdRate, usdRateDecimals);
            totalUsd += usdValue;
        }

        // Convert to quote currency if needed
        if (quoteCurrency != address(0)) {
            if (quoteCurrencyPrice == 0) {
                revert InvalidArgumentsWithContext("quoteCurrencyPrice == 0");
            }
            value = _fromUsd(totalUsd, quoteCurrencyPrice, quoteCurrencyPriceDecimals, quoteCurrencyDecimals);
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
        if (priceOracles[underlyingAsset].oracle == address(0)) {
            revert PriceFeedNotSet(underlyingAsset);
        }
    }

    /// @notice Validates that a price feed is configured for an asset (quoteAsset validation)
    /// @param quoteAsset The quote asset to validate
    function _requirePriceFeedConfig(address quoteAsset) internal view {
        if (priceOracles[quoteAsset].oracle == address(0)) {
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

    /// @notice Converts an asset's balance to USD
    /// @param balance The balance of the asset
    /// @param decimals The number of decimals of the asset
    /// @param usdRate The USD rate of the asset
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @return usd The computed balance in USD
    function _toUsd(int256 balance, uint8 decimals, uint256 usdRate, uint256 usdRateDecimals)
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
        // This is extremely unlikely in practice but prevents potential issues
        if (denominator > MAX_DECIMAL_EXPONENT) {
            revert InvalidArgumentsWithContext("denominator > MAX_DECIMAL_EXPONENT");
        }

        // casting to 'int256' is safe because usdRate is uint256 and the result fits in int256 range
        // forge-lint: disable-next-line(unsafe-typecast)
        usd = (balance * int256(usdRate)) / int256(10 ** denominator);
    }

    /// @notice Converts USD value to a base asset value
    /// @param usdValue The USD value with NAV_DECIMALS decimals
    /// @param baseAssetPrice The USD price of the base asset
    /// @param baseAssetPriceDecimals The number of decimals of the base asset price
    /// @param baseAssetDecimals The number of decimals of the base asset
    /// @return baseAssetValue The computed value in the base asset with baseAssetDecimals
    function _fromUsd(int256 usdValue, uint256 baseAssetPrice, uint8 baseAssetPriceDecimals, uint8 baseAssetDecimals)
        internal
        pure
        returns (int256 baseAssetValue)
    {
        if (baseAssetPrice == 0) {
            revert InvalidArgumentsWithContext("baseAssetPrice == 0");
        }

        // Calculate the scaling factor needed
        // We need: (usdValue * 10^(baseAssetDecimals + baseAssetPriceDecimals)) / (baseAssetPrice * 10^NAV_DECIMALS)
        // This ensures the result is in baseAssetDecimals

        // Check for potential overflow in exponent calculation
        uint256 totalDecimals = uint256(baseAssetDecimals) + uint256(baseAssetPriceDecimals);
        if (totalDecimals > MAX_DECIMAL_EXPONENT) {
            revert InvalidArgumentsWithContext("totalDecimals > MAX_DECIMAL_EXPONENT");
        }

        // Calculate numerator: usdValue * 10^(baseAssetDecimals + baseAssetPriceDecimals)
        // casting to 'int256' is safe because 10^totalDecimals fits in int256 range (totalDecimals <= 255)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 numerator = usdValue * int256(10 ** totalDecimals);

        // Calculate denominator: baseAssetPrice * 10^NAV_DECIMALS
        // casting to 'int256' is safe because baseAssetPrice and 10^NAV_DECIMALS fit in int256 range
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 denominator = int256(baseAssetPrice) * int256(10 ** NAV_DECIMALS);

        baseAssetValue = numerator / denominator;
    }
}
