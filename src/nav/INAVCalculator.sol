// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IPrices} from "src/prices/Prices.sol";
import {IBalances} from "src/balances/IBalances.sol";

/// @title INAVCalculator Interface
/// @notice Interface for NAVCalculator contract
/// @author kpk
interface INAVCalculator {
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
        uint256 price;
        uint8 priceDecimals;
        bool stale;
        string protocol;
        string positionDetail;
    }

    /// @notice Health check information for NAV calculations
    /// @param stalePriceAssets Array of assets with stale prices
    /// @param sequencerDown Whether the L2 sequencer is down
    struct HealthCheck {
        Asset[] stalePriceAssets;
        bool sequencerDown;
    }

    /// @notice The complete NAV snapshot
    /// @param value Total value in quoteAsset
    /// @param quoteAsset The quote currency (must have PriceFeedConfig configured)
    /// @param timestamp Block timestamp this reading refers to
    /// @param issues Health check information
    // forge-lint: disable-next-line(pascal-case-struct)
    struct NAV {
        int256 value;
        Asset quoteAsset;
        uint64 timestamp;
        HealthCheck issues;
    }

    struct Asset {
        address asset;
        string symbol;
        uint8 decimals;
    }

    /// @notice Comprehensive price feed query result for a token
    /// @param oracle The address of the price oracle
    /// @param priceType The type of oracle (Chainlink or Custom)
    /// @param price The current price
    /// @param decimals The decimals used by the oracle
    /// @param chainlinkHeartbeat The heartbeat interval (Chainlink only)
    /// @param updatedAt The timestamp when price was last updated (Chainlink only, 0 for custom)
    /// @param stale Whether the price is stale (asset-specific, e.g., heartbeat timeout)
    /// @param sequencerDown Whether L2 sequencer is down (L2 only, false on L1)
    struct PriceFeed {
        address oracle;
        IPrices.PriceType priceType;
        uint256 price;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        uint256 updatedAt; // For Chainlink: timestamp from latestRoundData, for Custom: 0
        bool stale;
        bool sequencerDown;
    }

    //
    // Events
    //

    /// @notice Event emitted when the string for the native token symbol is set
    /// @param nativeTokenSymbol The symbol of the chain's native token
    event NativeTokenSymbolSet(string indexed nativeTokenSymbol);

    /// @notice Event emitted when the Chainlink uptime feed is updated by a call to `setChainlinkUptimeFeed`
    /// @param oldChainlinkUptimeFeed The address of the old Chainlink uptime feed
    /// @param newChainlinkUptimeFeed The address of the new Chainlink uptime feed
    event ChainlinkUptimeFeedUpdated(address indexed oldChainlinkUptimeFeed, address indexed newChainlinkUptimeFeed);

    /// @notice Event emitted when the L2 sequencer grace period is updated by a call to `setSequencerGracePeriod`
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

    /// @notice Emitted when an asset is not found

    /// @notice Emitted when 'setSequencerGracePeriod' is called and 'chainlinkUptimeFeed' is the zero address
    error UptimeFeedNotSet();

    /// @notice Registers an asset with its price feed.
    /// @dev The asset must be registered with a price feed. Cannot register an asset without a price feed.
    /// @param asset The address of the asset to register
    /// @param oracle The address of the price oracle
    /// @param priceType The type of the price oracle
    /// @param chainlinkHeartbeat The heartbeat interval for Chainlink oracles (ignored for custom oracles)
    function registerAsset(address asset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Sets the price feed for an existing asset.
    /// @dev Cannot be called before registering the asset. Replaces any existing price oracle.
    function setPriceFeed(address asset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Adds a balance oracle globally.
    /// @dev The oracle will return positions for all registered assets. Replaces any existing oracle with the same address.
    function addBalanceOracle(address oracle) external;

    /// @notice Unsets the price feed for a given asset.
    /// @dev The asset remains registered after this operation.
    function unsetPriceFeed(address underlyingAsset) external;

    /// @notice Removes a balance oracle from the global registry.
    /// @dev The oracle is removed globally and will no longer return positions for any asset.
    function removeBalanceOracle(address oracle) external;

    /// @notice Unregisters an asset, removing all oracles and the asset itself.
    /// @param underlyingAsset The address of the asset to unregister.
    /// @dev This is a shortcut that unsets price and balance oracles, then removes the asset.
    function unregisterAsset(address underlyingAsset) external;

    /// @notice Sets the symbol of the native token used for display purposes (e.g. "xDAI")
    /// @dev This function can only be called by the manager role
    /// @param nativeTokenSymbol The symbol of the native token
    function setNativeTokenSymbol(string memory nativeTokenSymbol) external;

    /// @notice Update the Chainlink L2 sequencer uptime feed address
    /// @param newChainlinkL2UptimeFeed The new Chainlink L2 sequencer uptime feed address
    function setChainlinkL2SequencerUptimeFeed(address newChainlinkL2UptimeFeed) external;

    /// @notice Sets the Chainlink L2 sequencer grace period
    /// @param newSequencerGracePeriod The new Chainlink L2 sequencer grace period in seconds
    function setChainlinkL2SequencerGracePeriod(uint256 newSequencerGracePeriod) external;

    /// @notice Counts the number of assets known by this calculator.
    /// @return the number of assets known by this calculator.
    function assetCount() external view returns (uint256);

    /// @notice Returns the current initialization version as tracked by OpenZeppelin's Initializable storage
    function version() external view returns (uint64);

    /// @notice Gets NAV for an account in the specified baseAsset (quote currency)
    /// @param account The address of the account to calculate for
    /// @param baseAsset The quote currency address (address(0) for USD). Must have PriceFeedConfig configured.
    /// @return nav The NAV of the account in the specified quote currency
    function getAccountNav(address account, address baseAsset) external view returns (NAV memory nav);

    /// @notice Gets NAV for a range of assets (chunked query)
    /// @param account The address of the account to calculate for
    /// @param from Starting asset index (inclusive, from asset enumeration)
    /// @param to Ending asset index (inclusive, from asset enumeration)
    /// @param baseAsset The quote currency address (address(0) for USD). Must have PriceFeedConfig configured.
    /// @dev Validates that from <= to and both indices are within asset count bounds
    /// @dev Reverts with InvalidArguments if indices are out of range or from > to
    /// @return nav The NAV of the account for the specified asset range in the quote currency
    function getAccountNavForRange(address account, uint256 from, uint256 to, address baseAsset)
        external
        view
        returns (NAV memory nav);

    /// @notice Gets all positions for a given account with pricing in the specified quote currency
    /// @param account The address of the account to calculate for
    /// @param quoteAsset The quote currency address (address(0) for USD). Must have PriceFeedConfig configured.
    /// @return positions Array of enriched Position structs with pricing information
    /// @dev This method aggregates balance-only PositionBalance data from oracles and enriches them with pricing
    function getAccountPositions(address account, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice Gets positions for a specific asset for a given account
    /// @param account The address of the account to calculate for
    /// @param asset The specific asset to filter by (must be registered)
    /// @param quoteAsset The quote currency address (address(0) for USD). Must have PriceFeedConfig configured.
    /// @return positions Array of enriched Position structs with pricing information for the specified asset
    /// @dev This method aggregates balance-only PositionBalance data from oracles and enriches them with pricing
    function getAccountPositionsForAsset(address account, address asset, address quoteAsset)
        external
        view
        returns (Position[] memory positions);

    /// @notice The amount of decimals returned with each USD value
    /// @return The amount of decimals
    function usdDecimals() external view returns (uint8);

    /// @notice Returns the asset at a given index
    /// @param idx The index of the asset
    /// @return The asset at the given index
    function assetAt(uint256 idx) external view returns (Asset memory);

    /// @notice Returns the assets for this calculator
    /// @return The assets known by this calculator
    function assets() external view returns (address[] memory);

    /// @notice Returns comprehensive price feed query result for a given token
    /// @param underlyingAsset The address of the token
    /// @return priceFeed The complete price information including oracle details, price, staleness, and sequencer status
    function getPriceData(address underlyingAsset) external view returns (PriceFeed memory priceFeed);

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

    /// @notice Calculates the total value of provided asset balances in the specified quote currency
    /// @param assets Array of asset addresses
    /// @param amounts Array of amounts corresponding to each asset (always positive)
    /// @param isDebt Array of flags indicating whether each amount is debt (true) or credit (false)
    /// @param quoteCurrency The address of the quote currency (address(0) for USD)
    /// @return value The total value of all balances in the quote currency
    /// @dev Arrays must be the same length. Each asset must be registered and have a price oracle.
    /// @dev If quoteCurrency is address(0), returns USD value. Otherwise, converts from USD to quoteCurrency.
    /// @dev Debt positions (isDebt = true) are subtracted from the total, credit positions (isDebt = false) are added.
    function calculateValue(
        address[] memory assets,
        uint256[] memory amounts,
        bool[] memory isDebt,
        address quoteCurrency
    ) external view returns (int256 value);
}
