// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IBalances} from "src/balances/IBalances.sol";
import {IPrices} from "src/prices/Prices.sol";

/// @title INAVCalculator Interface
/// @notice Interface for NAVCalculator contract
/// @author kpk
interface INAVCalculator is IBalances {
    /// @notice Registered asset metadata (address, symbol, decimals) — used by NAV/Pricing and balance oracles
    struct Asset {
        address asset;
        string symbol;
        uint8 decimals;
    }

    /// @notice Balance-only position data returned by balance oracles
    /// @dev Balance oracles return this struct without pricing information
    /// @dev NAVCalculator enriches these with pricing to create Position structs
    struct PositionBalance {
        Asset underlyingAsset;
        address balanceOracle;
        uint256 amount; // Always positive, use isDebt to indicate debt vs credit
        bool isDebt; // true = debt (subtract from NAV), false = credit (add to NAV)
        string protocol;
        string positionDetail;
    }

    /// @notice Complete position with pricing information
    /// @dev This is the enriched version returned by NAVCalculator public methods
    /// @dev Contains all PositionBalance fields plus pricing data (quoteAsset, value, price, priceDecimals, stale)
    struct Position {
        Asset underlyingAsset;
        address balanceOracle;
        uint256 amount; // Always positive, use isDebt to indicate debt vs credit
        bool isDebt; // true = debt (subtract from NAV), false = credit (add to NAV)
        Asset quoteAsset;
        int256 value; // Can be negative for debt positions (calculated from amount, isDebt, and price)
        int256 price;
        uint8 priceDecimals;
        bool stale;
        string protocol;
        string positionDetail;
    }

    /// @notice The complete NAV snapshot
    /// @param value Total value in quoteAsset
    /// @param quoteAsset The quote currency (address(0) denotes USD; otherwise must have a price feed when used in getters)
    /// @param timestamp Block timestamp this reading refers to
    /// @param stalePriceAssets Array of assets with stale prices
    /// @param sequencerDown Whether the L2 sequencer is down
    // forge-lint: disable-next-line(pascal-case-struct)
    struct NAV {
        int256 value;
        Asset quoteAsset;
        uint64 timestamp;
        Asset[] stalePriceAssets;
        bool sequencerDown;
    }

    /// @notice Comprehensive price feed query result for a token
    /// @param priceFeed The address of the price feed
    /// @param priceType The type of price feed (Chainlink or Custom)
    /// @param price The current price
    /// @param decimals The decimals used by the price feed
    /// @param chainlinkHeartbeat The heartbeat interval (Chainlink only)
    /// @param updatedAt The timestamp when price was last updated (Chainlink only, 0 for custom)
    /// @param stale Whether the price is stale (asset-specific, e.g., heartbeat timeout)
    /// @param sequencerDown Whether L2 sequencer is down (L2 only, false on L1)
    struct PriceFeedData {
        address priceFeed;
        IPrices.PriceType priceType;
        int256 price;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        uint256 updatedAt; // For Chainlink: timestamp from latestRoundData, for Custom: 0
        bool stale;
        bool sequencerDown;
    }

    //
    // Events
    //

    /// @notice Event emitted when the Chainlink L2 sequencer uptime feed is updated by a call to `setChainlinkL2SequencerUptimeFeed`
    /// @param oldChainlinkUptimeFeed The address of the old Chainlink uptime feed
    /// @param newChainlinkUptimeFeed The address of the new Chainlink uptime feed
    event ChainlinkUptimeFeedUpdated(address indexed oldChainlinkUptimeFeed, address indexed newChainlinkUptimeFeed);

    /// @notice Event emitted when the L2 sequencer grace period is updated by a call to `setChainlinkL2SequencerGracePeriod`
    /// @param oldSequencerGracePeriod The old sequencer grace period in seconds
    /// @param newSequencerGracePeriod The new sequencer grace period in seconds
    event L2SequencerGracePeriodUpdated(uint256 oldSequencerGracePeriod, uint256 newSequencerGracePeriod);

    /// @notice Event emitted when an asset is registered in the calculator
    /// @param asset The address of the asset
    /// @param decimals The number of decimals the asset uses
    event AssetRegistered(address indexed asset, uint8 decimals);

    /// @notice Event emitted when an asset is unregistered from the calculator
    /// @param asset The address of the asset
    event AssetUnregistered(address indexed asset);

    //
    // Errors
    //

    /// @notice Reverted when an asset is not registered (see errors.sol AssetNotFound).
    /// @dev Used by view and mutating functions that look up an asset by address.

    /// @notice Reverted when setChainlinkL2SequencerGracePeriod is called and the L2 sequencer uptime feed is the zero address.
    error UptimeFeedNotSet();

    /// @notice Registers an asset with its price feed.
    /// @dev The asset must be registered with a price feed. Cannot register an asset without a price feed.
    /// @param asset The address of the asset to register
    /// @param priceFeed The address of the price feed
    /// @param priceType The type of the price feed
    /// @param chainlinkHeartbeat The heartbeat interval for Chainlink price feeds (ignored for custom price feeds)
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Sets the price feed for an existing asset.
    /// @dev Cannot be called before registering the asset. Replaces any existing price feed.
    function setPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Adds a balance oracle to the global registry.
    /// @dev Reverts with DuplicateBalanceOracle if the oracle is already registered. The oracle will be queried for all accounts when computing NAV.
    function addBalanceOracle(address oracle) external;

    /// @notice Unsets the price feed for a given asset.
    /// @dev The asset remains registered after this operation.
    function unsetPriceFeed(address underlyingAsset) external;

    /// @notice Removes a balance oracle from the global registry.
    /// @dev The oracle will no longer be queried when computing NAV.
    function removeBalanceOracle(address oracle) external;

    /// @notice Removes an asset from the default oracle's inclusion list so it is no longer reported as wallet balance (e.g. to avoid double accounting with a custom oracle).
    /// @param asset The asset address to exclude from the default oracle
    function excludeAssetFromDefaultOracle(address asset) external;

    /// @notice Adds an asset back to the default oracle's inclusion list so wallet balances are reported again.
    /// @param asset The asset address (must be registered)
    function includeAssetInDefaultOracle(address asset) external;

    /// @notice Unregisters an asset from the registry.
    /// @param underlyingAsset The address of the asset to unregister.
    /// @dev Unsets the price feed for the asset (if set) and removes the asset from the asset registry. Balance oracles are global and are not removed.
    function unregisterAsset(address underlyingAsset) external;

    /// @notice Update the Chainlink L2 sequencer uptime feed address
    /// @param newChainlinkL2UptimeFeed The new Chainlink L2 sequencer uptime feed address
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2UptimeFeed) external;

    /// @notice Sets the Chainlink L2 sequencer grace period
    /// @param newSequencerGracePeriod The new Chainlink L2 sequencer grace period in seconds
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external;

    /// @notice Counts the number of assets known by this calculator.
    /// @return the number of assets known by this calculator.
    function assetCount() external view returns (uint256);

    /// @notice Checks if an asset is registered (required for NAV/Pricing and balance oracles).
    function isAssetRegistered(address asset) external view returns (bool);

    /// @notice Returns all registered assets with their metadata (address, symbol, decimals).
    function getRegisteredAssets() external view returns (Asset[] memory assets);

    /// @notice Returns the total number of registered assets.
    function getAssetCount() external view returns (uint256);

    /// @notice Returns the decimals for a registered asset.
    function getAssetDecimals(address asset) external view returns (uint8);

    /// @notice Returns the symbol for a registered asset.
    function getAssetSymbol(address asset) external view returns (string memory);

    /// @notice Returns the current initialization version as tracked by OpenZeppelin's Initializable storage
    function version() external view returns (uint64);

    /// @notice Gets NAV for an account in the specified quoteAsset (quote currency)
    /// @param account The address of the account to calculate for
    /// @param quoteAsset The quote currency address (address(0) for USD). When not address(0), must have a price feed configured.
    /// @return nav The NAV of the account in the specified quote currency
    function getAccountNav(address account, address quoteAsset) external view returns (NAV memory nav);

    /// @notice Gets NAV for a range of assets (chunked query)
    /// @param account The address of the account to calculate for
    /// @param from Starting asset index (inclusive, from asset enumeration)
    /// @param to Ending asset index (inclusive, from asset enumeration)
    /// @param quoteAsset The quote currency address (address(0) for USD). When not address(0), must have a price feed configured.
    /// @dev Validates that from <= to and both indices are within asset count bounds
    /// @dev Reverts with InvalidArguments if indices are out of range or from > to
    /// @return nav The NAV of the account for the specified asset range in the quote currency
    function getAccountNavForRange(address account, uint256 from, uint256 to, address quoteAsset)
        external
        view
        returns (NAV memory nav);

    /// @notice Gets all positions for a given account with pricing in the specified quote currency
    /// @param account The address of the account to calculate for
    /// @param quoteAsset The quote currency address (address(0) for USD). When not address(0), must have a price feed configured.
    /// @return positions Array of enriched Position structs with pricing information
    /// @dev This method aggregates balance-only PositionBalance data from oracles and enriches them with pricing
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Gets positions for a specific asset for a given account
    /// @param account The address of the account to calculate for
    /// @param asset The specific asset to filter by (must be registered)
    /// @param quoteAsset The quote currency address (address(0) for USD). When not address(0), must have a price feed configured.
    /// @return positions Array of enriched Position structs with pricing information for the specified asset
    /// @dev This method aggregates balance-only PositionBalance data from oracles and enriches them with pricing
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice The amount of decimals returned with each USD value
    /// @return The amount of decimals
    function usdDecimals() external view returns (uint8);

    /// @notice Returns comprehensive price feed query result for a given token
    /// @param underlyingAsset The address of the token
    /// @return priceFeedData The complete price information including price feed details, price, staleness, and sequencer status
    function getPriceData(address underlyingAsset) external view returns (PriceFeedData memory priceFeedData);

    /// @notice Returns overall health status
    /// @return sequencerDown Whether the L2 sequencer is down (false on L1)
    /// @return stalePriceAssets Array of assets with stale prices
    function healthCheck() external view returns (bool sequencerDown, address[] memory stalePriceAssets);

    /// @notice Returns true if the account has any non‑zero aggregated balance across all assets/oracles
    /// @param account The address to check
    /// @return has Any position present
    function hasPositions(address account) external view returns (bool has);

    /// @notice Returns all assets that have non-zero balances for the given account
    /// @param account The address of the account to check
    /// @return assets Array of asset addresses that have at least one non-zero balance
    /// @dev This is a gas-efficient way to identify which assets need processing
    function getAssetsWithPositions(address account) external view returns (address[] memory assets);

    /// @notice Converts one or more positive balances into a total value in the quote currency
    /// @param assets Array of asset addresses
    /// @param amounts Array of amounts (positive balances only; zero amounts are skipped)
    /// @param quoteAsset Quote currency address (address(0) for USD)
    /// @return value Total value of the balances in the quote asset (always non-negative for valid inputs)
    /// @dev Uses the same pricing and decimals as the rest of the NAV calculator. Only positive
    ///      balances are supported; no debt/negative positions. Each asset must be registered with a price feed.
    function calculateValue(address[] memory assets, uint256[] memory amounts, address quoteAsset)
        external
        view
        returns (int256 value);
}
