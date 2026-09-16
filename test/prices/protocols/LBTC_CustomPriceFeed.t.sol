// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LBTC_CustomPriceFeed} from "src/prices/protocols/LBTC_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title LBTC_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (WBTC/USD) comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(lbtc, nav, baseAsset)`. Price math against the live Lombard rate is exercised in the fork test.
contract LBTC_CustomPriceFeedTest is Test {
    Mock_ERC20 lbtc;
    Mock_ERC20 wbtc;
    Mock_NAVCalculator nav;

    function setUp() public {
        lbtc = new Mock_ERC20("LBTC", 8);
        wbtc = new Mock_ERC20("WBTC", 8);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(wbtc), 76_000e8, 8); // BTC/USD = $76,000
    }

    function test_constructor_valid() public {
        LBTC_CustomPriceFeed oracle = new LBTC_CustomPriceFeed(address(lbtc), address(nav), address(wbtc));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(lbtc));
    }

    function test_invalidConstructorArgs() public {
        // zero underlying
        vm.expectRevert();
        new LBTC_CustomPriceFeed(address(0), address(nav), address(wbtc));

        // zero nav (not a contract)
        vm.expectRevert();
        new LBTC_CustomPriceFeed(address(lbtc), address(0), address(wbtc));

        // zero base asset
        vm.expectRevert();
        new LBTC_CustomPriceFeed(address(lbtc), address(nav), address(0));
    }

    /// @notice The rate is an 18-dec multiplier over the base, independent of the 8-dec tokens either side.
    /// @dev This is the scaling most at risk here: LBTC and WBTC are both 8-decimal, while `getRate()` is
    ///      18-decimal, so a feed that confused token decimals for rate decimals would be wrong by 1e10 and
    ///      still look superficially plausible. Pinned at a rate of exactly 1.0 and at a 0.5% premium.
    function test_rateScalesTheBasePrice() public {
        vm.mockCall(address(lbtc), abi.encodeWithSignature("getRate()"), abi.encode(uint256(1e18)));
        LBTC_CustomPriceFeed atPar = new LBTC_CustomPriceFeed(address(lbtc), address(nav), address(wbtc));
        (uint256 parPrice,) = atPar.getLatestPrice();
        assertEq(parPrice, 76_000e8, "rate 1.0 => LBTC/USD == BTC/USD");

        vm.mockCall(address(lbtc), abi.encodeWithSignature("getRate()"), abi.encode(uint256(1005e15)));
        (uint256 premiumPrice,) = atPar.getLatestPrice();
        assertEq(premiumPrice, 76_380e8, "rate 1.005 => 1.005 x BTC/USD");
    }

    /// @notice A zero rate must not be published as a zero price.
    /// @dev `BaseCustomPriceFeed` treats a zero rate as stale rather than reporting $0, which matters because a
    ///      consumer that gates on `stale` refuses the read instead of valuing the position at nothing.
    function test_zeroRateIsStaleNotZero() public {
        vm.mockCall(address(lbtc), abi.encodeWithSignature("getRate()"), abi.encode(uint256(0)));
        LBTC_CustomPriceFeed oracle = new LBTC_CustomPriceFeed(address(lbtc), address(nav), address(wbtc));
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "no price when the rate is unreadable");
        assertTrue(stale, "a zero rate must surface as stale, not as a $0 valuation");
    }
}
