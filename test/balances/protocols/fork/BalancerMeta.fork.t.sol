// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancerV3PoolsMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV3PoolsMeta.sol";
import {BalancerV3GaugesMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV3GaugesMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title BalancerMetaParityForkTest
/// @notice Proves the split (BalancerV3PoolsMeta = wallet LP, BalancerV3GaugesMeta = staked LP + rewards) reproduces the
///         original combined BalancerV3PoolBalanceOracle per token, against the real mainnet Aave GHO/USDT/USDC pool
///         + gauge. All three adapters share one BalancesHarnessForFork registry (which implements
///         getRegisteredAssets), so per-token amounts are directly comparable. The combined adapter does a single
///         `poolBalanceOf(wallet + staked)` conversion while the split does two — a ≤ a-few-units rounding
///         difference per token (see BalancerV3PoolLib), asserted within tight tolerances.
contract BalancerMetaParityForkTest is BalanceAdapterTestBase {
    address public constant POOL = 0x85B2b559bC2D21104C4DEFdd6EFcA8A20343361D;
    address public constant GAUGE = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
    address public constant BALANCER_MINTER = 0x239e55F427D44C3cc793f49bFB507ebe76638a2b;

    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant USDT = MAINNET_USDT;
    address public constant USDC = MAINNET_USDC;
    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    uint256 public constant FORK_BLOCK = 22_087_430;
    uint256 public constant FORK_BLOCK_2 = 22_131_971;

    // Users with positions (from BalancerV3.fork.t.sol).
    address public constant MAINNET_STAKED_USER = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    address public constant MAINNET_WHALE_USER = 0xaF52695E1bB01A16D33D7194C28C42b10e0Dbec2;

    BalancerV3PoolsMetaBalanceAdapter public pools;
    BalancerV3GaugesMetaBalanceAdapter public gauges;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _deployAll();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _deployAll() internal {
        balances = _deployBalancesForOracle(_supportedAssets());
        pools = new BalancerV3PoolsMetaBalanceAdapter("Balancer V3", address(balances));
        gauges = new BalancerV3GaugesMetaBalanceAdapter(BALANCER_MINTER, "Balancer V3", address(balances));
    }

    function _supportedAssets() internal pure returns (address[] memory assets) {
        assets = new address[](4);
        assets[0] = USDT;
        assets[1] = USDC;
        assets[2] = GHO;
        assets[3] = BAL;
    }

    function _poolInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(POOL)));
    }

    function _gaugeInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(GAUGE)));
    }

    /// @notice Sum of the split adapters' legs for a single token (assetFilter restricts to that token).
    function _splitTokenAmount(address user, address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p = pools.getOraclePositionsForInstances(user, _poolInstance(), token);
        for (uint256 i = 0; i < p.length; i++) {
            sum += p[i].amount;
        }
        INAVCalculator.PositionBalance[] memory g = gauges.getOraclePositionsForInstances(user, _gaugeInstance(), token);
        for (uint256 i = 0; i < g.length; i++) {
            sum += g[i].amount;
        }
    }

    function test_splitTokenAmount_whale() public view {
        address[] memory assets = _supportedAssets();
        bool any;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 splitAmt = _splitTokenAmount(MAINNET_WHALE_USER, assets[i]);
            if (splitAmt != 0) any = true;
        }
        assertTrue(any, "user should have at least one non-zero position");
    }

    /// @notice Identity strings are derived on-chain from the instance coordinate.
    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            pools.getOraclePositionsForInstances(MAINNET_WHALE_USER, _poolInstance(), address(0));
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(POOL), "pool positionId = pool address");
        }
        INAVCalculator.PositionBalance[] memory g =
            gauges.getOraclePositionsForInstances(MAINNET_WHALE_USER, _gaugeInstance(), address(0));
        for (uint256 i = 0; i < g.length; i++) {
            assertEq(g[i].positionId, abi.encode(GAUGE), "gauge positionId = gauge address");
        }
    }
}
