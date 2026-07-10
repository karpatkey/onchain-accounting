// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sDAI_CustomPriceFeed} from "src/prices/protocols/sDAI_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal Maker DSR Pot mock exposing `chi` (RAY, 27 decimals).
contract Mock_Pot {
    function chi() external pure returns (uint256) {
        return 1e27; // 1.0 in RAY
    }
}

/// @notice Minimal Maker DsrManager mock exposing `pot()`.
contract Mock_DsrManager {
    address public immutable POT;

    constructor() {
        POT = address(new Mock_Pot());
    }

    function pot() external view returns (address) {
        return POT;
    }
}

/// @title sDAI_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (DAI/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(sDai, dsrManager, nav, baseAsset)`. Price math (chi) is exercised in the fork test.
contract sDAI_CustomPriceFeedTest is Test {
    Mock_ERC20 sDai;
    Mock_ERC20 dai;
    Mock_DsrManager dsrManager;
    Mock_NAVCalculator nav;

    function setUp() public {
        sDai = new Mock_ERC20("sDAI", 18);
        dai = new Mock_ERC20("DAI", 18);
        dsrManager = new Mock_DsrManager();
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(dai), 1e8, 8); // DAI/USD = $1
    }

    function test_constructor_valid() public {
        sDAI_CustomPriceFeed oracle =
            new sDAI_CustomPriceFeed(address(sDai), address(dsrManager), address(nav), address(dai));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(sDai));
    }

    function test_invalidConstructorArgs() public {
        // zero sDAI
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(0), address(dsrManager), address(nav), address(dai));

        // zero dsrManager
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(0), address(nav), address(dai));

        // dsrManager not a DSR manager (pot() reverts)
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(nav), address(nav), address(dai));

        // zero nav (not a contract)
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(dsrManager), address(0), address(dai));

        // zero base asset
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(dsrManager), address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(sDai), address(dsrManager), address(nav), address(nav));
    }
}
