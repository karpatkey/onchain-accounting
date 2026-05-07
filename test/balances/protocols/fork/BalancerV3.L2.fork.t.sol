// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {BalancerV3PoolBalanceOracle, IGaugeV3} from "src/balances/protocols/BalancerV3.sol";

/// @title BalancerV3 L2 fork tests — Arbitrum
/// @notice Verifies the Arbitrum L2 fallback path in `claimableTokens()` — specifically that
///         when the gauge's `inflation_rate()` (no-arg, mainnet) reverts, `calculateIntegrateFractionL2`
///         correctly falls back to the week-indexed `inflation_rate(uint256)` mapping used on L2 gauges.
///         Ported from v1 karpatkey-tokenized-fund's `test_claimableTokens_arbitrum`.
contract BalancerV3ArbitrumL2ForkTest is TestEnvConfigurator, TestSetupHelpers {
    BalancerV3PoolBalanceOracle public oracle;

    // Arbitrum L2 Balancer V3 addresses (Aave GHO/USDT/USDC pool)
    address public constant POOL = 0x19B001e6Bc2d89154c18e2216eec5C8c6047b6d8;
    address public constant GAUGE = 0x915475b32983b7EB1235c1b6752149b454f81ad8;
    address public constant BALANCER_MINTER = 0xc3ccacE87f6d3A81724075ADcb5ddd85a8A1bB68;

    address public constant BAL_ARB = 0x040d1EdC9569d4Bab2D15287Dc5A4F10F56a56B8;
    address public constant TEST_ACCOUNT = 0x5D15d7f69c1B4362C8f2a398eda850d6DB510b48;

    // Fork block that v1 uses for this same assertion. Mirroring it here to keep parity with
    // v1's known-good result so a regression in the L2 fallback path would be caught.
    uint256 public constant FORK_BLOCK = 435_874_187;

    BalancesHarnessForFork public balances;

    function setUp() public {
        uint256 arbFork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(arbFork);
        vm.rollFork(FORK_BLOCK);

        address[] memory allAssets = new address[](2);
        allAssets[0] = POOL;
        allAssets[1] = BAL_ARB;
        balances = deployBalancesInFork(allAssets);

        oracle = new BalancerV3PoolBalanceOracle(
            POOL,
            GAUGE,
            BALANCER_MINTER,
            "Balancer v3",
            "{\"protocol\":\"Balancer V3\",\"pool\":\"Test Pool\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
    }

    function test_claimableTokens_arbitrum_l2_fallback() public view {
        // On Arbitrum, gauge.inflation_rate() (no-arg, mainnet signature) reverts. The adapter
        // must catch that and fall back to calculateIntegrateFractionL2 which uses the
        // week-indexed inflation_rate(uint256) mapping. v1 asserts this exact numeric result at
        // the same fork block — we keep the assertion so any regression in the fallback math
        // (off-by-one on week index, missing mintable() subtraction, etc.) is caught.
        int256 claimable = oracle.claimableTokens(BAL_ARB, TEST_ACCOUNT);
        assertEq(claimable, 2_759_910_397_061_400_746, "BAL claimable amount on Arbitrum L2 fallback path");
    }

    function test_calculateIntegrateFractionL2_nonReverting() public view {
        // Direct smoke test of the L2-specific path. Any non-revert means the week-iteration
        // logic completes for a real Arbitrum user.
        oracle.calculateIntegrateFractionL2(TEST_ACCOUNT, IGaugeV3(GAUGE));
    }
}
