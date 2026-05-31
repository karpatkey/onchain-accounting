// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {GearboxMarketsMetaBalanceAdapter} from "src/balances/protocols/GearboxMarketsMeta.sol";
import {GearboxMarketBalanceOracle} from "src/balances/protocols/GearboxMarket.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IERC4626Min {
    function asset() external view returns (address);
}

/// @title GearboxMarketsMetaParityForkTest
/// @notice Proves the Gearbox markets meta-adapter reproduces the per-market GearboxMarketBalanceOracle exactly,
///         against the real mainnet kpkWETH market and a real holder. Both adapters share one BalancesHarnessForFork.
contract GearboxMarketsMetaParityForkTest is BalanceAdapterTestBase {
    using Strings for address;

    address public constant MARKET = 0x9396DCbf78fc526bb003665337C5E73b699571EF; // kpkWETH
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant HOLDER = 0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C;
    uint256 public constant FORK_BLOCK = 24_068_807;

    GearboxMarketBalanceOracle public per;
    GearboxMarketsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        balances = _deployBalancesForOracle(WETH);
        per = new GearboxMarketBalanceOracle(
            MARKET,
            "Gearbox",
            "{\"protocol\":\"Gearbox\",\"product\":\"Market\",\"name\":\"x\"",
            MARKET.toHexString(),
            address(balances)
        );
        meta = new GearboxMarketsMetaBalanceAdapter("Gearbox", address(balances));
    }

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(MARKET)));
    }

    function test_parity() public view {
        (uint256 perAmt,) = per.getOracleBalanceForAsset(HOLDER, WETH);
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(HOLDER, _instance(), address(0));
        uint256 metaAmt;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].underlyingAsset.asset == WETH) metaAmt += p[i].amount;
        }
        assertEq(metaAmt, perAmt, "WETH supply parity");
        assertGt(perAmt, 0, "holder should have a kpkWETH position");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(HOLDER, _instance(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].positionId, MARKET.toHexString());
        assertEq(p[0].protocol, "Gearbox");
        assertEq(p[0].underlyingAsset.asset, IERC4626Min(MARKET).asset());
    }
}
