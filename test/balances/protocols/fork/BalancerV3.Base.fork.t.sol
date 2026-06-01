// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {BalancerV3PoolBalanceOracle, IGaugeV3} from "src/balances/protocols/BalancerV3.sol";

/// @title BalancerV3 L2 fork tests — Base
/// @notice Smoke-level coverage of the Aave GHO/USDC pool BalancerV3 adapter on Base.
///         Mirrors the Arbitrum L2 fork test pattern: confirms the L2 inflation_rate fallback
///         path in `calculateIntegrateFractionL2` does not revert against a real Base gauge,
///         and that `getOracleBalanceForAsset` is callable on the deployed oracle. Without a
///         pinned user-position on Base we cannot assert numeric claimable amounts here; this
///         test exists to catch ABI / fallback regressions when adding the Base BalancerV3
///         adapter to `04_DeployBalanceAdapters.s.sol`.
contract BalancerV3BaseL2ForkTest is TestEnvConfigurator, TestSetupHelpers {
    BalancerV3PoolBalanceOracle public oracle;

    // Base L2 Balancer V3 addresses (Aave GHO/USDC pool)
    address public constant POOL = 0x7AB124EC4029316c2A42F713828ddf2a192B36db;
    address public constant GAUGE = 0x70DB188E5953f67a4B16979a2ceA26248b315401;
    address public constant BALANCER_MINTER = 0x0c5538098EBe88175078972F514C9e101D325D4F;

    address public constant BAL_BASE = 0x4158734D47Fc9692176B5085E0F52ee0Da5d47F1;
    address public constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant GHO_BASE = 0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee;

    BalancesHarnessForFork public balances;

    function setUp() public {
        uint256 baseFork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(baseFork);

        address[] memory allAssets = new address[](4);
        allAssets[0] = POOL;
        allAssets[1] = BAL_BASE;
        allAssets[2] = USDC_BASE;
        allAssets[3] = GHO_BASE;
        balances = deployBalancesInFork(allAssets);

        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, address(balances));
    }

    /// @notice The L2 inflation_rate fallback path runs without reverting against the live Base gauge.
    /// Same shape as the Arbitrum smoke test — confirms ABI parity for Base L2 gauges.
    function test_calculateIntegrateFractionL2_nonReverting() public view {
        // Use the gauge address itself as the account — guaranteed to exist and have non-empty
        // history at the gauge. Any non-revert means the week-iteration logic completes.
        oracle.calculateIntegrateFractionL2(GAUGE, IGaugeV3(GAUGE));
    }

    /// @notice `getOracleBalanceForAsset` returns without reverting for each pool-supported asset.
    /// Numeric assertion is impossible without a pinned user-position; this is a smoke check that
    /// the underlying token / pool / gauge wiring is intact on Base.
    function test_getOracleBalanceForAsset_nonReverting() public view {
        oracle.getOracleBalanceForAsset(GAUGE, USDC_BASE);
        oracle.getOracleBalanceForAsset(GAUGE, GHO_BASE);
        oracle.getOracleBalanceForAsset(GAUGE, BAL_BASE);
    }
}
