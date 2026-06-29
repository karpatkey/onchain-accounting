// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {GearboxV3MarketsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IERC4626Min {
    function asset() external view returns (address);
}

/// @title GearboxMarketsMetaParityForkTest
/// @notice Fork tests for the Gearbox markets meta-adapter against real mainnet contracts.
///         against the real mainnet kpkWETH market and a real holder. Both adapters share one BalancesHarnessForFork.
contract GearboxMarketsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant MARKET = 0x9396DCbf78fc526bb003665337C5E73b699571EF; // kpkWETH
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant HOLDER = 0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C;
    uint256 public constant FORK_BLOCK = 24_068_807;

    GearboxV3MarketsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        balances = _deployBalancesForAdapter(WETH);
        meta = new GearboxV3MarketsMetaBalanceAdapter("Gearbox", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(MARKET)));
    }

    function test_metaBalance() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _instance(), address(0));
        uint256 metaAmt;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == WETH) metaAmt += p[i].amount;
        }
        assertGt(metaAmt, 0, "holder should have a kpkWETH position");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _instance(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].positionId, abi.encode(MARKET));
        assertEq(p[0].balanceAsset.asset, IERC4626Min(MARKET).asset());
    }
}
