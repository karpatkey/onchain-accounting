// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {CappedRateCustomPriceFeed} from "src/prices/CappedRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice Minimal NAV stub exposing only what a CAPO feed reads: base/USD via getPriceData and the rate cap.
contract MockNav {
    INAVCalculator.PriceFeedData internal _pd;
    IPrices.RateCap internal _cap;

    function setBase(int256 price, uint8 dec) external {
        _pd.price = price;
        _pd.decimals = dec;
        _pd.updatedAt = block.timestamp;
        _pd.stale = false;
        _pd.sequencerDown = false;
    }

    function getPriceData(address) external view returns (INAVCalculator.PriceFeedData memory) {
        return _pd;
    }

    function setCap(uint256 maxAprBps, uint256 snapshotRate, uint64 ts) external {
        _cap = IPrices.RateCap(maxAprBps, snapshotRate, ts);
    }

    function getRateCap(address) external view returns (IPrices.RateCap memory) {
        return _cap;
    }
}

/// @notice Settable market feed (base-per-underlying) for the depeg-floor path.
contract SettableMarket {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals;

    constructor(uint8 dec) {
        decimals = dec;
    }

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, updatedAt, 1);
    }
}

/// @notice Concrete CAPO feed with a settable raw rate, to exercise the base cap/floor logic in isolation.
contract MockCappedFeed is CappedRateCustomPriceFeed {
    uint256 public raw;

    constructor(address u, address nav, address base, address market, uint256 hb)
        CappedRateCustomPriceFeed(u, nav, base, market, hb)
    {}

    function setRaw(uint256 r) external {
        raw = r;
    }

    function _rawRate() internal view override returns (uint256) {
        return raw;
    }
}

contract CappedRateCustomPriceFeedTest is Test {
    MockNav internal nav;
    Mock_ERC20 internal underlying;
    Mock_ERC20 internal base;
    MockCappedFeed internal feed; // no market floor

    uint256 internal constant YEAR = 365 days;

    function setUp() public {
        vm.warp(1_000_000);
        nav = new MockNav();
        nav.setBase(2000e8, 8); // ETH/USD = $2000, 8-dec
        underlying = new Mock_ERC20("U", 18);
        base = new Mock_ERC20("B", 18);
        feed = new MockCappedFeed(address(underlying), address(nav), address(base), address(0), 0);
    }

    function _price() internal view returns (uint256 p, bool stale) {
        (p, stale) = feed.getLatestPrice();
    }

    // --- growth cap ---------------------------------------------------------

    function test_unarmed_passesRawThrough() public {
        feed.setRaw(1.1e18); // cap snapshot is 0 → inactive
        (uint256 p, bool stale) = _price();
        assertFalse(stale);
        assertEq(p, 2200e8); // 1.1 × $2000
    }

    function test_growthCap_clampsAJumpedRate() public {
        nav.setCap(1000, 1e18, uint64(block.timestamp)); // 10%/yr from snapshot 1.0
        vm.warp(block.timestamp + YEAR / 2); // half a year → cap = 1.05
        feed.setRaw(1.2e18); // rate "jumps" to 1.2
        (uint256 p,) = _price();
        assertEq(p, 2100e8); // clamped to 1.05 × $2000
    }

    function test_growthCap_belowCap_notClamped() public {
        nav.setCap(1000, 1e18, uint64(block.timestamp));
        vm.warp(block.timestamp + YEAR / 2); // cap = 1.05
        feed.setRaw(1.02e18); // within cap
        (uint256 p,) = _price();
        assertEq(p, 2040e8); // 1.02 × $2000, untouched
    }

    function test_maxAprZero_disablesCap() public {
        nav.setCap(0, 1e18, uint64(block.timestamp)); // armed snapshot but 0 growth allowance = disabled
        feed.setRaw(5e18);
        (uint256 p,) = _price();
        assertEq(p, 10_000e8); // no cap applied
    }

    // --- market floor -------------------------------------------------------

    function test_marketFloor_clampsOnDepeg() public {
        SettableMarket market = new SettableMarket(18);
        market.set(1.0e18, block.timestamp); // market says 1.0 (fundamental will be 1.1 → depeg)
        MockCappedFeed f = new MockCappedFeed(address(underlying), address(nav), address(base), address(market), 3600);
        f.setRaw(1.1e18);
        (uint256 p, bool stale) = f.getLatestPrice();
        assertFalse(stale);
        assertEq(p, 2000e8); // floored to market 1.0 × $2000

        market.set(1.2e18, block.timestamp); // market above fundamental → no floor
        (p,) = f.getLatestPrice();
        assertEq(p, 2200e8); // raw 1.1 × $2000
    }

    function test_marketFloor_failOpen_whenStale() public {
        SettableMarket market = new SettableMarket(18);
        market.set(1.0e18, block.timestamp - 4000); // older than the 3600 heartbeat → skip floor
        MockCappedFeed f = new MockCappedFeed(address(underlying), address(nav), address(base), address(market), 3600);
        f.setRaw(1.1e18);
        (uint256 p,) = f.getLatestPrice();
        assertEq(p, 2200e8); // floor skipped → raw used
    }

    // --- staleness & accessor ----------------------------------------------

    function test_rawZero_marksStale() public {
        feed.setRaw(0);
        (uint256 p, bool stale) = _price();
        assertTrue(stale);
        assertEq(p, 0);
    }

    function test_rawRate_accessor() public {
        feed.setRaw(1.234e18);
        assertEq(feed.rawRate(), 1.234e18);
    }
}
