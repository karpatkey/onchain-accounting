// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/StakeWiseV3OsToken.sol";

contract StakewiseOsTokenTest is Test {
    StakeWiseV3OsTokenBalanceOracle public osTokenBalanceOracle;
    address public osGno = 0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0;
    address public gno = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public osTokenVaultController = 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a;
    address public osGnoHolder = 0x84d5922fF253e7287b642091F5803dF28a7E39Aa;
    IBalanceOracleCustom.PositionMetadata positionMetadata =
        IBalanceOracleCustom.PositionMetadata({protocol: "Stakewise", position: "osGNO", positionType: "Staked"});

    function setUp() public {
        uint256 fork = vm.createFork(vm.envString("GNOSIS_URL"));
        vm.selectFork(fork);
        vm.rollFork(40_418_428);

        osTokenBalanceOracle = new StakeWiseV3OsTokenBalanceOracle(osGno, gno, osTokenVaultController, positionMetadata);
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
