// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseDeployScript} from "script/utils/BaseDeployScript.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @notice Minimal stand-in for the NAV proxy, exposing only what `_onChainDivergenceToleranceBps` staticcalls.
contract MockPricingSource {
    IPrices.AssetPricing internal pricing;
    bool public reverts;

    function set(uint32 divergenceToleranceBps, uint32 pegToleranceBps) external {
        pricing =
            IPrices.AssetPricing({divergenceToleranceBps: divergenceToleranceBps, pegToleranceBps: pegToleranceBps});
    }

    function setReverts(bool value) external {
        reverts = value;
    }

    function getAssetPricing(address) external view returns (IPrices.AssetPricing memory) {
        require(!reverts, "pricing unavailable");
        return pricing;
    }
}

/// @notice Concrete `BaseDeployScript` that exposes the guard and neutralises the script scaffolding.
/// @dev `setUp()` is overridden to a no-op: the real one reads `script/config/chains/<chainId>.json` and would
///      make this a config test. `run()` reverts so the harness cannot be driven as a deploy script.
contract TolerancesHarness is BaseDeployScript {
    function setUp() public pure override {}

    function run() public pure override {
        revert("harness: not a deploy script");
    }

    function requireTolerancesPlannable(
        address navProxy,
        address asset,
        string memory symbol,
        uint256 monCount,
        uint256 divTol,
        uint256 pegTol,
        bool monitorsBeingAdded
    ) external view {
        _requireTolerancesPlannable(navProxy, asset, symbol, monCount, divTol, pegTol, monitorsBeingAdded);
    }
}

/// @title BaseDeployScript._requireTolerancesPlannable
/// @notice The guard that stops `RegisterAssets` / `MigrateToMonitorFeeds` from planning a batch containing a
///         call that is certain to revert on-chain.
/// @dev    It had **no test at all** before this file: blanking its body and deleting its two call sites were
///         equally invisible to the suite, because nothing under `test/` or `script/test/` imports or
///         instantiates anything in `script/manage/`. The integration harness deliberately re-implements the
///         same wiring instead of calling it (`IntegrationFromConfigBase.fork.sol`, "mirrors production
///         RegisterAssets"), and a mirror cannot catch a divergence from the thing it mirrors.
///
///         Each arm is asserted with its exact revert string, so removing one arm cannot be masked by another.
contract BaseDeployScriptTolerancesTest is Test {
    TolerancesHarness internal harness;
    MockPricingSource internal navProxy;

    address internal constant ASSET = address(0xA55E7);
    string internal constant SYMBOL = "WETH";

    function setUp() public {
        harness = new TolerancesHarness();
        navProxy = new MockPricingSource();
    }

    // --- arm 1: adding monitors with no divergence tolerance anywhere ---

    function test_revertsWhenAddingMonitorsWithNoToleranceInConfigOrOnChain() public {
        navProxy.set(0, 0);

        vm.expectRevert(bytes("WETH: adds monitorFeeds but no divergence tolerance (config or on-chain)"));
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 1, 0, 0, true);
    }

    /// @notice The idempotent re-run case the guard is deliberately lenient about: config carries no tolerance,
    ///         but one is already set on-chain from an earlier run, so `addMonitorFeed` will succeed.
    function test_allowsAddingMonitorsWhenToleranceAlreadyExistsOnChain() public {
        navProxy.set(500, 0);

        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 1, 0, 0, true);
    }

    /// @notice The arm is gated on monitors ACTUALLY being added — a plan that emits no `addMonitorFeed` must not
    ///         be blocked for lacking a tolerance it will never need.
    function test_allowsZeroToleranceWhenNoMonitorsAreBeingAdded() public {
        navProxy.set(0, 0);

        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 1, 0, 0, false);
    }

    /// @notice A failed/absent `getAssetPricing` reads as "no tolerance on chain" and blocks, rather than
    ///         planning a batch that will revert at execution.
    function test_revertsWhenTheOnChainReadFails() public {
        navProxy.set(500, 0);
        navProxy.setReverts(true);

        vm.expectRevert(bytes("WETH: adds monitorFeeds but no divergence tolerance (config or on-chain)"));
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 1, 0, 0, true);
    }

    // --- arm 2: divergence tolerance above the on-chain maximum ---

    function test_revertsOnDivergenceToleranceAboveTenThousandBps() public {
        vm.expectRevert(bytes("WETH: divergenceToleranceBps > 10000"));
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 1, 10_001, 0, false);
    }

    /// @dev Exactly 10 000 bps is the on-chain maximum and must be accepted; this is the boundary a
    ///      `>`-to-`>=` mutation moves.
    function test_acceptsDivergenceToleranceAtExactlyTenThousandBps() public view {
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 1, 10_000, 0, false);
    }

    /// @dev The arm is gated on `monCount > 0`: `setDivergenceTolerance` is only emitted when the asset declares
    ///      monitors, so an out-of-range value that will never be sent is not this guard's business.
    function test_ignoresOutOfRangeDivergenceToleranceWhenNoMonitorsAreDeclared() public view {
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 0, 10_001, 0, false);
    }

    // --- arm 3: peg tolerance above the on-chain maximum ---

    /// @dev Unlike the divergence arm this one is NOT gated on `monCount` — `setPegTolerance` is emitted whenever
    ///      `pegTol > 0`. `monCount` is 0 here precisely so that a mutation copying the divergence arm's
    ///      `monCount > 0` condition onto this one fails.
    function test_revertsOnPegToleranceAboveTenThousandBps() public {
        vm.expectRevert(bytes("WETH: pegToleranceBps > 10000"));
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 0, 0, 10_001, false);
    }

    function test_acceptsPegToleranceAtExactlyTenThousandBps() public view {
        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 0, 0, 10_000, false);
    }

    // --- the positive control ---

    /// @notice So "the guard rejects correctly" stays distinguishable from "the guard rejects everything".
    function test_acceptsAFullyValidPlan() public {
        navProxy.set(0, 0);

        harness.requireTolerancesPlannable(address(navProxy), ASSET, SYMBOL, 2, 500, 200, true);
    }

    /// @notice The symbol is interpolated into every message, so an operator reading a failed plan can tell which
    ///         asset is at fault.
    function test_revertMessageNamesTheAsset() public {
        vm.expectRevert(bytes("USDC: pegToleranceBps > 10000"));
        harness.requireTolerancesPlannable(address(navProxy), ASSET, "USDC", 0, 0, 10_001, false);
    }
}
