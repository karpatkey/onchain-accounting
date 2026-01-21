// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/StakeWiseV3OsToken.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

contract StakewiseOsTokenTest is TestEnvConfigurator {
    StakeWiseV3OsTokenBalanceOracle public osTokenBalanceOracle;
    MockBalances mockBalances;
    address public osGno = 0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0;
    address public gno = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public osTokenVaultController = 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a;
    address public osGnoHolder = 0x84d5922fF253e7287b642091F5803dF28a7E39Aa;

    function setUp() public {
        uint256 fork = vm.createFork(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(40_418_428);
        mockBalances = new MockBalances();

        osTokenBalanceOracle = new StakeWiseV3OsTokenBalanceOracle(
            osGno, gno, osTokenVaultController, "Stakewise v3", "osGNO", address(mockBalances)
        );
    }

    function test_revertIfUnsupportedAddress() public {
        vm.expectRevert();
        osTokenBalanceOracle.balanceOf(address(0), osGnoHolder);
    }

    function test_revertIfIncorrectToken() public {
        address wxdai = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
        vm.expectRevert();
        osTokenBalanceOracle.balanceOf(wxdai, osGnoHolder);
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = osTokenBalanceOracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], gno);
    }

    function test_gnosisInstance() public view {
        int256 price = osTokenBalanceOracle.balanceOf(gno, osGnoHolder);

        assertEq(price, 1_176_150_159_277_420_338_054);
    }
}
