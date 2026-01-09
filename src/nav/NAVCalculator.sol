// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPrices, Prices} from "src/prices/Prices.sol";
import {IBalances, Balances} from "src/balances/Balances.sol";
import {INAVCalculator} from "./INAVCalculator.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "src/errors.sol";
import "src/constants.sol";

/// @title NAV Calculator
/// @notice Calculates NAV based on on-chain balances and price oracles.
/// @author kpk
contract NAVCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable, INAVCalculator, Prices, Balances {
    //
    // Libraries
    //
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    //
    // State
    //

    /// @notice Set of known assets to track
    EnumerableMap.AddressToUintMap private _assetDecimals;

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
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        assetRecoverer = assetRecoverer_;
    }

    //
    // INAVCalculator
    //

    /// @inheritdoc INAVCalculator
    function addPrice(address underlyingAsset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external
    {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        // Assumption: All native assets use 18 decimals (EVM standard)
        // If deploying on a chain with different native decimals, this must be made configurable
        uint8 decimals = underlyingAsset == NATIVE_ADDRESS ? 18 : IERC20Metadata(underlyingAsset).decimals();
        _assetDecimals.set(underlyingAsset, decimals);

        _setPriceOracle(underlyingAsset, oracle, chainlinkHeartbeat, priceType);

        emit AssetAdded(underlyingAsset, decimals);
    }

    /// @inheritdoc INAVCalculator
    function addBalance(address underlyingAsset, address oracle, IBalances.BalanceType balanceType) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        if (oracle == address(0)) {
            revert InvalidArguments();
        }

        _requireAssetExists(underlyingAsset);

        _addBalanceOracle(underlyingAsset, oracle, balanceType);
    }

    /// @inheritdoc INAVCalculator
    function removePrice(address underlyingAsset) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        if (balanceOracleCountFor(underlyingAsset) > 0) {
            revert InvalidArguments();
        }

        bool success = _assetDecimals.remove(underlyingAsset);

        if (!success) {
            revert AssetNotFound();
        }
        _removePriceOracle(underlyingAsset);

        emit AssetRemoved(underlyingAsset);
    }

    /// @inheritdoc INAVCalculator
    function removeBalance(address underlyingAsset, address oracle) external {
        if (!hasRole(MANAGER, msg.sender)) revert NotAuthorized();

        _requireAssetExists(underlyingAsset);

        _removeBalanceOracle(underlyingAsset, oracle);
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
        return _assetDecimals.length();
    }

    /// @inheritdoc INAVCalculator
    function read(address account) external view returns (INAVCalculator.NAV memory nav) {
        nav.block = uint64(block.number);
        nav.timestamp = uint64(block.timestamp);

        uint256 length = _assetDecimals.length();

        if (length != 0) {
            // read all of the account's positions
            // NOTE: this can exceed gas limit
            (nav.usd, nav.stalePriceAssets, nav.sequencerDown) = readPositionsRange(account, 0, length - 1);
        } else {
            // Initialize empty arrays when no assets
            nav.stalePriceAssets = new address[](0);
            nav.sequencerDown = false;
        }
    }

    /// @inheritdoc INAVCalculator
    function readPositionsRange(address account, uint256 from, uint256 to)
        public
        view
        returns (int256 usd, address[] memory stalePriceAssets, bool sequencerDown)
    {
        if (from > to || to >= _assetDecimals.length()) {
            revert InvalidArguments();
        }

        // Check sequencer status once (global issue, affects all assets)
        sequencerDown = _isSequencerDown();

        // Allocate array the size of the range (max possible stale assets)
        uint256 rangeSize = to - from + 1;
        address[] memory staleAssetsTemp = new address[](rangeSize);
        uint256 staleCount = 0;

        // Single pass: collect stale assets and calculate USD
        for (uint256 i = from; i <= to; i++) {
            (address assetAddr,) = _assetDecimals.at(i);

            _requirePriceOracleExists(assetAddr);

            // fetches the current price for this asset
            (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(assetAddr);

            if (stale) {
                staleAssetsTemp[staleCount] = assetAddr;
                staleCount++;
            }

            // for each asset, iterate over its known balance oracles
            uint256 balanceOracleCount = balanceOracleCountFor(assetAddr);
            for (uint256 balanceIdx = 0; balanceIdx < balanceOracleCount; ++balanceIdx) {
                usd += _calculatePositionUsdValue(account, assetAddr, balanceIdx, usdRate, usdRateDecimals);
            }
        }

        // Create final array of exact size (optimize when empty)
        if (staleCount == 0) {
            stalePriceAssets = new address[](0);
        } else {
            stalePriceAssets = new address[](staleCount);
            for (uint256 i = 0; i < staleCount; i++) {
                stalePriceAssets[i] = staleAssetsTemp[i];
            }
        }
    }

    /// @inheritdoc INAVCalculator
    function readPosition(address account, address underlyingAsset, uint256 idxBalanceOracle)
        external
        view
        returns (INAVCalculator.Position memory p)
    {
        _requireAssetExists(underlyingAsset);
        _requirePriceOracleExists(underlyingAsset);

        (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(underlyingAsset);

        // Check sequencer status once
        bool sequencerDown = _isSequencerDown();

        // Get decimals once (asset already validated above)
        uint8 decimals = _getAssetDecimals(underlyingAsset);

        return _readPositionWithPrice(
            account, underlyingAsset, idxBalanceOracle, usdRate, usdRateDecimals, stale, sequencerDown, decimals
        );
    }

    /// @inheritdoc INAVCalculator
    function readPositionWithMetadata(address account, address underlyingAsset, uint256 idx)
        external
        view
        returns (INAVCalculator.PositionWithMetadata memory p)
    {
        uint8 decimals = _getAssetDecimals(underlyingAsset);

        BalanceOracleWithMetadata memory oracleWithMetadata = _balanceOracleWithMetadata(underlyingAsset, idx);

        (uint256 usdRate, uint256 usdRateDecimals, bool stale) = _latestPrice(underlyingAsset);

        // Check sequencer status once
        bool sequencerDown = _isSequencerDown();

        string memory symbol;
        if (underlyingAsset == NATIVE_ADDRESS) {
            symbol = _nativeTokenSymbol;
        } else {
            try IERC20Metadata(underlyingAsset).symbol() returns (string memory symbol_) {
                symbol = symbol_;
            } catch {
                symbol = "";
            }
        }

        p.protocol = oracleWithMetadata.protocol;
        p.position = oracleWithMetadata.position;
        p.positionType = oracleWithMetadata.positionType;
        p.underlyingAsset = underlyingAsset;
        p.underlyingAssetSymbol = symbol;
        p.underlyingAssetDecimals = decimals;
        p.usdRate = usdRate;
        p.usdRateDecimals = usdRateDecimals;
        p.stale = stale;
        p.balance = balanceOf(underlyingAsset, idx, account);
        p.usd = _toUsd(p.balance, decimals, usdRate, usdRateDecimals);
        p.sequencerDown = sequencerDown;

        return p;
    }

    /// @inheritdoc INAVCalculator
    function usdDecimals() external pure returns (uint8) {
        return NAV_DECIMALS;
    }

    /// @inheritdoc INAVCalculator
    function assetAt(uint256 idx) external view returns (INAVCalculator.Asset memory a) {
        (address asset, uint256 decimals) = _assetDecimals.at(idx);
        a.addr = asset;
        a.decimals = uint8(decimals);
    }

    /// @inheritdoc INAVCalculator
    function assets() external view returns (address[] memory) {
        return _assetDecimals.keys();
    }

    /// @inheritdoc INAVCalculator
    function getPriceData(address underlyingAsset) external view returns (INAVCalculator.PriceData memory priceData) {
        _requireAssetExists(underlyingAsset);

        PriceOracle storage oracle = priceOracles[underlyingAsset];
        _requirePriceOracleExists(underlyingAsset);

        (uint256 price, uint8 decimals, bool stale) = _latestPrice(underlyingAsset);

        priceData.oracle = oracle.oracle;
        priceData.priceType = oracle.priceType;
        priceData.price = price;
        priceData.decimals = decimals;
        priceData.chainlinkHeartbeat = oracle.chainlinkHeartbeat;
        priceData.stale = stale;

        // Get Chainlink-specific data
        if (oracle.priceType == IPrices.PriceType.Chainlink) {
            AggregatorV3Interface chainlinkOracle = AggregatorV3Interface(oracle.oracle);
            (,,, uint256 roundUpdatedAt,) = chainlinkOracle.latestRoundData();
            priceData.updatedAt = roundUpdatedAt;
        }

        // Check L2 sequencer uptime (conditional on L2)
        priceData.sequencerDown = _isSequencerDown();
    }

    /// @inheritdoc INAVCalculator
    function readAccountPositions(address account)
        external
        view
        returns (address[] memory assetAddresses, int256[] memory assetBalances, int256[] memory assetUsdValues)
    {
        uint256 totalAssets = _assetDecimals.length();

        // Early return empty arrays if no assets configured
        if (totalAssets == 0) {
            return (new address[](0), new int256[](0), new int256[](0));
        }

        // Temporary arrays sized to max possible entries, we will compact later
        address[] memory tempAssets = new address[](totalAssets);
        int256[] memory tempBalances = new int256[](totalAssets);
        int256[] memory tempUsdValues = new int256[](totalAssets);

        uint256 count = 0;

        for (uint256 i = 0; i < totalAssets; i++) {
            (address assetAddr, uint256 dec) = _assetDecimals.at(i);

            _requirePriceOracleExists(assetAddr);

            // Fetch price once per asset
            (uint256 usdRate, uint256 usdRateDecimals,) = _latestPrice(assetAddr);

            uint8 decimals = uint8(dec);

            // Sum all balances for this asset across its balance oracles
            uint256 balanceOracleCount = balanceOracleCountFor(assetAddr);
            int256 aggBalance = 0;
            for (uint256 balanceIdx = 0; balanceIdx < balanceOracleCount; ++balanceIdx) {
                aggBalance += balanceOf(assetAddr, balanceIdx, account);
            }

            // Only include non‑zero aggregated balances
            if (aggBalance != 0) {
                tempAssets[count] = assetAddr;
                tempBalances[count] = aggBalance;
                tempUsdValues[count] = _toUsd(aggBalance, decimals, usdRate, usdRateDecimals);
                count++;
            }
        }

        // Compact to exact size
        assetAddresses = new address[](count);
        assetBalances = new int256[](count);
        assetUsdValues = new int256[](count);
        for (uint256 j = 0; j < count; j++) {
            assetAddresses[j] = tempAssets[j];
            assetBalances[j] = tempBalances[j];
            assetUsdValues[j] = tempUsdValues[j];
        }
    }

    /// @inheritdoc INAVCalculator
    function healthCheck() external view returns (bool sequencerDown, address[] memory stalePriceAssets) {
        uint256 totalAssets = _assetDecimals.length();

        // Check sequencer status once
        sequencerDown = _isSequencerDown();

        if (totalAssets == 0) {
            stalePriceAssets = new address[](0);
            return (sequencerDown, stalePriceAssets);
        }

        address[] memory staleAssetsTemp = new address[](totalAssets);
        uint256 staleCount = 0;

        for (uint256 i = 0; i < totalAssets; i++) {
            (address assetAddr,) = _assetDecimals.at(i);

            _requirePriceOracleExists(assetAddr);

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
        uint256 totalAssets = _assetDecimals.length();
        if (totalAssets == 0) return false;

        for (uint256 i = 0; i < totalAssets; i++) {
            (address assetAddr,) = _assetDecimals.at(i);
            uint256 countOracles = balanceOracleCountFor(assetAddr);
            for (uint256 j = 0; j < countOracles; j++) {
                if (balanceOf(assetAddr, j, account) != 0) {
                    return true;
                }
            }
        }

        return false;
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
        if (!_assetDecimals.contains(underlyingAsset)) {
            revert AssetNotFound();
        }
    }

    /// @notice Validates that a price oracle exists for an asset, reverts if not
    /// @param underlyingAsset The asset to validate
    function _requirePriceOracleExists(address underlyingAsset) internal view {
        if (priceOracles[underlyingAsset].oracle == address(0)) {
            revert PriceOracleNotSet();
        }
    }

    /// @notice Gets asset decimals, reverts if asset doesn't exist
    /// @param underlyingAsset The asset address
    /// @return decimals The number of decimals for the asset
    function _getAssetDecimals(address underlyingAsset) internal view returns (uint8) {
        (bool contains, uint256 decimals) = _assetDecimals.tryGet(underlyingAsset);
        if (!contains) {
            revert AssetNotFound();
        }
        return uint8(decimals);
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

    /// @notice Computes the full position data, along with the USD value based on the already-provided exchange rate
    /// info
    /// @param account The address of the account
    /// @param underlyingAsset The address of the asset
    /// @param idxBalanceOracle The index of the balance oracle
    /// @param usdRate The USD rate of the asset
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @param stale If the price is stale (asset-specific)
    /// @param sequencerDown Whether the L2 sequencer is down (passed to avoid multiple checks)
    /// @param decimals The number of decimals of the asset (passed to avoid redundant lookup)
    /// @return p The computed position
    function _readPositionWithPrice(
        address account,
        address underlyingAsset,
        uint256 idxBalanceOracle,
        uint256 usdRate,
        uint256 usdRateDecimals,
        bool stale,
        bool sequencerDown,
        uint8 decimals
    ) internal view returns (INAVCalculator.Position memory p) {
        p.underlyingAsset = underlyingAsset;
        p.balance = balanceOf(underlyingAsset, idxBalanceOracle, account);
        p.stale = stale;
        p.usdRate = usdRate;
        p.usdRateDecimals = usdRateDecimals;
        p.sequencerDown = sequencerDown;
        p.usd = _toUsd(p.balance, decimals, usdRate, usdRateDecimals);
    }

    /// @notice Calculates the USD value of a given position
    /// @param account The address of the account
    /// @param underlyingAsset The address of the asset
    /// @param idxBalanceOracle The index of the balance oracle
    /// @param usdRate The USD rate of the asset
    /// @param usdRateDecimals The number of decimals of the USD rate
    /// @return usd The computed USD value of the position
    function _calculatePositionUsdValue(
        address account,
        address underlyingAsset,
        uint256 idxBalanceOracle,
        uint256 usdRate,
        uint256 usdRateDecimals
    ) internal view returns (int256 usd) {
        uint8 decimals = _getAssetDecimals(underlyingAsset);
        int256 balance = balanceOf(underlyingAsset, idxBalanceOracle, account);
        return _toUsd(balance, decimals, usdRate, usdRateDecimals);
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
            revert InvalidArguments();
        }

        uint256 denominator = decimals + usdRateDecimals - NAV_DECIMALS;
        // Prevent exponent that's too large (max uint8 is 255, but we use uint256 for safety)
        // This is extremely unlikely in practice but prevents potential issues
        if (denominator > 255) {
            revert InvalidArguments();
        }

        usd = (balance * int256(usdRate)) / int256(10 ** denominator);
    }
}
