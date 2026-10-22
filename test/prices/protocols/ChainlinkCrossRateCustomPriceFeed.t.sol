// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ChainlinkCrossRateCustomPriceFeed} from "src/prices/protocols/ChainlinkCrossRateCustomPriceFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {InvalidArguments} from "src/errors.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice A Chainlink mock covering every read path this feed has: a signed (zero / negative) answer, a settable
///         `updatedAt`, a decimals migration, a REVERTING or SHORT-WORD `decimals()`, and a reverting
///         `latestRoundData()` (armed after construction, since the constructor probes it).
contract Mock_CrossRateLegOracle is AggregatorV3Interface {
    enum DecimalsMode {
        Normal,
        Revert,
        Short
    }

    int256 internal _answer;
    uint8 internal _decimals;
    uint256 internal _updatedAt;
    uint80 internal _roundId;
    DecimalsMode internal _decimalsMode;
    bool internal _roundDataReverts;

    constructor(int256 answer_, uint8 decimals_, uint80 roundId_) {
        _answer = answer_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
        _roundId = roundId_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    /// @notice Simulates an aggregator migration that changes the reported decimals.
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setDecimalsMode(DecimalsMode mode) external {
        _decimalsMode = mode;
    }

    function setRoundDataReverts(bool reverts_) external {
        _roundDataReverts = reverts_;
    }

    function decimals() external view override returns (uint8) {
        if (_decimalsMode == DecimalsMode.Revert) revert("decimals: boom");
        if (_decimalsMode == DecimalsMode.Short) {
            // `success` with a 1-byte reply: an ABI decode would revert the caller; probeWord must not.
            assembly {
                mstore(0x00, 0x0800000000000000000000000000000000000000000000000000000000000000)
                return(0x00, 1)
            }
        }
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "X / B";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return this.latestRoundData();
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!_roundDataReverts, "latestRoundData: boom");
        return (_roundId, _answer, _updatedAt - 1, _updatedAt, _roundId);
    }
}

/// @title ChainlinkCrossRateCustomPriceFeed unit tests (no fork)
/// @dev The canonical numbers are the mainnet WBTC values read at block 26_240_000: Chainlink `WBTC / BTC`
///      answered `99816000` (0.99816, 8 dec) and Chainlink `BTC / USD` answered `8312343368270` ($83,123.43, 8 dec).
contract ChainlinkCrossRateCustomPriceFeedTest is Test {
    int256 internal constant RATE = 99_816_000; // 0.99816 WBTC/BTC, 8 dec
    int256 internal constant BASE = 8_312_343_368_270; // $83,123.43368270 BTC/USD, 8 dec
    /// @dev floor(99816000 * 8312343368270 / 1e8) = 8297048656472 — $82,970.48656472 per WBTC.
    uint256 internal constant EXPECTED = 8_297_048_656_472;
    uint256 internal constant RATE_HB = 86_400;
    uint256 internal constant BASE_HB = 3_600;
    uint256 internal constant MIN_R = 0.5e8;
    uint256 internal constant MAX_R = 1.5e8;

    Mock_ERC20 wbtc;
    Mock_CrossRateLegOracle rateFeed;
    Mock_CrossRateLegOracle baseFeed;
    ChainlinkCrossRateCustomPriceFeed oracle;

    function setUp() public {
        // Move off block.timestamp == 1 so "updatedAt in the past" is expressible.
        vm.warp(1_000_000);
        wbtc = new Mock_ERC20("WBTC", 8);
        rateFeed = new Mock_CrossRateLegOracle(RATE, 8, 11);
        baseFeed = new Mock_CrossRateLegOracle(BASE, 8, 22);
        oracle = _deploy(rateFeed, baseFeed, MIN_R, MAX_R);
    }

    function _deploy(Mock_CrossRateLegOracle r, Mock_CrossRateLegOracle b, uint256 minR, uint256 maxR)
        internal
        returns (ChainlinkCrossRateCustomPriceFeed)
    {
        return new ChainlinkCrossRateCustomPriceFeed(
            address(wbtc), address(r), RATE_HB, address(b), BASE_HB, minR, maxR
        );
    }

    function _assertStructuralZero(string memory why) internal view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, why);
        assertTrue(stale, why);
    }

    // --- construction --------------------------------------------------------

    function test_constructor_valid() public view {
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(wbtc));
        assertEq(address(oracle.RATE_FEED()), address(rateFeed));
        assertEq(address(oracle.BASE_USD_FEED()), address(baseFeed));
        assertEq(oracle.RATE_HEARTBEAT(), RATE_HB);
        assertEq(oracle.BASE_HEARTBEAT(), BASE_HB);
        assertEq(oracle.MIN_RATE(), MIN_R);
        assertEq(oracle.MAX_RATE(), MAX_R);
    }

    /// @dev No NAV dependency, declared by the contract — and answerable, which is what registration probes.
    function test_baseAssetIsZero() public view {
        assertEq(oracle.BASE_ASSET(), address(0));
        assertEq(INavSourcedPriceFeed(address(oracle)).BASE_ASSET(), address(0));
    }

    function test_invalidConstructorArgs() public {
        address w = address(wbtc);
        address r = address(rateFeed);
        address b = address(baseFeed);

        vm.expectRevert(); // zero underlying
        new ChainlinkCrossRateCustomPriceFeed(address(0), r, RATE_HB, b, BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // underlying not ERC20-like (an oracle has no totalSupply)
        new ChainlinkCrossRateCustomPriceFeed(r, r, RATE_HB, b, BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // zero rate oracle
        new ChainlinkCrossRateCustomPriceFeed(w, address(0), RATE_HB, b, BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // rate oracle is not a Chainlink oracle
        new ChainlinkCrossRateCustomPriceFeed(w, w, RATE_HB, b, BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // zero rate heartbeat
        new ChainlinkCrossRateCustomPriceFeed(w, r, 0, b, BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // zero base oracle
        new ChainlinkCrossRateCustomPriceFeed(w, r, RATE_HB, address(0), BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // base oracle is not a Chainlink oracle
        new ChainlinkCrossRateCustomPriceFeed(w, r, RATE_HB, w, BASE_HB, MIN_R, MAX_R);
        vm.expectRevert(); // zero base heartbeat
        new ChainlinkCrossRateCustomPriceFeed(w, r, RATE_HB, b, 0, MIN_R, MAX_R);
    }

    function test_invalidBand() public {
        address w = address(wbtc);
        address r = address(rateFeed);
        address b = address(baseFeed);

        vm.expectRevert(InvalidArguments.selector); // zero floor
        new ChainlinkCrossRateCustomPriceFeed(w, r, RATE_HB, b, BASE_HB, 0, MAX_R);
        vm.expectRevert(InvalidArguments.selector); // empty band
        new ChainlinkCrossRateCustomPriceFeed(w, r, RATE_HB, b, BASE_HB, MAX_R, MAX_R);
        vm.expectRevert(InvalidArguments.selector); // inverted band
        new ChainlinkCrossRateCustomPriceFeed(w, r, RATE_HB, b, BASE_HB, MAX_R, MIN_R);
    }

    /// @dev A base feed with fewer than 8 decimals scales the BANDED rate up per read; a ceiling whose scaled value
    ///      cannot fit a uint256 is rejected at construction rather than overflowing on the read path.
    function test_invalidBand_scaledCeilingOverflows() public {
        Mock_CrossRateLegOracle base6 = new Mock_CrossRateLegOracle(83_123e6, 6, 22);
        vm.expectRevert(InvalidArguments.selector);
        new ChainlinkCrossRateCustomPriceFeed(
            address(wbtc), address(rateFeed), RATE_HB, address(base6), BASE_HB, 1, type(uint256).max / 10
        );
    }

    // --- the composition -----------------------------------------------------

    /// @dev THE happy path at the real mainnet answers.
    function test_price_composesTheMainnetWbtcAnswers() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, EXPECTED, "floor(0.99816e8 * 83123.43368270e8 / 1e8)");
        assertEq(price, (uint256(RATE) * uint256(BASE)) / 1e8, "by hand");
    }

    /// @dev An 18-decimal rate leg must cancel exactly like an 8-decimal one.
    function test_price_rate18Decimals() public {
        Mock_CrossRateLegOracle rate18 = new Mock_CrossRateLegOracle(int256(99_816_000) * 1e10, 18, 11);
        ChainlinkCrossRateCustomPriceFeed o = _deploy(rate18, baseFeed, 0.5e18, 1.5e18);
        (uint256 price, bool stale) = o.getLatestPrice();
        assertFalse(stale);
        assertEq(price, EXPECTED, "rate decimals cancel");
    }

    /// @dev An 18-decimal BASE leg is normalised down to NAV_DECIMALS.
    function test_price_base18Decimals() public {
        Mock_CrossRateLegOracle base18 = new Mock_CrossRateLegOracle(BASE * 1e10, 18, 22);
        ChainlinkCrossRateCustomPriceFeed o = _deploy(rateFeed, base18, MIN_R, MAX_R);
        (uint256 price, bool stale) = o.getLatestPrice();
        assertFalse(stale);
        assertEq(price, EXPECTED, "base normalised from 18 to 8 decimals");
    }

    /// @dev Both legs at 18 decimals.
    function test_price_both18Decimals() public {
        Mock_CrossRateLegOracle rate18 = new Mock_CrossRateLegOracle(int256(99_816_000) * 1e10, 18, 11);
        Mock_CrossRateLegOracle base18 = new Mock_CrossRateLegOracle(BASE * 1e10, 18, 22);
        ChainlinkCrossRateCustomPriceFeed o = _deploy(rate18, base18, 0.5e18, 1.5e18);
        (uint256 price,) = o.getLatestPrice();
        assertEq(price, EXPECTED);
    }

    /// @dev A base leg with FEWER than 8 decimals is scaled up (no precision lost: the scale-up is exact).
    function test_price_base6Decimals() public {
        Mock_CrossRateLegOracle base6 = new Mock_CrossRateLegOracle(83_123_433_682, 6, 22); // $83,123.433682
        ChainlinkCrossRateCustomPriceFeed o = _deploy(rateFeed, base6, MIN_R, MAX_R);
        (uint256 price, bool stale) = o.getLatestPrice();
        assertFalse(stale);
        assertEq(price, (uint256(RATE) * 83_123_433_682 * 100) / 1e8, "base scaled from 6 to 8 decimals");
    }

    /// @dev Unity rate passes the base price through unchanged.
    function test_price_unityRateIsBasePrice() public {
        rateFeed.setAnswer(1e8);
        (uint256 price,) = oracle.getLatestPrice();
        assertEq(price, uint256(BASE));
    }

    /// @dev Exact floor of the product over the whole band, at any positive 8-decimal base price.
    function testFuzz_price_isExactFloor(uint256 rate, uint256 base) public {
        rate = bound(rate, MIN_R, MAX_R);
        base = bound(base, 1, uint256(type(int256).max));
        rateFeed.setAnswer(int256(rate));
        baseFeed.setAnswer(int256(base));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        // No overflow anywhere, even at an int256-max base: the product is taken in 512 bits.
        if (base <= type(uint256).max / rate) assertEq(price, rate * base / 1e8, "floor(rate * base / 1e8)");
        else assertGt(price, 0);
    }

    // --- structural failures: (0, true) --------------------------------------

    function test_structural_rateZero() public {
        rateFeed.setAnswer(0);
        _assertStructuralZero("rate == 0");
    }

    function test_structural_rateNegative() public {
        rateFeed.setAnswer(-1);
        _assertStructuralZero("rate < 0");
    }

    function test_structural_baseZero() public {
        baseFeed.setAnswer(0);
        _assertStructuralZero("base == 0");
    }

    function test_structural_baseNegative() public {
        baseFeed.setAnswer(-1e8);
        _assertStructuralZero("base < 0");
    }

    function test_structural_rateDecimalsChanged() public {
        rateFeed.setDecimals(6);
        _assertStructuralZero("rate decimals 8 -> 6");
    }

    function test_structural_baseDecimalsChanged() public {
        baseFeed.setDecimals(18);
        _assertStructuralZero("base decimals 8 -> 18 would over-report 1e10x");
    }

    function test_structural_rateDecimalsReverts() public {
        rateFeed.setDecimalsMode(Mock_CrossRateLegOracle.DecimalsMode.Revert);
        _assertStructuralZero("rate decimals() reverts");
    }

    function test_structural_baseDecimalsShortWord() public {
        baseFeed.setDecimalsMode(Mock_CrossRateLegOracle.DecimalsMode.Short);
        _assertStructuralZero("base decimals() returns a short word");
    }

    function test_structural_rateBelowBand() public {
        rateFeed.setAnswer(int256(MIN_R) - 1);
        _assertStructuralZero("rate below MIN_RATE");
    }

    function test_structural_rateAboveBand() public {
        rateFeed.setAnswer(int256(MAX_R) + 1);
        _assertStructuralZero("rate above MAX_RATE");
    }

    /// @dev A re-pointed aggregator quoting BTC/USD on the rate leg lands far outside the band.
    function test_structural_rateRequotedAsUsdPrice() public {
        rateFeed.setAnswer(BASE);
        _assertStructuralZero("rate leg re-quoted to BTC / USD");
    }

    function test_band_isInclusive() public {
        rateFeed.setAnswer(int256(MIN_R));
        (uint256 p1, bool s1) = oracle.getLatestPrice();
        assertFalse(s1);
        assertEq(p1, MIN_R * uint256(BASE) / 1e8);
        rateFeed.setAnswer(int256(MAX_R));
        (uint256 p2, bool s2) = oracle.getLatestPrice();
        assertFalse(s2);
        assertEq(p2, MAX_R * uint256(BASE) / 1e8);
    }

    /// @dev A structural failure still reports the OLDER leg's timestamp, never block.timestamp.
    function test_structural_keepsMinUpdatedAt() public {
        baseFeed.setUpdatedAt(block.timestamp - 100);
        rateFeed.setAnswer(0);
        (,,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 100);
    }

    // --- staleness (ADR 0029): carried, never zeroed --------------------------

    function test_stale_rateLegCarriesPrice() public {
        rateFeed.setUpdatedAt(block.timestamp - RATE_HB);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "rate age == heartbeat is stale");
        assertEq(price, EXPECTED, "stale rate leg keeps the exact price");
    }

    function test_stale_baseLegCarriesPrice() public {
        baseFeed.setUpdatedAt(block.timestamp - BASE_HB);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "base age == heartbeat is stale");
        assertEq(price, EXPECTED, "stale base leg keeps the exact price");
    }

    function test_fresh_justInsideBothHeartbeats() public {
        rateFeed.setUpdatedAt(block.timestamp - RATE_HB + 1);
        baseFeed.setUpdatedAt(block.timestamp - BASE_HB + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, EXPECTED);
    }

    /// @dev Each leg is aged against its OWN heartbeat: a base leg 2h old is stale even though it is well within the
    ///      rate leg's 24h.
    function test_stale_eachLegItsOwnHeartbeat() public {
        baseFeed.setUpdatedAt(block.timestamp - 2 hours);
        (, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
    }

    /// @dev An upstream clock ahead of ours counts as age 0, not as an underflow.
    function test_futureTimestamp_isFresh() public {
        rateFeed.setUpdatedAt(block.timestamp + 50);
        baseFeed.setUpdatedAt(block.timestamp + 10);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, EXPECTED);
    }

    function test_updatedAt_isMinOfLegs() public {
        rateFeed.setUpdatedAt(block.timestamp - 500);
        baseFeed.setUpdatedAt(block.timestamp - 20);
        (,,, uint256 u1,) = oracle.latestRoundData();
        assertEq(u1, block.timestamp - 500, "rate leg older");

        rateFeed.setUpdatedAt(block.timestamp - 5);
        baseFeed.setUpdatedAt(block.timestamp - 3000);
        (,,, uint256 u2,) = oracle.latestRoundData();
        assertEq(u2, block.timestamp - 3000, "base leg older");
    }

    // --- latestRoundData -----------------------------------------------------

    function test_latestRoundData_freshAnswersPrice() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        assertEq(answer, int256(EXPECTED));
        assertEq(roundId, 11, "rate leg's roundId");
        assertEq(answeredInRound, 11, "rate leg's answeredInRound");
        assertEq(startedAt, block.timestamp - 1, "rate leg's startedAt");
        assertEq(updatedAt, block.timestamp);
    }

    function test_latestRoundData_staleAnswersZero() public {
        baseFeed.setUpdatedAt(block.timestamp - BASE_HB);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, 0, "stale -> 0 for Chainlink-ABI readers");
        assertEq(updatedAt, block.timestamp - BASE_HB, "still the older leg's timestamp");
    }

    // --- governingFeedFreshness ----------------------------------------------

    /// @dev Rate leg at 50% of its 24h, base at 10% of its 1h → the rate leg governs.
    function test_governing_rateLegHasLargerRatio() public {
        rateFeed.setUpdatedAt(block.timestamp - RATE_HB / 2);
        baseFeed.setUpdatedAt(block.timestamp - BASE_HB / 10);
        (uint256 u, uint256 hb) = oracle.governingFeedFreshness();
        assertEq(u, block.timestamp - RATE_HB / 2);
        assertEq(hb, RATE_HB);
    }

    /// @dev Base leg at 90% of its 1h, rate at 10% of its 24h → the base leg governs despite being younger.
    function test_governing_baseLegHasLargerRatio() public {
        rateFeed.setUpdatedAt(block.timestamp - RATE_HB / 10);
        baseFeed.setUpdatedAt(block.timestamp - (BASE_HB * 9) / 10);
        (uint256 u, uint256 hb) = oracle.governingFeedFreshness();
        assertEq(u, block.timestamp - (BASE_HB * 9) / 10);
        assertEq(hb, BASE_HB);
    }

    /// @dev A leg whose `latestRoundData()` reverts makes the read revert (no silent 0, no stale price); the NAV's
    ///      try/catch around `getLatestPrice` then treats the feed as unusable.
    function test_revertingLeg_revertsRead() public {
        rateFeed.setRoundDataReverts(true);
        vm.expectRevert();
        oracle.getLatestPrice();
        rateFeed.setRoundDataReverts(false);
        baseFeed.setRoundDataReverts(true);
        vm.expectRevert();
        oracle.getLatestPrice();
    }

    function test_governing_rateUnreadableReportsBase() public {
        baseFeed.setUpdatedAt(block.timestamp - 7);
        rateFeed.setRoundDataReverts(true);
        (uint256 u, uint256 hb) = oracle.governingFeedFreshness();
        assertEq(u, block.timestamp - 7);
        assertEq(hb, BASE_HB);
    }

    function test_governing_baseUnreadableReportsRate() public {
        rateFeed.setUpdatedAt(block.timestamp - 9);
        baseFeed.setRoundDataReverts(true);
        (uint256 u, uint256 hb) = oracle.governingFeedFreshness();
        assertEq(u, block.timestamp - 9);
        assertEq(hb, RATE_HB);
    }

    function test_governing_bothUnreadable() public {
        rateFeed.setRoundDataReverts(true);
        baseFeed.setRoundDataReverts(true);
        (uint256 u, uint256 hb) = oracle.governingFeedFreshness();
        assertEq(u, 0, "no push timestamp");
        assertEq(hb, RATE_HB);
    }

    /// @dev A `type(uint256).max` heartbeat (the "gate disabled" sentinel) must not overflow the ratio compare.
    function test_governing_maxHeartbeatDoesNotOverflow() public {
        ChainlinkCrossRateCustomPriceFeed o = new ChainlinkCrossRateCustomPriceFeed(
            address(wbtc), address(rateFeed), type(uint256).max, address(baseFeed), BASE_HB, MIN_R, MAX_R
        );
        rateFeed.setUpdatedAt(block.timestamp - 1000);
        baseFeed.setUpdatedAt(block.timestamp - 10);
        (uint256 u, uint256 hb) = o.governingFeedFreshness();
        assertEq(u, block.timestamp - 10, "the finite-heartbeat leg governs");
        assertEq(hb, BASE_HB);
    }

    // --- interface -----------------------------------------------------------

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(ICustomPriceFeed).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0xffffffff));
    }
}
