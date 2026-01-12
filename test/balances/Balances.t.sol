// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IBalances, Balances} from "src/balances/Balances.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

import "src/errors.sol";

contract BalancesHarness is Balances {
    constructor() initializer {
        __Balances_init();
    }

    function setBalanceOracle(address underlyingAsset, address oracle, IBalances.BalanceType balanceType) public {
        _setBalanceOracle(underlyingAsset, oracle, balanceType);
    }

    function unsetBalanceOracle(address underlyingAsset, address oracle) public {
        _unsetBalanceOracle(underlyingAsset, oracle);
    }
}

contract BalancesTest is Test {
    BalancesHarness public balances;
    Mock_ERC20 public usdc;
    Mock_CustomBalanceOracle public customOracle;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public ops = makeAddr("ops");
    address public admin = makeAddr("admin");

    function setUp() public {
        vm.startPrank(admin);
        balances = new BalancesHarness();
        usdc = new Mock_ERC20("USDC", 6);
        customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalance(address(usdc), alice, 123_456_789);
        customOracle.setBalance(address(usdc), bob, -987_654_321);
        address[] memory underlyingAssets = new address[](1);
        underlyingAssets[0] = address(usdc);
        customOracle.setUnderlyingAssetsSupported(underlyingAssets);
        customOracle.setPositionMetadata(
            IBalanceOracleCustom.PositionMetadata({
                protocol: "Mock Protocol", position: "Mock Position", positionType: "Mock Type"
            })
        );
        vm.stopPrank();
    }

    function test_setup() public view {
        (address oracle,) = balances.balanceOracleAt(balances.NATIVE_ADDRESS(), 0);

        assertEq(balances.balanceOracleCountFor(balances.NATIVE_ADDRESS()), 1);

        assertEq(oracle, balances.NATIVE_ADDRESS());
    }

    function test_setAndGetERC20BalanceOracle() public {
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);

        usdc.mint(alice, 1000);

        int256 balance = balances.balanceOf(address(usdc), 0, alice);
        assertEq(balance, 1000);
    }

    function test_setAndGetCustomBalanceOracle() public {
        balances.setBalanceOracle(address(customOracle), address(customOracle), IBalances.BalanceType.Custom);

        customOracle.setBalance(address(customOracle), alice, 2000);

        int256 balance = balances.balanceOf(address(customOracle), 0, alice);
        assertEq(balance, 2000);
    }

    function test_setAndGetCustomBalanceOracleNegativeBalance() public {
        balances.setBalanceOracle(address(customOracle), address(customOracle), IBalances.BalanceType.Custom);

        customOracle.setBalance(address(customOracle), alice, -2000);

        int256 balance = balances.balanceOf(address(customOracle), 0, alice);
        assertEq(balance, -2000);
    }

    function test_setBalanceOracle_nativeAddress() public {
        address nativeAddress = address(balances.NATIVE_ADDRESS());

        vm.expectRevert(IBalances.DuplicateBalanceOracle.selector);
        balances.setBalanceOracle(nativeAddress, nativeAddress, IBalances.BalanceType.Native);
    }

    function test_getNativeBalance() public {
        deal(alice, 1337);
        int256 balance = balances.balanceOf(address(balances.NATIVE_ADDRESS()), 0, alice);
        assertEq(balance, 1337);
    }

    function test_unsetBalanceOracle() public {
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        balances.unsetBalanceOracle(address(usdc), address(usdc));

        vm.expectRevert();
        balances.balanceOf(address(usdc), 0, alice);
    }

    function test_unsetBalanceOracle_cantRemoveNativeTokenNativeBalanceOracle() public {
        address nativeAddress = balances.NATIVE_ADDRESS();
        vm.expectRevert(InvalidArguments.selector);
        balances.unsetBalanceOracle(nativeAddress, nativeAddress);
    }

    function test_checkOracleSupport_ERC20() public view {
        balances.checkBalanceOracleSupport(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
    }

    function test_checkOracleSupport_Custom() public view {
        balances.checkBalanceOracleSupport(address(usdc), address(customOracle), IBalances.BalanceType.Custom);
    }

    function test_RevertIf_InvalidOracleZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        balances.checkBalanceOracleSupport(address(0), address(0), IBalances.BalanceType.ERC20);
    }

    function test_RevertIf_InvalidOracleERC20() public {
        vm.expectRevert();
        balances.checkBalanceOracleSupport(address(usdc), address(customOracle), IBalances.BalanceType.ERC20);
    }

    function test_RevertIf_InvalidOracleCustom() public {
        vm.expectRevert();
        balances.checkBalanceOracleSupport(address(usdc), address(usdc), IBalances.BalanceType.Custom);
    }

    function test_setBalanceOracle_duplicate() public {
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);

        vm.expectRevert();
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
    }

    function test_readBalanceOraclesWithMetadata() public {
        address ethAddress = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        balances.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        balances.setBalanceOracle(address(usdc), address(customOracle), IBalances.BalanceType.Custom);

        IBalances.BalanceOracleWithMetadata[] memory oracles_1 = balances.balanceOraclesWithMetadata(address(usdc));

        assertEq(oracles_1.length, 2);

        assertEq(oracles_1[0].oracle, address(usdc));
        assertEq(oracles_1[0].protocol, "Portfolio balance");
        assertEq(oracles_1[0].position, "USDC");
        assertEq(oracles_1[0].positionType, "ERC20");

        assertEq(oracles_1[1].oracle, address(customOracle));
        assertEq(oracles_1[1].protocol, "Mock Protocol");
        assertEq(oracles_1[1].position, "Mock Position");
        assertEq(oracles_1[1].positionType, "Mock Type");

        IBalances.BalanceOracleWithMetadata[] memory oracles_2 = balances.balanceOraclesWithMetadata(ethAddress);
        assertEq(oracles_2.length, 1);

        assertEq(oracles_2[0].oracle, ethAddress);
        assertEq(oracles_2[0].protocol, "Portfolio balance");
        assertEq(oracles_2[0].position, "ETH");
        assertEq(oracles_2[0].positionType, "Native");
    }
}
