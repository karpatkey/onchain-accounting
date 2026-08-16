// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {InvertedChainlinkCustomPriceFeed} from "src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";

/// @notice A Chainlink mock whose answer may be zero or NEGATIVE. `Mock_PriceOracleChainlink` stores its
///         price as `uint256`, so it cannot express the negative-answer case this feed must survive —
///         and a negative answer reaching `uint256(answer)` would be catastrophic, not merely wrong.
contract Mock_SignedChainlinkOracle is AggregatorV3Interface {
    int256 internal _answer;
    uint8 internal _decimals;
    uint256 internal _updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    /// @notice Simulates an aggregator migration that changes reported decimals.
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "USD / X";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (7, _answer, 5, _updatedAt, 7);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (7, _answer, 5, _updatedAt, 7);
    }
}

/// @notice A Chainlink mock that always reverts, to drive `governingFeedFreshness`'s catch arm.
contract Mock_RevertingChainlinkOracle is AggregatorV3Interface {
    bool internal armed; // constructor-time probe must succeed; arm it afterwards

    function arm() external {
        armed = true;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "USD / X";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return this.latestRoundData();
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!armed, "boom");
        return (1, 1e8, 0, block.timestamp, 1);
    }
}

/// @title InvertedChainlinkCustomPriceFeed unit tests (no fork)
/// @dev The real ARS numbers used below are the ones measured on mainnet 2026-08-15 from
///      `0xBb65fa58BDb7d33e4a3D1A40a7A9BD99E746367b` (`description() == "USD / ARS"`, 8 decimals,
///      `answer == 158309760000`). They are the reason this contract exists, so they are pinned as the
///      canonical case rather than a round number.
contract InvertedChainlinkCustomPriceFeedTest is Test {
    /// @dev Mainnet USD/ARS answer at 8 decimals — 1583.0976 ARS per USD.
    int256 internal constant ARS_ANSWER = 158309760000;
    /// @dev floor(1e8 * 1e8 / 158309760000) — $0.00063167 per wARS.
    uint256 internal constant ARS_EXPECTED_PRICE = 63167;
    uint256 internal constant HEARTBEAT = 90000; // declared 86400 + 1h margin
    uint256 internal constant MIN_A = 100e8; // the runtime direction band, feed decimals
    uint256 internal constant MAX_A = 100000e8;

    Mock_ERC20 wars;
    Mock_SignedChainlinkOracle feed;
    InvertedChainlinkCustomPriceFeed oracle;

    function setUp() public {
        // Move off block.timestamp == 1 so "updatedAt in the past" is expressible.
        vm.warp(1_000_000);
        wars = new Mock_ERC20("wARS", 18);
        feed = new Mock_SignedChainlinkOracle(ARS_ANSWER, 8);
        oracle = new InvertedChainlinkCustomPriceFeed(address(wars), address(feed), HEARTBEAT, MIN_A, MAX_A);
    }

    // --- construction --------------------------------------------------------

    function test_constructor_valid() public view {
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(wars));
        assertEq(address(oracle.USD_TO_ASSET_FEED()), address(feed));
        assertEq(oracle.FEED_HEARTBEAT(), HEARTBEAT);
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert(); // zero underlying
        new InvertedChainlinkCustomPriceFeed(address(0), address(feed), HEARTBEAT, MIN_A, MAX_A);

        vm.expectRevert(); // underlying not ERC20-like (feed has no totalSupply)
        new InvertedChainlinkCustomPriceFeed(address(feed), address(feed), HEARTBEAT, MIN_A, MAX_A);

        vm.expectRevert(); // zero oracle
        new InvertedChainlinkCustomPriceFeed(address(wars), address(0), HEARTBEAT, MIN_A, MAX_A);

        vm.expectRevert(); // oracle is not a Chainlink oracle
        new InvertedChainlinkCustomPriceFeed(address(wars), address(wars), HEARTBEAT, MIN_A, MAX_A);

        vm.expectRevert(); // zero heartbeat
        new InvertedChainlinkCustomPriceFeed(address(wars), address(feed), 0, MIN_A, MAX_A);
    }

    // --- the inversion itself ------------------------------------------------

    /// @dev THE test: the mainnet ARS answer must invert to $0.00063167, NOT to $1583.
    function test_price_invertsTheMainnetArsAnswer() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertEq(price, ARS_EXPECTED_PRICE, "1e8 * 1e8 / 158309760000");
        // Guard the whole point of the contract: the price must be the reciprocal, not the raw answer.
        assertLt(price, 1e8, "wARS is worth far less than $1");
        assertTrue(price != uint256(ARS_ANSWER), "must not pass the raw USD/ARS answer through");
    }

    /// @dev Unity check: at 1 X per USD the price must be exactly $1 (1e8), for any feed decimals.
    /// @dev Uses its own band: MIN/MAX_ANSWER are in the FEED's decimals, and the ARS band (100e8..100000e8)
    ///      deliberately excludes unity — a 1-per-USD answer is not a plausible ARS rate.
    function test_price_unityAnswerGivesOneDollar() public {
        Mock_SignedChainlinkOracle f = new Mock_SignedChainlinkOracle(1e8, 8);
        InvertedChainlinkCustomPriceFeed o =
            new InvertedChainlinkCustomPriceFeed(address(wars), address(f), HEARTBEAT, 1, 1e18);
        (uint256 price, bool stale) = o.getLatestPrice();
        assertFalse(stale);
        assertEq(price, 1e8, "1 X per USD => $1.00");
    }

    /// @dev The feed's own decimals must cancel — an 18-decimal USD/X feed at unity is still $1.
    function test_price_feedDecimalsCancel() public {
        Mock_SignedChainlinkOracle feed18 = new Mock_SignedChainlinkOracle(1e18, 18);
        // Band in the 18-decimal feed's OWN units — that is what MIN/MAX_ANSWER are denominated in.
        InvertedChainlinkCustomPriceFeed o18 =
            new InvertedChainlinkCustomPriceFeed(address(wars), address(feed18), HEARTBEAT, 1, type(uint256).max - 1);
        (uint256 price, bool stale) = o18.getLatestPrice();
        assertFalse(stale);
        assertEq(price, 1e8, "feed decimals cancel out");
    }

    /// @dev Inverting twice must return to the original. The bound is DERIVED, not picked: flooring the
    ///      forward inversion loses at most one unit of `price`, and re-inverting magnifies that by
    ///      `answer / price` (here 1e16/63167^2), so the round-trip error is bounded by
    ///      `backToAnswer / price + 1`. At the mainnet ARS answer that is ~2.51e6, and the measured error
    ///      is 750,234 — inside it. An earlier version of this test used a flat 1e8, which is ~133x the
    ///      real error and would have passed even if the inversion were substantially wrong.
    function test_price_roundTripsWithinOneUnit() public {
        feed.setAnswer(ARS_ANSWER);
        (uint256 price,) = oracle.getLatestPrice();
        // price = 1e16 / answer  =>  answer ~= 1e16 / price
        uint256 backToAnswer = 1e16 / price;
        uint256 bound = backToAnswer / price + 1; // exact floor-propagation bound, not a magic number
        assertApproxEqAbs(backToAnswer, uint256(ARS_ANSWER), bound, "round trip within the floor bound");
    }

    /// @dev Rounding is Floor, so the result never exceeds the exact value.
    /// @dev Bounded to the configured band: outside it the feed reports stale by design, so the Floor
    ///      invariant is only meaningful inside.
    function testFuzz_price_neverExceedsExact(int256 answer) public {
        answer = int256(bound(answer, int256(MIN_A), int256(MAX_A)));
        feed.setAnswer(answer);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        assertLe(price, (1e8 * 1e8) / uint256(answer), "Floor: never above exact");
    }

    /// @dev **The over-report this contract's cached-unit guard exists to stop.** `_feedUnit` is a
    ///      NUMERATOR here, so an aggregator migrating 8 -> 6 decimals while publishing the SAME real rate
    ///      would inflate the price by exactly 100x with `stale == false` — the opposite of the safe
    ///      direction every sibling feed fails in. Without the per-read decimals re-assertion this test
    ///      reads 6316729 instead of 63167 and passes silently.
    function test_feedDecimalsMigration_isStaleNotA100xOverReport() public {
        (uint256 before, bool staleBefore) = oracle.getLatestPrice();
        assertFalse(staleBefore);
        assertEq(before, ARS_EXPECTED_PRICE);

        // Same real rate, two fewer decimals: 1583.0976 ARS/USD at 6dp.
        feed.setDecimals(6);
        feed.setAnswer(1583097600);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "decimals migration must report STALE");
        assertEq(price, 0, "and must not report the 100x-inflated 6316729");
    }

    /// @dev **A revert inside a `try` BODY is not caught by that statement's own `catch`.** The first
    ///      version of the decimals guard recomputed `10 ** uint256(liveDecimals)` to compare units, which
    ///      REVERTS for any `liveDecimals >= 78` (10**78 exceeds uint256) — turning a hostile or broken
    ///      aggregator into a whole-feed revert, the one failure mode {ICustomPriceFeed} forbids. Comparing
    ///      the `uint8` directly cannot overflow. 255 is the worst case an aggregator can return.
    function test_absurdDecimals_isStaleNotRevert() public {
        feed.setDecimals(255);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "absurd decimals => stale");
        assertEq(price, 0);

        // And the whole ICustomPriceFeed surface must stay callable, not revert.
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 0, "latestRoundData still answers, zeroed");
        (uint256 u, uint256 hb) = oracle.governingFeedFreshness();
        assertEq(hb, HEARTBEAT);
        assertGt(u, 0);
    }

    /// @dev An unreadable `decimals()` is equally unsafe to trust, since the cached unit can no longer be
    ///      confirmed. Reported stale rather than assumed unchanged.
    function test_unreadableDecimals_isStale() public {
        vm.mockCallRevert(address(feed), abi.encodeWithSignature("decimals()"), "boom");
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "unreadable decimals => stale");
        assertEq(price, 0);
    }

    /// @dev **`try/catch` catches a REVERT but not a DECODE failure.** An aggregator answering `success`
    ///      with a short or out-of-range word is exactly the shape the earlier `try/catch` form let through
    ///      into a frame-level revert. `probeWord` is total over any returndata, so all of these land on
    ///      the stale path instead.
    function test_undecodableDecimals_isStaleNotRevert() public {
        // success + EMPTY returndata: no revert to catch, and nothing to decode.
        vm.mockCall(address(feed), abi.encodeWithSignature("decimals()"), "");
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "empty returndata => stale");
        assertEq(price, 0);
        vm.clearMockedCalls();

        // success + a word far outside uint8: decodes as a dirty value, must not be trusted.
        vm.mockCall(address(feed), abi.encodeWithSignature("decimals()"), abi.encode(uint256(300)));
        (price, stale) = oracle.getLatestPrice();
        assertTrue(stale, "out-of-range decimals word => stale");
        assertEq(price, 0);
    }

    /// @dev **The direction pin at READ time.** `RateFeedGuard` pins `description()` and this same band
    ///      but is deploy-only, so it cannot see a Chainlink proxy that later migrates its aggregator at
    ///      the same address with the same decimals. An `X / USD` re-quote answers ~67207 here — four
    ///      orders BELOW the floor — so the band catches what `decimals()` cannot. Without it the feed
    ///      would report ~$1,583 instead of ~$0.00063 with `stale == false`, on an immutable contract.
    function test_answerBelowBand_isStale_theInvertedRequoteCase() public {
        feed.setAnswer(67207); // exactly what the real ARS/USD feed answers
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "an ARS/USD re-quote must report stale, not a 2.5-million-x over-report");
        assertEq(price, 0);
    }

    function test_answerAboveBand_isStale() public {
        feed.setAnswer(int256(MAX_A) + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_bandBoundsAreInclusive() public {
        feed.setAnswer(int256(MIN_A));
        (, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "MIN_ANSWER is inclusive");
        feed.setAnswer(int256(MAX_A));
        (, stale) = oracle.getLatestPrice();
        assertFalse(stale, "MAX_ANSWER is inclusive");
    }

    function test_invalidBand_reverts() public {
        vm.expectRevert(); // zero floor
        new InvertedChainlinkCustomPriceFeed(address(wars), address(feed), HEARTBEAT, 0, MAX_A);
        vm.expectRevert(); // max <= min
        new InvertedChainlinkCustomPriceFeed(address(wars), address(feed), HEARTBEAT, MAX_A, MIN_A);
    }

    // --- staleness and bad answers -------------------------------------------

    /// @dev A zero answer must report STALE, not revert — mulDiv by zero would revert in-frame.
    function test_zeroAnswer_isStaleNotRevert() public {
        feed.setAnswer(0);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "zero answer => stale");
        assertEq(price, 0);
    }

    /// @dev A negative answer must report STALE. Casting it to uint256 would produce an astronomic price.
    function test_negativeAnswer_isStale() public {
        feed.setAnswer(-1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "negative answer => stale");
        assertEq(price, 0);
    }

    function test_stale_atAndBeyondHeartbeat() public {
        // Exactly at the heartbeat is already stale (>= boundary).
        feed.setUpdatedAt(block.timestamp - HEARTBEAT);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale, "age == heartbeat => stale");
        assertEq(price, 0);

        // One second inside the window is fresh.
        feed.setUpdatedAt(block.timestamp - (HEARTBEAT - 1));
        (price, stale) = oracle.getLatestPrice();
        assertFalse(stale, "age == heartbeat - 1 => fresh");
        assertEq(price, ARS_EXPECTED_PRICE);
    }

    /// @dev An upstream clock ahead of ours must not underflow the age subtraction.
    function test_futureUpdatedAt_doesNotUnderflow() public {
        feed.setUpdatedAt(block.timestamp + 10_000);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "future timestamp clamps to now, age 0");
        assertEq(price, ARS_EXPECTED_PRICE);
    }

    // --- interface surface ---------------------------------------------------

    function test_latestRoundData_passesThroughAndZeroesOnStale() public {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        assertEq(roundId, 7, "roundId from the underlying leg");
        assertEq(startedAt, 5, "startedAt from the underlying leg");
        assertEq(answeredInRound, 7);
        assertEq(updatedAt, block.timestamp);
        assertEq(answer, int256(ARS_EXPECTED_PRICE), "answer is the INVERTED price");

        // When stale, the answer is zeroed but the round metadata still passes through.
        feed.setAnswer(0);
        (roundId, answer,, updatedAt,) = oracle.latestRoundData();
        assertEq(answer, 0, "stale => zero answer");
        assertEq(roundId, 7, "metadata still reported");
        assertEq(updatedAt, block.timestamp);
    }

    function test_governingFeedFreshness_reportsTheSingleLeg() public {
        feed.setUpdatedAt(block.timestamp - 100);
        (uint256 updatedAt, uint256 heartbeat) = oracle.governingFeedFreshness();
        assertEq(updatedAt, block.timestamp - 100);
        assertEq(heartbeat, HEARTBEAT);
    }

    function test_governingFeedFreshness_unreadableLegReportsZeroTimestamp() public {
        Mock_RevertingChainlinkOracle bad = new Mock_RevertingChainlinkOracle();
        InvertedChainlinkCustomPriceFeed o =
            new InvertedChainlinkCustomPriceFeed(address(wars), address(bad), HEARTBEAT, MIN_A, MAX_A);
        bad.arm(); // only after construction — the constructor probes latestRoundData()
        (uint256 updatedAt, uint256 heartbeat) = o.governingFeedFreshness();
        assertEq(updatedAt, 0, "unreadable leg => 0 (documented no-timestamp value)");
        assertEq(heartbeat, HEARTBEAT);
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(ICustomPriceFeed).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }
}
