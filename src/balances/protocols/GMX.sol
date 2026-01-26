// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ArrayUtils} from "src/utils/ArrayUtils.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title GMX
/// @notice Balance oracle for GMX synthetic positions
contract GmxBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using Math for uint256;

    //
    // Constants
    //

    /// @notice Number of decimals used in floating point calculations
    uint256 public constant FLOAT_PRECISION_DECIMALS = 30;
    /// @notice Position list key for GMX data store
    bytes32 public constant POSITION_LIST = keccak256(abi.encode("POSITION_LIST"));
    /// @notice synthetic BTC token address used in GMX
    address public constant SYN_BTC = 0x47904963fc8b2340414262125aF798B9655E58Cd;
    /// @notice WBTC token address
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    /// @notice Struct to hold token and its corresponding price feed
    /// @param token Address of the token
    /// @param feed Address of the Chainlink price feed for the token
    struct TokenFeed {
        address token;
        address feed;
    }

    //
    // Type Definitions
    //

    /// @notice Asset balance data structure
    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice GMX Reader contract for fetching market and position data
    IGMXReader public immutable READER;
    /// @notice GMX Referral Storage contract
    address public immutable REFERRAL_STORAGE;
    /// @notice GMX Market contract address
    address public immutable GMX_MARKET;
    /// @notice GMX Data Store contract
    IDataStore public immutable DATA_STORE;
    /// @notice USDC token contract
    IERC20Metadata public immutable USDC;
    /// @notice Collateral token address
    address public immutable COLLATERAL_TOKEN;
    /// @notice Whether the position is long
    bool public immutable IS_LONG;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Mapping of token addresses to their price feeds
    mapping(address => AggregatorV3Interface) public priceFeeds;
    /// @notice Market properties for the GMX market
    IGMXReader.MarketProps public marketProps;

    //
    // Constructor
    //

    /// @param market_ Address of the GMX market
    /// @param reader_ Address of the GMX reader contract
    /// @param referralStorage_ Address of the GMX referral storage contract
    /// @param usdc_ Address of the USDC token
    /// @param collateralToken_ Address of the collateral token
    /// @param isLong_ Whether the position is long
    /// @param tokenFeeds_ Array of token and price feed pairs
    /// @param protocol_ Protocol identifier (e.g., "GMX").
    /// @param positionDetail_ Position detail identifier (e.g., "Long/Short Position").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(
        address market_,
        address reader_,
        address referralStorage_,
        address usdc_,
        address collateralToken_,
        bool isLong_,
        TokenFeed[] memory tokenFeeds_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        require(market_.code.length > 0, "Market must be a contract");
        require(reader_.code.length > 0, "Reader must be a contract");
        require(referralStorage_.code.length > 0, "ReferralStorage must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");
        
        GMX_MARKET = market_;
        READER = IGMXReader(reader_);
        REFERRAL_STORAGE = referralStorage_;
        DATA_STORE = IDataStore(IMarket(GMX_MARKET).dataStore());
        USDC = IERC20Metadata(usdc_);
        COLLATERAL_TOKEN = collateralToken_;
        IS_LONG = isLong_;
        marketProps = READER.getMarket(DATA_STORE, GMX_MARKET);

        for (uint256 i = 0; i < tokenFeeds_.length; i++) {
            priceFeeds[tokenFeeds_[i].token] = AggregatorV3Interface(tokenFeeds_[i].feed);
        }

        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance (positive for credit, negative for debt)
    /// @dev Position value calculation breakdown:
    /// 1. Net Value Formula:
    ///    Net Value = Initial Collateral + PnL - Borrow Fee - Negative Funding Fee - Close Fee
    ///
    /// 2. PnL Calculation:
    ///    For Shorts: PnL = (SizeInTokens * EntryPrice) - (SizeInTokens * CurrentPrice)
    ///                = SizeInAmount - (SizeInTokens * CurrentPrice)
    ///
    ///    For Longs:  PnL = (SizeInTokens * CurrentPrice) - (SizeInTokens * EntryPrice)
    ///                = (SizeInTokens * CurrentPrice) - SizeInAmount
    ///
    /// 3. Net Value Decomposition:
    ///    Net Value = (Initial Collateral * CurrentCollateralPrice) + PnL
    ///               - (Borrow Fee * CurrentCollateralPrice) - (Funding Fee * CurrentCollateralPrice)
    ///               - (Close Fee * CurrentCollateralPrice)
    ///
    ///    Simplified:
    ///    Net Value = PnL + (CollateralAmount - BorrowingFee - FundingFee - PositionFee) * CurrentCollateralPrice
    ///
    /// 4. Balance Calculation:
    ///    The balanceOf function returns the position value in the requested token:
    ///    - For USDC: Returns the SizeInAmount USD value of the position
    ///    - For Collateral Token: Returns the collateral value minus fees
    ///    - For Long/Short Token: Returns the SizeInTokens amount of the position in the Long/Short token
    ///
    /// Reference:
    /// https://github.com/gmx-io/gmx-synthetics/blob/66b5d7dbd4684d7612c9db6f6a3000be84fa2ff7/contracts/position/PositionUtils.sol#L189
    function _calculateBalance(address underlyingAsset, address account) internal view returns (int256 balance) {
        if (underlyingAsset == address(0) || account == address(0)) {
            return 0;
        }

        IGMXReader.MarketPrices[] memory marketPrices = getMarketPrices();

        IGMXReader.PositionInfo memory positionInfo =
            getPositionInfo(account, GMX_MARKET, COLLATERAL_TOKEN, IS_LONG, marketPrices);

        int256 total = 0;

        if (underlyingAsset == address(USDC)) {
            (uint256 usdcPrice, uint256 oracleDecimals) = getPrice(underlyingAsset);
            uint256 usdPriceScaled =
                positionInfo.position.numbers.sizeInUsd / (10 ** (FLOAT_PRECISION_DECIMALS - oracleDecimals));

            int256 sizeInUsdc = usdPriceScaled.mulDiv(10 ** USDC.decimals(), usdcPrice, Math.Rounding.Floor).toInt256();

            if (IS_LONG) {
                total -= sizeInUsdc;
            } else {
                total += sizeInUsdc;
            }
        }

        if (IS_LONG && underlyingAsset == marketProps.longToken) {
            total += int256(positionInfo.position.numbers.sizeInTokens);
        } else if (!IS_LONG && underlyingAsset == marketProps.shortToken) {
            total -= int256(positionInfo.position.numbers.sizeInTokens);
        }

        if (underlyingAsset == positionInfo.position.addresses.collateralToken) {
            total += int256(positionInfo.position.numbers.collateralAmount)
            - (int256(
                    positionInfo.fees.borrowing.borrowingFeeAmount + positionInfo.fees.funding.fundingFeeAmount
                        + positionInfo.fees.positionFeeAmount
                ));
        }

        return total;
    }

    /// @notice Get market prices for the GMX market
    /// @return Array of market prices
    function getMarketPrices() public view returns (IGMXReader.MarketPrices[] memory) {
        IGMXReader.MarketPrices[] memory marketPrices = new IGMXReader.MarketPrices[](1);
        marketPrices[0] = IGMXReader.MarketPrices(
            getPriceProps(marketProps.indexToken),
            getPriceProps(marketProps.longToken),
            getPriceProps(marketProps.shortToken)
        );
        return marketPrices;
    }

    /// @notice Get price properties for a token
    /// @param token Address of the token to get price for
    /// @return Price properties for the token
    function getPriceProps(address token) public view returns (IGMXReader.PriceProps memory) {
        // BTC synthetic token address is not a real ERC20 token or even a contract,
        // so we need to map it to the actual BTC token that has a price feed and token decimals.
        if (token == SYN_BTC) {
            token = WBTC;
        }

        (uint256 tokenPrice, uint256 oracleDecimals) = getPrice(token);

        uint256 tokenPriceScaled =
            tokenPrice * (10 ** (FLOAT_PRECISION_DECIMALS - oracleDecimals - IERC20Metadata(token).decimals()));

        return IGMXReader.PriceProps(tokenPriceScaled, tokenPriceScaled);
    }

    /// @notice Get the price of a token using its Chainlink price feed
    /// @param token Address of the token to get price for
    /// @return Price of the token
    /// @return Decimals of the price feed
    function getPrice(address token) public view returns (uint256, uint256) {
        AggregatorV3Interface tokenPricefeed = priceFeeds[token];

        if (address(tokenPricefeed) == address(0)) {
            return (0, 0);
        }

        (, int256 price,,,) = tokenPricefeed.latestRoundData();
        // casting to 'uint256' is safe because Chainlink prices are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(price), tokenPricefeed.decimals());
    }

    /// @notice Get position information for a safe
    /// @param safe Address of the safe
    /// @param market Address of the GMX market
    /// @param collateralAddress Address of the collateral token
    /// @param isLong Whether the position is long
    /// @param prices Market prices
    /// @return account Position information the safe
    function getPositionInfo(
        address safe,
        address market,
        address collateralAddress,
        bool isLong,
        IGMXReader.MarketPrices[] memory prices
    ) public view returns (IGMXReader.PositionInfo memory account) {
        bytes32 positionKey = getPositionKey(safe, market, collateralAddress, isLong);

        if (!hasPosition(positionKey)) {
            account.position.flags.isLong = isLong;
            account.position.addresses.account = address(safe);
            account.position.addresses.market = market;
            account.position.addresses.collateralToken = collateralAddress;
            return account;
        }

        return READER.getPositionInfo(
            address(DATA_STORE), address(REFERRAL_STORAGE), positionKey, prices[0], 0, address(0), true
        );
    }

    /// @notice Get position key for a safe
    /// @param account Address of the account
    /// @param market Address of the GMX market
    /// @param collateralToken Address of the collateral token
    /// @param isLong Whether the position is long
    /// @return Position key
    function getPositionKey(address account, address market, address collateralToken, bool isLong)
        public
        pure
        returns (bytes32)
    {
        bytes32 key = keccak256(abi.encode(account, market, collateralToken, isLong));
        return key;
    }

    /// @notice Check if a position exists
    /// @param positionKey Position key to check
    /// @return Whether the position exists
    function hasPosition(bytes32 positionKey) public view returns (bool) {
        return DATA_STORE.containsBytes32(POSITION_LIST, positionKey);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        // Return USDC + (longToken or shortToken based on IS_LONG) + COLLATERAL_TOKEN
        address[] memory assets = new address[](3);
        assets[0] = address(USDC);
        assets[1] = IS_LONG ? marketProps.longToken : marketProps.shortToken;
        assets[2] = COLLATERAL_TOKEN;
        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (int256 balance)
    {
        // Optimized: directly calculate balance without building full Position structs
        balance = _calculateBalance(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory balances)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempBalances = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = asset;
                tempBalances[count] = balance;
                count++;
            }
        }

        // Resize to actual count
        assets = new address[](count);
        balances = new int256[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            balances[i] = tempBalances[i];
        }
    }


    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's GMX positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by GMX and registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        address[] memory registeredAssets = NAV_CALCULATOR.assets();

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayUtils.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData;
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    int256 balance = _calculateBalance(assetFilter, account);
                    if (balance != 0) {
                        // Convert int256 balance back to (uint256 amount, bool isDebt) for AssetBalanceData
                        uint256 amount;
                        bool isDebt;
                        if (balance < 0) {
                            amount = uint256(-balance);
                            isDebt = true;
                        } else {
                            amount = uint256(balance);
                            isDebt = false;
                        }
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: amount, isDebt: isDebt});
                    } else {
                        assetBalanceData = new AssetBalanceData[](0);
                    }
                    break;
                }
            }
        } else {
            // Pre-allocate temporary array (max size)
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                int256 balance = _calculateBalance(registeredSupportedAssets[i], account);
                if (balance != 0) {
                    // Convert int256 balance back to (uint256 amount, bool isDebt) for AssetBalanceData
                    uint256 amount;
                    bool isDebt;
                    if (balance < 0) {
                        amount = uint256(-balance);
                        isDebt = true;
                    } else {
                        amount = uint256(balance);
                        isDebt = false;
                    }
                    tempData[count] = AssetBalanceData({asset: registeredSupportedAssets[i], amount: amount, isDebt: isDebt});
                    count++;
                }
            }

            // Resize to actual count
            assetBalanceData = new AssetBalanceData[](count);
            for (uint256 i = 0; i < count; i++) {
                assetBalanceData[i] = tempData[i];
            }
        }
        positions = _buildPositions(assetBalanceData);
    }

    //
    // Internal Functions - Asset Registry & Lookup
    //

    /// @notice Gets asset information from NAVCalculator by iterating through registered assets
    /// @param asset The asset address to look up
    /// @return assetInfo The Asset struct containing asset address, symbol, and decimals
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory assetInfo) {
        uint256 assetCount = NAV_CALCULATOR.assetCount();
        for (uint256 i = 0; i < assetCount; i++) {
            INAVCalculator.Asset memory a = NAV_CALCULATOR.assetAt(i);
            if (a.asset == asset) {
                return a;
            }
        }
        revert("Asset not found in NAVCalculator");
    }

    //
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this oracle
    /// @param assetBalanceData Array of AssetBalanceData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets are guaranteed to be registered (filtered in getOraclePositions).
    function _buildPositions(AssetBalanceData[] memory assetBalanceData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetBalanceData.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](assetBalanceData.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetBalanceData.length; i++) {
            address asset = assetBalanceData[i].asset;

            // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

            // Build position (balance-only, pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    amount: assetBalanceData[i].amount,
                    isDebt: assetBalanceData[i].isDebt,
                    protocol: _protocol,
                    positionDetail: _positionDetail
                });

            positionCount++;
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
}

/// @title IMarket
/// @notice Interface for GMX market
interface IMarket {
    /// @notice Get the data store address
    /// @return Address of the data store
    function dataStore() external view returns (address);
}

/// @title IDataStore
/// @notice Interface for GMX data store
interface IDataStore {
    /// @notice Check if a bytes32 value exists for a key
    /// @param key Key to check
    /// @param value Value to check
    /// @return Whether the value exists
    function containsBytes32(bytes32 key, bytes32 value) external view returns (bool);
}

/// @title IGMXReader
/// @notice Interface for GMX reader contract that provides market and position data
interface IGMXReader {
    /// @notice Struct containing position addresses
    /// @param account Address of the position owner
    /// @param market Address of the GMX market
    /// @param collateralToken Address of the collateral token
    struct Addresses {
        address account;
        address market;
        address collateralToken;
    }

    /// @notice Struct containing position numbers
    /// @param sizeInUsd Size of the position in USD
    /// @param sizeInTokens Size of the position in tokens
    /// @param collateralAmount Amount of collateral
    /// @param borrowingFactor Factor used for borrowing calculations
    /// @param fundingFeeAmountPerSize Funding fee amount per size
    /// @param longTokenClaimableFundingAmountPerSize Claimable funding amount per size for long token
    /// @param shortTokenClaimableFundingAmountPerSize Claimable funding amount per size for short token
    /// @param increasedAtTime Time when position was increased
    /// @param decreasedAtTime Time when position was decreased
    struct Numbers {
        uint256 sizeInUsd;
        uint256 sizeInTokens;
        uint256 collateralAmount;
        uint256 borrowingFactor;
        uint256 fundingFeeAmountPerSize;
        uint256 longTokenClaimableFundingAmountPerSize;
        uint256 shortTokenClaimableFundingAmountPerSize;
        uint256 increasedAtTime;
        uint256 decreasedAtTime;
    }

    /// @notice Struct containing position flags
    /// @param isLong Whether the position is long
    struct Flags {
        bool isLong;
    }

    /// @notice Struct containing position properties
    /// @param addresses Position addresses
    /// @param numbers Position numbers
    /// @param flags Position flags
    struct Props {
        Addresses addresses;
        Numbers numbers;
        Flags flags;
    }

    /// @notice Struct containing market properties
    /// @param marketToken Address of the market token
    /// @param indexToken Address of the index token
    /// @param longToken Address of the long token
    /// @param shortToken Address of the short token
    struct MarketProps {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
    }

    /// @notice Struct containing position information
    /// @param position Position properties
    /// @param fees Position fees
    /// @param executionPriceResult Execution price result
    /// @param basePnlUsd Base PnL in USD
    /// @param pnlAfterPriceImpactUsd PnL after price impact in USD
    struct PositionInfo {
        Props position;
        PositionFees fees;
        ExecutionPriceResult executionPriceResult;
        int256 basePnlUsd;
        int256 pnlAfterPriceImpactUsd;
    }

    /// @notice Struct containing execution price result
    /// @param priceImpactUsd Price impact in USD
    /// @param priceImpactDiffUsd Price impact difference in USD
    /// @param executionPrice Execution price
    struct ExecutionPriceResult {
        int256 priceImpactUsd;
        uint256 priceImpactDiffUsd;
        uint256 executionPrice;
    }

    /// @notice Struct containing position fees
    /// @param referral Referral fees
    /// @param pro Pro fees
    /// @param funding Funding fees
    /// @param borrowing Borrowing fees
    /// @param ui UI fees
    /// @param liquidation Liquidation fees
    /// @param collateralTokenPrice Collateral token price
    /// @param positionFeeFactor Position fee factor
    /// @param protocolFeeAmount Protocol fee amount
    /// @param positionFeeReceiverFactor Position fee receiver factor
    /// @param feeReceiverAmount Fee receiver amount
    /// @param feeAmountForPool Fee amount for pool
    /// @param positionFeeAmountForPool Position fee amount for pool
    /// @param positionFeeAmount Position fee amount
    /// @param totalCostAmountExcludingFunding Total cost amount excluding funding
    /// @param totalCostAmount Total cost amount
    /// @param totalDiscountAmount Total discount amount
    struct PositionFees {
        PositionReferralFees referral;
        PositionProFees pro;
        PositionFundingFees funding;
        PositionBorrowingFees borrowing;
        PositionUiFees ui;
        PositionLiquidationFees liquidation;
        PriceProps collateralTokenPrice;
        uint256 positionFeeFactor;
        uint256 protocolFeeAmount;
        uint256 positionFeeReceiverFactor;
        uint256 feeReceiverAmount;
        uint256 feeAmountForPool;
        uint256 positionFeeAmountForPool;
        uint256 positionFeeAmount;
        uint256 totalCostAmountExcludingFunding;
        uint256 totalCostAmount;
        uint256 totalDiscountAmount;
    }

    /// @notice Struct containing price properties
    /// @param min Minimum price
    /// @param max Maximum price
    struct PriceProps {
        uint256 min;
        uint256 max;
    }

    /// @notice Struct containing pro fees
    /// @param traderTier Trader tier
    /// @param traderDiscountFactor Trader discount factor
    /// @param traderDiscountAmount Trader discount amount
    struct PositionProFees {
        uint256 traderTier;
        uint256 traderDiscountFactor;
        uint256 traderDiscountAmount;
    }

    /// @notice Struct containing liquidation fees
    /// @param liquidationFeeUsd Liquidation fee in USD
    /// @param liquidationFeeAmount Liquidation fee amount
    /// @param liquidationFeeReceiverFactor Liquidation fee receiver factor
    /// @param liquidationFeeAmountForFeeReceiver Liquidation fee amount for fee receiver
    struct PositionLiquidationFees {
        uint256 liquidationFeeUsd;
        uint256 liquidationFeeAmount;
        uint256 liquidationFeeReceiverFactor;
        uint256 liquidationFeeAmountForFeeReceiver;
    }

    /// @notice Struct containing referral fees
    /// @param referralCode Referral code
    /// @param affiliate Affiliate address
    /// @param trader Trader address
    /// @param totalRebateFactor Total rebate factor
    /// @param affiliateRewardFactor Affiliate reward factor
    /// @param adjustedAffiliateRewardFactor Adjusted affiliate reward factor
    /// @param traderDiscountFactor Trader discount factor
    /// @param totalRebateAmount Total rebate amount
    /// @param traderDiscountAmount Trader discount amount
    /// @param affiliateRewardAmount Affiliate reward amount
    struct PositionReferralFees {
        bytes32 referralCode;
        address affiliate;
        address trader;
        uint256 totalRebateFactor;
        uint256 affiliateRewardFactor;
        uint256 adjustedAffiliateRewardFactor;
        uint256 traderDiscountFactor;
        uint256 totalRebateAmount;
        uint256 traderDiscountAmount;
        uint256 affiliateRewardAmount;
    }

    /// @notice Struct containing borrowing fees
    /// @param borrowingFeeUsd Borrowing fee in USD
    /// @param borrowingFeeAmount Borrowing fee amount
    /// @param borrowingFeeReceiverFactor Borrowing fee receiver factor
    /// @param borrowingFeeAmountForFeeReceiver Borrowing fee amount for fee receiver
    struct PositionBorrowingFees {
        uint256 borrowingFeeUsd;
        uint256 borrowingFeeAmount;
        uint256 borrowingFeeReceiverFactor;
        uint256 borrowingFeeAmountForFeeReceiver;
    }

    /// @notice Struct containing funding fees
    /// @param fundingFeeAmount Funding fee amount
    /// @param claimableLongTokenAmount Claimable long token amount
    /// @param claimableShortTokenAmount Claimable short token amount
    /// @param latestFundingFeeAmountPerSize Latest funding fee amount per size
    /// @param latestLongTokenClaimableFundingAmountPerSize Latest long token claimable funding amount per size
    /// @param latestShortTokenClaimableFundingAmountPerSize Latest short token claimable funding amount per size
    struct PositionFundingFees {
        uint256 fundingFeeAmount;
        uint256 claimableLongTokenAmount;
        uint256 claimableShortTokenAmount;
        uint256 latestFundingFeeAmountPerSize;
        uint256 latestLongTokenClaimableFundingAmountPerSize;
        uint256 latestShortTokenClaimableFundingAmountPerSize;
    }

    /// @notice Struct containing UI fees
    /// @param uiFeeReceiver UI fee receiver address
    /// @param uiFeeReceiverFactor UI fee receiver factor
    /// @param uiFeeAmount UI fee amount
    struct PositionUiFees {
        address uiFeeReceiver;
        uint256 uiFeeReceiverFactor;
        uint256 uiFeeAmount;
    }

    /// @notice Struct containing market prices
    /// @param indexTokenPrice Index token price
    /// @param longTokenPrice Long token price
    /// @param shortTokenPrice Short token price
    struct MarketPrices {
        PriceProps indexTokenPrice;
        PriceProps longTokenPrice;
        PriceProps shortTokenPrice;
    }

    /// @notice Get position information
    /// @param dataStore Address of the data store
    /// @param referralStorage Address of the referral storage
    /// @param positionKey Position key
    /// @param prices Market prices
    /// @param sizeDeltaUsd Size delta in USD
    /// @param uiFeeReceiver UI fee receiver address
    /// @param usePositionSizeAsSizeDeltaUsd Whether to use position size as size delta USD
    /// @return Position information
    function getPositionInfo(
        address dataStore,
        address referralStorage,
        bytes32 positionKey,
        MarketPrices memory prices,
        uint256 sizeDeltaUsd,
        address uiFeeReceiver,
        bool usePositionSizeAsSizeDeltaUsd
    ) external view returns (PositionInfo memory);

    /// @notice Get market properties
    /// @param dataStore Address of the data store
    /// @param key Market key
    /// @return Market properties
    function getMarket(IDataStore dataStore, address key) external view returns (MarketProps memory);
}
