// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IPrices} from "src/prices/Prices.sol";
import {IBalances} from "src/balances/Balances.sol";

/// @title INAVCalculator Interface
/// @notice Interface for NAVCalculator contract
/// @author kpk
interface INAVCalculator {
    /// @notice Core position data (currency-agnostic)
    /// @param asset Address of the asset
    /// @param assetSymbol Asset symbol (e.g., "USDC", "ETH")
    /// @param assetDecimals Asset decimals
    /// @param protocol Protocol name (e.g., "Aave", "Portfolio balance")
    /// @param position Position identifier within protocol
    /// @param positionType Position type (e.g., "Supplied", "Borrowed", "ERC20")
    /// @param balance Position balance (signed for debt)
    struct PositionCore {
        address asset;
        string assetSymbol;
        uint8 assetDecimals;
        string protocol;
        string position;
        string positionType;
        int256 balance;
    }

    /// @notice Pricing extension (currency-specific)
    /// @param quoteCurrency Quote currency address (address(0) for USD)
    /// @param quoteCurrencySymbol Quote currency symbol
    /// @param quoteCurrencyDecimals Quote currency decimals
    /// @param value Position value in quote currency
    /// @param rate Exchange rate (price per unit)
    /// @param rateDecimals Rate decimals
    /// @param stale Whether price is stale
    /// @param sequencerDown Whether sequencer is down
    struct PositionPricing {
        address quoteCurrency;
        string quoteCurrencySymbol;
        uint8 quoteCurrencyDecimals;
        int256 value;
        uint256 rate;
        uint8 rateDecimals;
        bool stale;
        bool sequencerDown;
    }

    /// @notice Complete position with pricing
    /// @param core Core position data
    /// @param pricing Pricing information
    struct VerbosePosition {
        PositionCore core;
        PositionPricing pricing;
    }

    /// @notice Complete account positions response
    /// @param nav Standard NAV (USD total)
    /// @param positions Flat array of all positions
    struct AccountPositions {
        NAV nav;
        VerbosePosition[] positions;
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

    /// @notice Gets the total NAV value in USD for a given account
    /// @param account The address of the account to calculate for
    /// @dev This function reads all known assets, and might exhaust gas if there are too many
    /// assets known by the calculator contract at the time of calling.
    /// @return nav The NAV of the account in USD
    function getTotalNAV(address account) external view returns (NAV memory nav);

    /// @notice Gets all positions for a given account with pricing in the specified currency
    /// @param account The address of the account to calculate for
    /// @param quoteCurrency The address of the quote currency (address(0) for USD)
    /// @dev If quoteCurrency is address(0), returns USD pricing. Otherwise, converts from USD to the specified currency.
    /// @return accountPositions AccountPositions struct containing NAV and flat array of all positions
    function getAllPositions(address account, address quoteCurrency)
        external
        view
        returns (AccountPositions memory accountPositions);


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
    /// @param balances Array of balances corresponding to each asset (signed to allow debt)
    /// @param quoteCurrency The address of the quote currency (address(0) for USD)
    /// @return value The total value of all balances in the quote currency
    /// @dev Arrays must be the same length. Each asset must be registered and have a price oracle.
    /// @dev If quoteCurrency is address(0), returns USD value. Otherwise, converts from USD to quoteCurrency.
    function calculateValue(
        address[] memory assets,
        int256[] memory balances,
        address quoteCurrency
    ) external view returns (int256 value);

}
