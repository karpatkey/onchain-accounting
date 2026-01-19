// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IPrices} from "src/prices/Prices.sol";
import {IBalances} from "src/balances/Balances.sol";

/// @title INAVCalculator Interface
/// @notice Interface for NAVCalculator contract
/// @author kpk
interface INAVCalculator {
    /// @notice A holding a specific asset, and its corresponding usd equivalent
    ///   This can represent a direct ERC20 balance, or a position deposited in a 3rd party contract
    /// @param underlyingAsset Address of the token
    /// @param balance The amount of the asset
    /// @param usd Amount of USD equivalent represented with NAV_DECIMALS decimals
    /// @param usdRate The usd rate used, i.e. the USD price per one full token unit, scaled by `usdRateDecimals`
    /// @param usdRateDecimals The decimals with which usdRate is represented
    /// @param stale Whether this asset's USD price is currently considered stale (asset-specific, e.g., heartbeat timeout)
    /// @param sequencerDown Whether the L2 sequencer is down (global issue, affects all prices on L2 chains)
    struct Position {
        address underlyingAsset;
        int256 balance;
        int256 usd;
        uint256 usdRate;
        uint256 usdRateDecimals;
        bool stale;
        bool sequencerDown;
    }

    /// @notice An enriched position record including on‑chain amounts plus human‑readable metadata
    /// @param protocol The protocol name for the position (e.g. "Portfolio balance", "Aave", etc.)
    /// @param position The specified position within the protocol
    /// @param positionType The type of the position (e.g., "Supplied", "Borrowed", "Native", "ERC20", etc.).
    /// @param underlyingAsset The address of the underlying token
    /// @param underlyingAssetSymbol The symbol of the underlying asset (e.g. "USDC", "ETH")
    /// @param underlyingAssetDecimals Number of decimals of the underlying asset
    /// @param usdRate The usd rate used, i.e. the USD price per one full token unit, scaled by `usdRateDecimals`
    /// @param usdRateDecimals The decimals with which usdRate is represented
    /// @param stale Whether this asset's USD price is currently considered stale (asset-specific, e.g., heartbeat timeout)
    /// @param balance The equivalent balance of this underlyng asset (signed to allow negative/debt positions)
    /// @param usd Amount of USD equivalent represented with NAV_DECIMALS decimals
    /// @param sequencerDown Whether the L2 sequencer is down (global issue, affects all prices on L2 chains)
    struct PositionWithMetadata {
        string protocol;
        string position;
        string positionType;
        address underlyingAsset;
        string underlyingAssetSymbol;
        uint8 underlyingAssetDecimals;
        uint256 usdRate;
        uint256 usdRateDecimals;
        bool stale;
        int256 balance;
        int256 usd;
        bool sequencerDown;
    }

    /// @notice The complete NAV snapshot
    /// @param block Block number this reading refers to
    /// @param timestamp Block timestamp this reading refers to
    /// @param usd Total USD calculated
    /// @param stalePriceAssets Array of assets that have stale prices (asset-specific issues)
    /// @param sequencerDown Whether the L2 sequencer is down (global issue affecting all prices)
    /// @notice   If sequencerDown is true or stalePriceAssets.length > 0, this reading should not be used to
    /// @notice   compute deposits/withdrawals, but may still be kept for notifications & historical purposes
    struct NAV {
        uint64 block;
        uint64 timestamp;
        int256 usd;
        address[] stalePriceAssets;
        bool sequencerDown;
    }

    /// @notice A known ERC20 asset
    /// @param addr The address of the asset
    /// @param decimals The number of decimals the asset uses
    struct Asset {
        address addr;
        uint8 decimals;
    }

    /// @notice Comprehensive price data for a token
    /// @param oracle The address of the price oracle
    /// @param priceType The type of oracle (Chainlink or Custom)
    /// @param price The current price
    /// @param decimals The decimals used by the oracle
    /// @param chainlinkHeartbeat The heartbeat interval (Chainlink only)
    /// @param updatedAt The timestamp when price was last updated (Chainlink only, 0 for custom)
    /// @param stale Whether the price is stale (asset-specific, e.g., heartbeat timeout)
    /// @param sequencerDown Whether L2 sequencer is down (L2 only, false on L1)
    struct PriceData {
        address oracle;
        IPrices.PriceType priceType;
        uint256 price;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        uint256 updatedAt; // For Chainlink: timestamp from latestRoundData, for Custom: 0
        bool stale;
        bool sequencerDown;
    }

    /// @notice Detailed asset position with all positions for that asset
    /// @param asset The address of the asset
    /// @param assetSymbol The symbol of the asset (e.g. "USDC", "ETH")
    /// @param assetDecimals The number of decimals of the asset
    /// @param totalBalance The aggregated balance across all positions for this asset (signed to allow debt)
    /// @param totalUsd The total USD value of all positions for this asset, scaled by NAV_DECIMALS
    /// @param usdRate The USD price per one full token unit, scaled by `usdRateDecimals`
    /// @param usdRateDecimals The decimals with which usdRate is represented
    /// @param stale Whether this asset's USD price is currently considered stale (asset-specific)
    /// @param sequencerDown Whether the L2 sequencer is down (global issue, affects all prices)
    /// @param positions Array of all positions for this asset across all protocols
    struct AssetPosition {
        address asset;
        string assetSymbol;
        uint8 assetDecimals;
        int256 totalBalance;
        int256 totalUsd;
        uint256 usdRate;
        uint256 usdRateDecimals;
        bool stale;
        bool sequencerDown;
        PositionWithMetadata[] positions;
    }

    /// @notice Detailed protocol position with all positions for that protocol
    /// @param protocol The protocol name (e.g. "Aave", "Portfolio balance", etc.)
    /// @param totalUsd The total USD value of all positions for this protocol, scaled by NAV_DECIMALS
    /// @param sequencerDown Whether the L2 sequencer is down (global issue, affects all prices)
    /// @param positions Array of all positions for this protocol across all assets
    struct ProtocolPosition {
        string protocol;
        int256 totalUsd;
        bool sequencerDown;
        PositionWithMetadata[] positions;
    }

    /// @notice Complete detailed NAV organized by asset
    /// @param nav The standard NAV struct with aggregated totals
    /// @param assetPositions Array of asset positions, one per asset with non-zero balances
    struct DetailedNAV {
        NAV nav;
        AssetPosition[] assetPositions;
    }

    /// @notice Complete detailed positions organized by protocol
    /// @param nav The standard NAV struct with aggregated totals
    /// @param protocolPositions Array of protocol positions, one per protocol with positions
    struct DetailedPositions {
        NAV nav;
        ProtocolPosition[] protocolPositions;
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
    error AssetNotFound();

    /// @notice Emitted when 'setSequencerGracePeriod' is called and 'chainlinkUptimeFeed' is the zero address
    error UptimeFeedNotSet();

    /// @notice Registers a new asset in the calculator without any oracles.
    /// @param asset The address of the asset to register
    /// @dev Trying to read anything related to such asset would fail until oracles are set.
    function registerAsset(address asset) external;

    /// @notice Sets the price oracle for an existing asset.
    /// @param asset The address of the asset
    /// @param oracle The address of the price oracle to use
    /// @param priceType The type of the price oracle
    /// @param chainlinkHeartbeat The heartbeat interval for the Chainlink oracle. This is relevant only for Chainlink
    /// oracles.
    /// @dev Cannot be called before registering the asset. Replaces any existing price oracle.
    function setPriceOracle(address asset, address oracle, IPrices.PriceType priceType, uint256 chainlinkHeartbeat)
        external;

    /// @notice Sets a balance oracle for an existing asset.
    /// @param underlyingAsset The address of the token to set a balance oracle for.
    /// @param oracle The address of the balance oracle to use.
    /// @param balanceType The type of the balance.
    /// @dev Cannot be called before registering the asset. Replaces any existing balance oracle with the same address.
    function setBalanceOracle(address underlyingAsset, address oracle, IBalances.BalanceType balanceType) external;

    /// @notice Unsets the price oracle for a given asset.
    /// @param underlyingAsset The address of the asset.
    /// @dev The asset remains registered after this operation.
    function unsetPriceOracle(address underlyingAsset) external;

    /// @notice Unsets a balance oracle for a given asset.
    /// @param underlyingAsset The address of the asset.
    /// @param oracle The address of the balance oracle to unset.
    /// @dev The asset remains registered after this operation.
    function unsetBalanceOracle(address underlyingAsset, address oracle) external;

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

    /// @notice Reads the current NAV of a given account.
    /// @param account The address of the account to calculate for.
    /// @dev This function reads all known assets, and might exhaust gas if there are too many
    /// assets known by the calculator contract at the time of calling.
    /// It is recommended to use the readPositionsRange function instead, with an appropriate range of assets and call
    /// it multiple times if necessary.
    /// @return The NAV of the account.
    function read(address account) external view returns (NAV memory);

    /// @notice Reads the holdings of a given account, for a limited range of assets
    ///   Also includes the corresponding usd total, and the amount of issues found long the way
    ///
    /// Important :
    /// - The ordering of oracles in the underlying data structure is not guaranteed. Entries may change order as
    ///    oracles are added or removed . It is not safe to assume a fixed order or that the same
    ///    query will yield a consistent oracle order.
    ///
    /// - Ensure that any external integrations using
    ///    the oracle data accounts for potential reordering, and calls `balanceOracleAt` directly for
    ///    verification if needed.
    ///
    /// @param account The address to calculate for
    /// @param underlyingAsset The address of the token to calculate
    /// @param idx The index of the balance oracle
    /// @return p A `Position` struct containing:
    ///              • `underlyingAsset` – the token address
    ///              • `balance` – the on‑chain asset amount (signed to allow negative/debt)
    ///              • `usdRate` – USD price per full token unit (scaled by `usdRateDecimals`)
    ///              • `usdRateDecimals` – decimals used in `usdRate`
    ///              • `usd` – amount of USD equivalent represented with NAV_DECIMALS decimals
    ///              • `stale` – whether this asset's USD price is currently considered stale (asset-specific)
    ///              • `sequencerDown` – whether the L2 sequencer is down (global issue, affects all prices)
    function readPosition(address account, address underlyingAsset, uint256 idx)
        external
        view
        returns (Position memory p);

    /// @notice Reads a single enriched position record—including human‑readable metadata for a given account and
    /// balance oracle.
    /// @param account The address to calculate for
    /// @param underlyingAsset The address of the token to calculate
    /// @param idx The index of the balance oracle
    /// @return p A `PositionWithMetadata` struct containing:
    ///               • `protocol` — The protocol name for the position (e.g. "Portfolio balance", "Aave", etc.)
    ///               • `position` — The specified position within the protocol
    ///               • `positionType` — The type of the position (e.g., "Supplied", "Borrowed", "ERC20", etc.)
    ///               • `underlyingAsset`— The address of the underlying token
    ///               • `underlyingAssetSymbol` — The symbol of the underlying asset (e.g. "USDC", "ETH")
    ///               • `underlyingAssetDecimals` — Number of decimals of the underlying asset
    ///               • `usdRate` — The USD price per one full token unit, scaled by `usdRateDecimals`
    ///               • `usdRateDecimals` — How many decimals are used in `usdRate`
    ///               • `stale` — Whether this asset's USD price is currently considered stale (asset-specific)
    ///               • `balance` — The equivalent balance of this underlying asset (signed to allow negative/debt
    /// positions)
    ///               • `usd` — Amount of USD equivalent represented with `NAV_DECIMALS` decimals
    ///               • `sequencerDown` — Whether the L2 sequencer is down (global issue, affects all prices)
    function readPositionWithMetadata(address account, address underlyingAsset, uint256 idx)
        external
        view
        returns (PositionWithMetadata memory p);

    /// @notice Reads the holdings of a given account, for a limited range of assets.
    /// Also includes the corresponding usd total, assets with stale prices, and sequencer status.
    ///
    /// Important:
    /// - The ordering of balances in the returned array is not guaranteed. Entries may change order as oracles
    ///    are added or removed from the nav calculator. It is not safe to assume a fixed order or that the same
    ///    query will yield a consistent oracle order.
    ///
    /// - To ensure complete and consistent data, it is recommended to retrieve the full range in a single query.
    ///
    /// - If a caller splits their query range into smaller parts (e.g., retrieving assets 0 to 20 in two
    ///    separate calls: 0-10 and 11-20), there is a risk of duplicating or missing assets if a oracle for that asset
    /// was added or removed. Ensure that any external integrations using
    ///    the oracle data account for potential reordering, and calls `balanceOracleAt` directly for
    ///    verification if needed.
    ///
    /// @param account The address to calculate for
    /// @param from The index of the first balance oracle
    /// @param to The index of the last balance oracle
    /// @return usd The total USD value of the positions
    /// @return stalePriceAssets Array of assets that have stale prices (asset-specific issues)
    /// @return sequencerDown Whether the L2 sequencer is down (global issue affecting all prices)
    function readPositionsRange(address account, uint256 from, uint256 to)
        external
        view
        returns (int256 usd, address[] memory stalePriceAssets, bool sequencerDown);

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

    /// @notice Returns comprehensive price data for a given token
    /// @param underlyingAsset The address of the token
    /// @return priceData The complete price information including oracle details, price, staleness, and sequencer status
    function getPriceData(address underlyingAsset) external view returns (PriceData memory priceData);

    /// @notice Returns, for a single account, correlated arrays of assets, balances and USD values (one entry per asset)
    /// @param account The address to calculate for
    /// @return assets The list of assets with non‑zero aggregated balances for the account
    /// @return balances The aggregated balances per asset (signed to allow debt)
    /// @return usdValues The USD values per asset, scaled by `NAV_DECIMALS`
    function readAccountPositions(address account)
        external
        view
        returns (address[] memory assets, int256[] memory balances, int256[] memory usdValues);

    /// @notice Returns overall health status
    /// @return sequencerDown Whether the L2 sequencer is down (false on L1)
    /// @return stalePriceAssets Array of assets with stale prices
    function healthCheck() external view returns (bool sequencerDown, address[] memory stalePriceAssets);

    /// @notice Returns true if the account has any non‑zero aggregated balance across all assets/oracles
    /// @param account The address to check
    /// @return has Any position present
    function hasPositions(address account) external view returns (bool has);

    /// @notice Reads the current NAV of a given account, converted to a base asset.
    /// @param account The address of the account to calculate for.
    /// @param baseAsset The address of the asset to convert NAV to (e.g., ETH address).
    /// @dev This function reads all known assets, and might exhaust gas if there are too many
    /// assets known by the calculator contract at the time of calling.
    /// It is recommended to use the readPositionsRangeInBaseAsset function instead, with an appropriate range of assets and call
    /// it multiple times if necessary.
    /// @return nav The NAV of the account in the base asset, with the same structure as read() but with baseAssetValue instead of usd.
    /// @return baseAssetValue The NAV value in the base asset, represented with the base asset's decimals.
    /// @return baseAssetStale Whether the base asset's price is stale.
    function readInBaseAsset(address account, address baseAsset)
        external
        view
        returns (NAV memory nav, int256 baseAssetValue, bool baseAssetStale);

    /// @notice Reads a single position, with its value converted to a base asset.
    /// @param account The address to calculate for
    /// @param underlyingAsset The address of the token to calculate
    /// @param idxBalanceOracle The index of the balance oracle
    /// @param baseAsset The address of the asset to convert the position value to (e.g., ETH address).
    /// @return p The position struct with baseAssetValue field populated.
    /// @return baseAssetValue The position value in the base asset, represented with the base asset's decimals.
    /// @return baseAssetStale Whether the base asset's price is stale.
    function readPositionInBaseAsset(
        address account,
        address underlyingAsset,
        uint256 idxBalanceOracle,
        address baseAsset
    ) external view returns (Position memory p, int256 baseAssetValue, bool baseAssetStale);

    /// @notice Returns detailed NAV organized per asset with all positions
    /// @dev This function reads all known assets and might exhaust gas if there are too many assets.
    /// It is recommended to use readPositionsRange for large asset sets.
    /// @param account The address to calculate for
    /// @return detailedNAV A DetailedNAV struct containing:
    ///   - nav: Standard NAV struct with aggregated totals
    ///   - assetPositions: Array of AssetPosition structs, one per asset with non-zero balances,
    ///     each containing all positions for that asset organized by protocol
    function readDetailedNAV(address account) external view returns (DetailedNAV memory detailedNAV);

    /// @notice Returns all positions organized by protocol with their amounts and values
    /// @dev This function reads all known assets and might exhaust gas if there are too many assets.
    /// It is recommended to use readPositionsRange for large asset sets.
    /// @param account The address to calculate for
    /// @return detailedPositions A DetailedPositions struct containing:
    ///   - nav: Standard NAV struct with aggregated totals
    ///   - protocolPositions: Array of ProtocolPosition structs, one per protocol with positions,
    ///     each containing all positions for that protocol across all assets
    function readDetailedPositions(address account) external view returns (DetailedPositions memory detailedPositions);
}
