// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {osToken_CustomPriceFeed} from "src/prices/protocols/osToken_CustomPriceFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal StakeWise OsTokenVaultController mock — returns a settable osToken→underlying rate.
contract Mock_OsTokenVaultController {
    uint256 public rate; // assets per 1e18 shares

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }
}

/// @title osToken_CustomPriceFeed unit tests (no fork)
/// @notice Exercises the generic osToken price math (`convertToAssets(1e18) * underlying/USD / 1e18`), staleness,
///         and the ICustomPriceFeed surface, using a mock controller + a Mock_NAVCalculator for the base/USD price.
/// @dev Base/USD (ETH/USD) now comes from the NAV; the constructor takes `(osToken, controller, nav, baseAsset)`.
contract osToken_CustomPriceFeedTest is Test {
    Mock_ERC20 osToken;
    Mock_ERC20 weth; // underlying / base asset priced by the NAV
    Mock_OsTokenVaultController controller;
    Mock_NAVCalculator nav;
    osToken_CustomPriceFeed oracle;

    uint256 constant RATE = 1.072e18; // 1 osETH = 1.072 ETH
    int256 constant USD = 3000e8; // ETH/USD = $3000 (8 decimals)

    function setUp() public {
        vm.warp(1_000_000); // non-zero base time
        osToken = new Mock_ERC20("osETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        controller = new Mock_OsTokenVaultController(RATE);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), USD, 8);
        oracle = new osToken_CustomPriceFeed(address(osToken), address(controller), address(nav), address(weth));
    }

    function test_price() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale);
        // 1.072e18 * 3000e8 / 1e18 = 3216e8 = $3216 (8 decimals)
        assertEq(price, RATE * uint256(USD) / 1e18);
        assertEq(price, 3216e8);
    }

    function test_metadata() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.underlyingAssetSupported(), address(osToken));
        assertTrue(oracle.supportsInterface(type(ICustomPriceFeed).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_latestRoundData_matchesPrice() public view {
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(uint256(answer), RATE * uint256(USD) / 1e18);
    }

    function test_stale_whenBaseStale() public {
        nav.setAssetStale(address(weth), true);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 0, "stale returns answer 0");
    }

    function test_stale_whenUsdNonPositive() public {
        nav.setAssetPrice(address(weth), 0, 8); // base price 0 → NavBaseUsdLib reports stale
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_stale_whenRateZero() public {
        controller.setRate(0);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    function test_invalidConstructorArgs() public {
        // zero osToken
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(0), address(controller), address(nav), address(weth));

        // zero controller (not a contract)
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(0), address(nav), address(weth));

        // controller not a contract
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(0xdead), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(controller), address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(controller), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new osToken_CustomPriceFeed(address(osToken), address(controller), address(nav), address(nav));
    }
}
