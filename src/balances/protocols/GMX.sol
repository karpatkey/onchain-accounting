// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "src/errors.sol";

/// @title GMX
/// @notice Balance oracle for GMX synthetic positions
contract GmxBalanceOracle is IBalanceOracleCustom {
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

    /// @notice Position tags associated with the balance oracle.
    PositionMetadata internal _positionMetadata;

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
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(
        address market_,
        address reader_,
        address referralStorage_,
        address usdc_,
        address collateralToken_,
        bool isLong_,
        TokenFeed[] memory tokenFeeds_,
        PositionMetadata memory positionMetadata_
    ) {
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

        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
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
    function balanceOf(address underlyingAsset, address safe) external view returns (int256) {
        if (underlyingAsset == address(0) || safe == address(0)) {
            return 0;
        }

        IGMXReader.MarketPrices[] memory marketPrices = getMarketPrices();

        IGMXReader.PositionInfo memory positionInfo =
            getPositionInfo(safe, GMX_MARKET, COLLATERAL_TOKEN, IS_LONG, marketPrices);

        int256 total = 0;

        if (underlyingAsset == address(USDC)) {
            (uint256 usdcPrice, uint256 oracleDecimals) = getPrice(underlyingAsset);
            uint256 usdPriceScaled =
                positionInfo.position.numbers.sizeInUsd / (10 ** (FLOAT_PRECISION_DECIMALS - oracleDecimals));

            int256 sizeInUSDC = usdPriceScaled.mulDiv(10 ** USDC.decimals(), usdcPrice, Math.Rounding.Floor).toInt256();

            if (IS_LONG) {
                total -= sizeInUSDC;
            } else {
                total += sizeInUSDC;
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

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = address(0); // FIXME
        return assets;
    }

    /// @inheritdoc IBalanceOracleCustom
    function positionMetadata() external view override returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
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
