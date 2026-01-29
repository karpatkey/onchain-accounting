// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalances} from "src/balances/IBalances.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title INAVCalculator
/// @notice Interface for the NAV Calculator contract. Defines the full API for asset registration, price feeds,
///         balance oracles, and NAV/position queries in one or more quote currencies.
/// @dev Extends IBalances for oracle registry and IPrices for price feed types. Implementations are typically
///      UUPS-upgradeable and use AccessControl (MANAGER for mutations, DEFAULT_ADMIN_ROLE for upgrades).
/// @author kpk
interface INAVCalculator is IBalances {
    //
    // Structs
    //

    /// @notice Registered asset metadata used by the NAV/Pricing registry and balance oracles.
    /// @param asset Token address (or NATIVE_ADDRESS for chain native token).
    /// @param symbol Display symbol (e.g. "ETH", "USDC").
    /// @param decimals Number of decimals for amounts.
    struct Asset {
        address asset;
        string symbol;
        uint8 decimals;
    }

    /// @notice Balance-only position data returned by balance oracles (no pricing).
    /// @dev NAVCalculator enriches these with pricing to produce Position structs.
    /// @param underlyingAsset Asset metadata (address, symbol, decimals).
    /// @param balanceOracle Address of the oracle that reported this position.
    /// @param amount Balance magnitude (always positive); sign is implied by isDebt.
    /// @param isDebt True if debt (subtract from NAV), false if credit (add to NAV).
    /// @param protocol Protocol or source identifier (e.g. "aave", "wallet").
    /// @param positionDetail Optional detail string (e.g. pool id, market).
    struct PositionBalance {
        Asset underlyingAsset;
        address balanceOracle;
        uint256 amount;
        bool isDebt;
        string protocol;
        string positionDetail;
    }

    /// @notice Enriched position including pricing and quote-currency value.
    /// @dev Returned by getAccountPositions and getAccountPositionsForAsset.
    /// @param underlyingAsset Asset metadata from registry (canonical symbol/decimals).
    /// @param balanceOracle Oracle that reported the balance.
    /// @param amount Balance magnitude (positive); sign implied by isDebt.
    /// @param isDebt True if debt, false if credit.
    /// @param quoteAsset Quote currency for value (e.g. USD when address(0)).
    /// @param value Value in quote asset (negative for debt).
    /// @param price Price used (e.g. USD per unit of asset).
    /// @param priceDecimals Decimals of price.
    /// @param stale True if the price was stale at query time.
    /// @param protocol Protocol/source identifier.
    /// @param positionDetail Optional detail.
    struct Position {
        Asset underlyingAsset;
        address balanceOracle;
        uint256 amount;
        bool isDebt;
        Asset quoteAsset;
        int256 value;
        int256 price;
        uint8 priceDecimals;
        bool stale;
        string protocol;
        string positionDetail;
    }

    /// @notice NAV snapshot for an account in a given quote currency.
    /// @param value Total portfolio value in quoteAsset (can be negative if net debt).
    /// @param quoteAsset Quote currency; address(0) denotes USD.
    /// @param timestamp Block timestamp of the reading.
    /// @param stalePriceAssets Assets whose prices were stale at query time.
    /// @param sequencerDown True if the L2 sequencer was down or in grace period (L2 only).
    // forge-lint: disable-next-line(pascal-case-struct)
    struct NAV {
        int256 value;
        Asset quoteAsset;
        uint64 timestamp;
        Asset[] stalePriceAssets;
        bool sequencerDown;
    }

    /// @notice Detailed price feed data for a single asset.
    /// @param priceFeed Address of the price feed contract.
    /// @param priceType Chainlink or Custom.
    /// @param price Current price (e.g. USD per unit).
    /// @param decimals Decimals of the price.
    /// @param chainlinkHeartbeat Heartbeat for staleness (Chainlink only).
    /// @param updatedAt Last update timestamp (Chainlink: from latestRoundData; Custom: 0).
    /// @param stale True if price is stale (heartbeat or custom logic).
    /// @param sequencerDown True if L2 sequencer is down (L2 only).
    struct PriceFeedData {
        address priceFeed;
        IPrices.PriceType priceType;
        int256 price;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        uint256 updatedAt;
        bool stale;
        bool sequencerDown;
    }

    //
    // Events
    //

    /// @notice Emitted when the Chainlink L2 sequencer uptime feed is updated.
    /// @param oldChainlinkUptimeFeed Previous uptime feed address.
    /// @param newChainlinkUptimeFeed New uptime feed address.
    event ChainlinkUptimeFeedUpdated(address indexed oldChainlinkUptimeFeed, address indexed newChainlinkUptimeFeed);

    /// @notice Emitted when the L2 sequencer grace period is updated.
    /// @param oldSequencerGracePeriod Previous grace period in seconds.
    /// @param newSequencerGracePeriod New grace period in seconds.
    event L2SequencerGracePeriodUpdated(uint256 oldSequencerGracePeriod, uint256 newSequencerGracePeriod);

    /// @notice Emitted when an asset is registered.
    /// @param asset Registered asset address.
    /// @param decimals Asset decimals.
    event AssetRegistered(address indexed asset, uint8 decimals);

    /// @notice Emitted when an asset is unregistered.
    /// @param asset Unregistered asset address.
    event AssetUnregistered(address indexed asset);

    //
    // Errors
    //

    /// @notice Thrown when the L2 sequencer uptime feed is not set but the grace period is being updated.
    error UptimeFeedNotSet();

    //
    // Mutating functions (require MANAGER role)
    //

    /// @notice Registers an asset and sets its price feed.
    /// @dev Fetches decimals/symbol from ERC20 or uses native token symbol. Adds asset to default oracle inclusion list.
    /// @param asset Asset address to register (cannot be zero).
    /// @param priceFeed Price feed address (cannot be zero).
    /// @param priceType Chainlink or Custom.
    /// @param chainlinkHeartbeat Heartbeat for Chainlink staleness (ignored for Custom).
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Sets or replaces the price feed for an already registered asset.
    /// @param asset Registered asset address.
    /// @param priceFeed New price feed address (cannot be zero).
    /// @param priceType Chainlink or Custom.
    /// @param chainlinkHeartbeat Heartbeat for Chainlink (ignored for Custom).
    function setPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Registers a balance oracle in the global registry.
    /// @dev Reverts with DuplicateBalanceOracle if already registered.
    /// @param oracle Oracle address (must implement IBalanceOracleAdapter).
    function addBalanceOracle(address oracle) external;

    /// @notice Removes the price feed for an asset; asset remains registered.
    /// @param underlyingAsset Registered asset address.
    function unsetPriceFeed(address underlyingAsset) external;

    /// @notice Removes a balance oracle from the global registry.
    /// @param oracle Oracle address to remove (cannot be the default ERC20 oracle).
    function removeBalanceOracle(address oracle) external;

    /// @notice Excludes an asset from the default oracle so wallet balances are not reported for it.
    /// @param asset Registered asset address.
    function excludeAssetFromDefaultOracle(address asset) external;

    /// @notice Includes an asset in the default oracle so wallet balances are reported again.
    /// @param asset Registered asset address.
    function includeAssetInDefaultOracle(address asset) external;

    /// @notice Unregisters an asset: unsets price feed, removes from default oracle list, and removes from registry.
    /// @param underlyingAsset Asset address to unregister.
    function unregisterAsset(address underlyingAsset) external;

    /// @notice Sets the Chainlink L2 sequencer uptime feed (use address(0) on L1).
    /// @param newChainlinkL2UptimeFeed New uptime feed address.
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2UptimeFeed) external;

    /// @notice Sets the L2 sequencer grace period (reverts if uptime feed not set).
    /// @param newSequencerGracePeriod Grace period in seconds.
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external;

    //
    // View functions — registry
    //

    /// @notice Returns the number of registered assets (alias for getAssetCount).
    /// @return Number of registered assets.
    function assetCount() external view returns (uint256);

    /// @notice Returns whether an asset is registered.
    /// @param asset Asset address to check.
    /// @return True if registered.
    function isAssetRegistered(address asset) external view returns (bool);

    /// @notice Returns all registered assets with metadata.
    /// @return assets Array of Asset (address, symbol, decimals).
    function getRegisteredAssets() external view returns (Asset[] memory assets);

    /// @notice Returns the number of registered assets.
    /// @return Number of registered assets.
    function getAssetCount() external view returns (uint256);

    /// @notice Returns the current implementation version (Initializable storage).
    /// @return Version number.
    function version() external view returns (uint64);

    //
    // View functions — NAV and positions
    //

    /// @notice Computes NAV for an account in the given quote currency.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD. Must have a price feed if not zero.
    /// @return nav NAV struct (value, quoteAsset, timestamp, stalePriceAssets, sequencerDown).
    function getAccountNav(address account, address quoteAsset) external view returns (NAV memory nav);

    /// @notice Returns all positions for an account with pricing in the quote currency.
    /// @param account Account address.
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return positions Array of enriched Position structs.
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Returns positions for an account filtered by a single asset.
    /// @param account Account address.
    /// @param asset Asset to filter by (must be registered).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return positions Array of enriched Position structs for the asset.
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Returns the number of decimals used for USD values (e.g. 8).
    /// @return USD decimals.
    function usdDecimals() external view returns (uint8);

    /// @notice Returns detailed price feed data for an asset.
    /// @param underlyingAsset Registered asset address.
    /// @return priceFeedData PriceFeedData struct (feed, type, price, decimals, heartbeat, updatedAt, stale, sequencerDown).
    function getPriceData(address underlyingAsset) external view returns (PriceFeedData memory priceFeedData);

    /// @notice Returns health status: sequencer down flag and list of assets with stale prices.
    /// @return sequencerDown True if L2 sequencer is down or in grace period (false on L1).
    /// @return stalePriceAssets Addresses of assets with stale prices.
    function healthCheck() external view returns (bool sequencerDown, address[] memory stalePriceAssets);

    /// @notice Returns whether the account has any non-zero balance across oracles and registered assets.
    /// @param account Account address.
    /// @return has True if at least one position has non-zero amount.
    function hasPositions(address account) external view returns (bool has);

    /// @notice Returns the list of assets for which the account has at least one non-zero position.
    /// @param account Account address.
    /// @return assets Array of asset addresses.
    function getAssetsWithPositions(address account) external view returns (address[] memory assets);

    /// @notice Converts a list of (asset, amount) pairs into a total value in the quote currency.
    /// @dev Only positive amounts; zero amounts are skipped. All assets must be registered with a price feed.
    /// @param assets Asset addresses.
    /// @param amounts Corresponding amounts (same length as assets).
    /// @param quoteAsset Quote currency; address(0) for USD.
    /// @return value Sum of values in quote asset (non-negative for valid inputs).
    function calculateValue(address[] memory assets, uint256[] memory amounts, address quoteAsset)
        external
        view
        returns (int256 value);
}
