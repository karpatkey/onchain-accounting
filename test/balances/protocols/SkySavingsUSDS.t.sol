// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {SkySavingsUsdsBalanceOracle} from "src/balances/protocols/SkySavingsUsds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract SavingsUSDSTest is TestEnvConfigurator, TestSetupHelpers {
    IERC4626 public constant SAVINGS_USDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    IERC20 public constant USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    uint256 public constant FORK_BLOCK = 21_378_910;

    uint256 public fork;
    SkySavingsUsdsBalanceOracle public oracle;
    MockBalances mockBalances;
    BalancesHarnessForFork public balances;

    // Global user address with SavingsUSDS position
    address public testUser;

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        mockBalances = new MockBalances();

        balances = deployBalancesInFork(address(USDS));
        oracle = new SkySavingsUsdsBalanceOracle(address(SAVINGS_USDS), "Sky", "SavingsUSDS", address(balances));

        // Set global user address - use address that has SavingsUSDS position
        testUser = 0x7F311a4D48377030bD810395f4CCfC03bdbe9Ef3;
    }

    function test_MAINNET_balanceOf_TEST_USER() public {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(testUser, address(USDS));

        vm.startPrank(testUser);
        uint256 previousBalance = USDS.balanceOf(testUser);
        SAVINGS_USDS.redeem(SAVINGS_USDS.balanceOf(testUser), testUser, testUser);
        uint256 newBalance = USDS.balanceOf(testUser);
        vm.stopPrank();

        uint256 expected = newBalance - previousBalance;

        assertEq(amount, expected, "Oracle balance should match redemption amount");
        assertGt(amount, 0, "User should have positive USDS position");
        assertFalse(isDebt);
    }

    function test_balanceOfZeroAddress() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(USDS));
        assertEq(amount, 0);
    }

    function test_returnsZeroOnInvalidToken() public view {
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        (uint256 amount,) = oracle.getOracleBalanceForAsset(testUser, address(0xdead));
        assertEq(amount, 0);
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDS));
    }

    function test_constructorRevertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new SkySavingsUsdsBalanceOracle(address(0), "Sky", "SavingsUSDS", address(mockBalances));
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_immutableAddresses() public view {
        assertEq(address(oracle.SAVINGS_USDS()), address(SAVINGS_USDS));
        assertEq(oracle.USDS(), address(USDS));
    }
}
