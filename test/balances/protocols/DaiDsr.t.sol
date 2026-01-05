// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {DaiDsrBalanceOracle, PotLike} from "src/balances/protocols/DaiDsr.sol";

contract DaiDsrBalanceOracleTest is Test {
    uint256 fork;
    uint256 forkBlock;

    address dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address dsr = address(0x373238337Bfe1146fb49989fc222523f83081dDb);

    PotLike public pot;

    DaiDsrBalanceOracle oracle;
    IBalanceOracleCustom.PositionMetadata dsrMetadata =
        IBalanceOracleCustom.PositionMetadata({protocol: "Maker", position: "DSR", positionType: "Supplied"});

    function setUp() public {
        fork = vm.createFork(vm.envString("MAINNET_URL"));
        forkBlock = vm.parseUint(vm.envString("MAINNET_FORK_BLOCK"));

        vm.selectFork(fork);
        vm.rollFork(forkBlock);
        oracle = new DaiDsrBalanceOracle(dai, dsr, dsrMetadata);

        pot = oracle.pot();
    }

    function test_mainnet_balanceOf_rho_valid() public {
        address user = address(0x03eFba502883E05Ad15fC351b1582Bc55a54D5D3);
        uint256 rho = pot.rho();

        vm.rollFork(forkBlock - 16);
        oracle = new DaiDsrBalanceOracle(dai, dsr, dsrMetadata);

        assertEq(rho, block.timestamp);
        oracle = new DaiDsrBalanceOracle(dai, dsr, dsrMetadata);
        int256 balance = oracle.balanceOf(dai, user);
        assertEq(balance, 298_938_032_336);
    }

    function test_mainnet_balanceOf_rho_not_updated() public {
        address user = address(0x03eFba502883E05Ad15fC351b1582Bc55a54D5D3);
        vm.rollFork(forkBlock);

        uint256 rho = pot.rho();
        assert(rho < block.timestamp);
        oracle = new DaiDsrBalanceOracle(dai, dsr, dsrMetadata);
        int256 balance = oracle.balanceOf(dai, user);
        assertEq(balance, 298_938_172_407);
    }
}
