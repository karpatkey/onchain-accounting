// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {FluidFTokensMetaBalanceAdapter} from "src/balances/protocols/FluidFTokensMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FluidFTokensMetaParityForkTest
/// @notice Fork tests for the Fluid fTokens meta-adapter against real mainnet contracts.
///         against the real mainnet fUSDC vault with a deal-and-deposit position. Both adapters share one
///         BalancesHarnessForFork.
contract FluidFTokensMetaParityForkTest is BalanceAdapterTestBase {
    address public constant F_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 public constant FORK_BLOCK = 23_641_970;

    address public user = makeAddr("fluidUser");

    FluidFTokensMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        // Deal USDC and deposit into fUSDC so `user` holds a non-zero supply position.
        deal(USDC, user, 50_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(F_USDC, 50_000e6);
        IERC4626(F_USDC).deposit(50_000e6, user);
        vm.stopPrank();

        balances = _deployBalancesForOracle(USDC);
        meta = new FluidFTokensMetaBalanceAdapter("Fluid", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(F_USDC)));
    }

    function test_metaBalance() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(user, _instance(), address(0));
        assertEq(p.length, 1);
        assertApproxEqAbs(p[0].amount, 50_000e6, 1, "approx deposited assets");
        assertEq(p[0].positionId, abi.encode(F_USDC));
    }
}
