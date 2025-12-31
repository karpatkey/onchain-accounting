// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SkySavingsUsdsBalanceOracle} from "src/balances/protocols/SkySavingsUsds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import "src/errors.sol";

contract SavingsUSDSTest is Test {
    IERC4626 public constant SAVINGS_USDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    IERC20 public constant USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    address public constant TEST_USER = 0x7F311a4D48377030bD810395f4CCfC03bdbe9Ef3;
    uint256 public constant FORK_BLOCK = 21_378_910;

    uint256 public fork;
    SkySavingsUsdsBalanceOracle public oracle;
    IBalanceOracleCustom.PositionMetadata positionMetadata =
        IBalanceOracleCustom.PositionMetadata({protocol: "Sky", position: "SavingsUSDS", positionType: "Supplied"});

    function setUp() public {
        fork = vm.createFork(vm.envString("MAINNET_URL"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new SkySavingsUsdsBalanceOracle(address(SAVINGS_USDS), positionMetadata);
    }

    function test_MAINNET_balanceOf_TEST_USER() public {
        int256 balance = oracle.balanceOf(address(USDS), TEST_USER);

        vm.startPrank(TEST_USER);
        uint256 previousBalance = USDS.balanceOf(TEST_USER);
        SAVINGS_USDS.redeem(SAVINGS_USDS.balanceOf(TEST_USER), TEST_USER, TEST_USER);
        uint256 newBalance = USDS.balanceOf(TEST_USER);
        vm.stopPrank();

        int256 expected = int256(newBalance - previousBalance);

        assertEq(balance, expected);
        assertEq(balance, 98_307_873_348_802_707_423_058_221);
    }

    function test_balanceOfZeroAddress() public view {
        int256 balance = oracle.balanceOf(address(USDS), address(0));
        assertEq(balance, 0);
    }

    function test_revertsOnInvalidToken() public {
        vm.expectRevert(InvalidArguments.selector);
        oracle.balanceOf(address(0xdead), TEST_USER);
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDS));
    }

    function test_constructorRevertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new SkySavingsUsdsBalanceOracle(address(0), positionMetadata);
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleCustom).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_immutableAddresses() public view {
        assertEq(address(oracle.SAVINGS_USDS()), address(SAVINGS_USDS));
        assertEq(oracle.USDS(), address(USDS));
    }
}
