// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {RegisterAssets} from "script/manage/RegisterAssets.s.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";

/// @title RegisterAssetsTest
/// @notice The first dedicated test for `script/manage/RegisterAssets.s.sol` — the step that registers every asset and
///         wires every price feed on a fresh NAV. Before this file, none of its behaviour was exercised by any test in
///         the repo (issue #260), including the two guards that route registration through `AssetKindRegistry`.
/// @dev **Why the guards specifically, and why now.** `AssetKindRegistryNotDeployed` fired for real during a fork
///      rehearsal, because the preflight script and the runbook had diverged on step order. It refused rather than
///      falling back to `NAVCalculator.registerAsset` — which is the correct outcome precisely because the fallback
///      would have SUCCEEDED, silently and permanently costing every asset in that run its labels: labels can only be
///      written at registration and there is no setter. So the guard is load-bearing, and until this file it had never
///      been executed by a test. That is the #253 failure mode — three guards written on reasoning alone, all three
///      defective — and it is what {test_failsClosed_whenAssetKindRegistryNotDeployed} exists to close.
///
///      **The fail-closed test and the happy path deliberately share one config builder** ({_writeTwoFeedAssetConfig}).
///      The two runs differ in exactly one fact — whether the chain's `AssetKindRegistry` is recorded in the
///      deployments file — so the pair proves the guard is not merely reachable but DISCRIMINATING: the same config
///      that aborts without the registry registers, classifies and labels with it. A guard that fires on a config
///      which could not have worked anyway proves nothing.
///
///      **Method.** The script is driven through its real `run()` entry point against a real `NAVCalculator` proxy and
///      a real `AssetKindRegistry` — no mocks on either side of the facade — reading fixture JSON written to the
///      genuine `script/config/**` paths under a throwaway chain id, and its real `safe-transactions/*.json` output is
///      read back to assert the batch. Nothing here re-implements the planner; every assertion is about what the
///      shipped script did. The fixture files are written and removed within each test (the
///      `BridgeEscrowConfigRehearsal` precedent), and every run goes through {_runScriptCatching} so a reverting run
///      still cleans up before the assertions execute.
///
///      **Every assertion here was proven able to fail**, by mutating the script and confirming the intended test went
///      red: routing the primary to `NAVCalculator.registerAsset` when no registry is recorded (the fallback the guard
///      forbids) kills the fail-closed test; routing it there when the registry IS recorded — which executes cleanly
///      and only loses the labels — kills the happy path on its TARGET assertion; defaulting a bad `accrualKind` kills
///      both kind tests; deleting the NAV-pointer check kills that one; deleting the unresolved-primary skip kills the
///      last. That last mutation initially SURVIVED, which is why TKB carries a resolvable second feed — see
///      {test_unresolvedPrimaryFeed_silentlySkipsTheAsset}.
///
///      **Overlap with `AssetKindRegistryWiring.t.sol`, stated rather than quietly duplicated.** That file's
///      `RegisterAssetsWiringGuardTest` already reaches `NavNotPointedAtAssetKindRegistry`, against an EMPTY assets
///      config — so it proves the guard fires before an empty plan. {test_failsClosed_whenNavDoesNotPointAtRegistry}
///      here re-asserts it against a real asset, which is what pins "before planning" rather than "before doing
///      nothing". The other guards had no coverage anywhere.
///
///      **What this file does NOT cover**, stated rather than implied: the MultiSend encoding path
///      (`_buildMultiSendCallData` is logged, never executed against a real MultiSend), the `--rpc-url`/no-code early
///      returns, and the per-chain committed configs. Targets are asserted on two of the three layers the target
///      passes through — the Safe-tx JSON and the EOA broadcast — not on the third.
contract RegisterAssetsTest is SuperTest {
    /// @dev Throwaway chain id for the running test, set by {_useFixtureChain}. Its three config files are created and
    ///      removed inside that test, so nothing here depends on how the committed per-chain configs happen to be
    ///      authored, and no committed file is touched.
    /// @dev **Every test uses a DIFFERENT id, and that is not cosmetic.** All config paths are `<chainId>.json`, so a
    ///      shared id would make the fixtures a shared mutable resource across test functions — and forge is free to
    ///      run them concurrently. Distinct ids make the races impossible rather than unlikely.
    uint256 internal fixtureChainId;

    /// @dev Config values, kept as constants so the JSON fixture and the expected calldata cannot drift apart.
    uint256 internal constant PRIMARY_HEARTBEAT = 3600;
    uint256 internal constant SECONDARY_HEARTBEAT = 86_400;
    uint256 internal constant MONITOR_HEARTBEAT = 86_400;
    uint32 internal constant DIVERGENCE_TOLERANCE_BPS = 250;

    RegisterAssets internal script;
    AssetKindRegistry internal registry;

    /// @dev The asset the happy-path/fail-closed pair registers, plus its three feeds. All three report the same price
    ///      so the divergence check between the primary and the monitor cannot be what fails a test.
    Mock_ERC20 internal tokenA;
    Mock_PriceOracleChainlink internal feedPrimary;
    Mock_PriceOracleChainlink internal feedSecondary;
    Mock_PriceOracleChainlink internal feedMonitor;

    /// @dev A resolvable feed used ONLY as TKB's second entry in {test_unresolvedPrimaryFeed_silentlySkipsTheAsset} —
    ///      the fallback that must never be promoted to primary.
    Mock_PriceOracleChainlink internal feedFallback;

    function setUp() public {
        setupAll();

        registry = new AssetKindRegistry(address(nav));
        vm.startPrank(admin);
        // The wiring `08_DeployAssetKindRegistry` performs: the facade forwards to `NAVCalculator.registerAsset` and
        // the NAV gates on ITS `msg.sender`, so the REGISTRY needs MANAGER, not just the operator.
        nav.grantRole(MANAGER, address(registry));
        // `_broadcastManagerMultiSend` runs `vm.startBroadcast()` with no argument, so the batch executes as forge's
        // default sender. That address is the "operator" for these tests and needs MANAGER on the NAV.
        nav.grantRole(MANAGER, DEFAULT_SENDER);
        vm.stopPrank();

        tokenA = new Mock_ERC20("TKA", 18);
        feedPrimary = new Mock_PriceOracleChainlink("TKA-primary", 100_000_000, 8);
        feedSecondary = new Mock_PriceOracleChainlink("TKA-secondary", 100_000_000, 8);
        feedMonitor = new Mock_PriceOracleChainlink("TKA-monitor", 100_000_000, 8);
        feedFallback = new Mock_PriceOracleChainlink("TKB-fallback", 100_000_000, 8);

        script = new RegisterAssets();
    }

    /// @dev Puts the run on `id`: makes it the live `block.chainid` (the script keys every config read off it, so it
    ///      has to be set before `run()` calls its own `setUp()`), then writes that chain's config file. Nothing under
    ///      `src/nav` or `src/prices` reads `block.chainid`, so switching it after the NAV is deployed changes no
    ///      contract behaviour.
    function _useFixtureChain(uint256 id) internal {
        fixtureChainId = id;
        vm.chainId(id);
        vm.createDir("safe-transactions", true);
        _writeChainConfig();
    }

    // ============================================================
    // Fixture plumbing
    // ============================================================

    function _chainConfigPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/script/config/chains/", vm.toString(fixtureChainId), ".json");
    }

    function _assetsConfigPath() internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(), "/script/config/nav-config/assets-and-price-feeds/", vm.toString(fixtureChainId), ".json"
        );
    }

    function _deploymentsPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/script/config/deployments/", vm.toString(fixtureChainId), ".json");
    }

    function _safeTxPath() internal view returns (string memory) {
        return string.concat("safe-transactions/", vm.toString(fixtureChainId), "-register-assets.json");
    }

    function _writeChainConfig() internal {
        vm.writeFile(
            _chainConfigPath(),
            string.concat(
                '{"chainId":',
                vm.toString(fixtureChainId),
                ',"name":"register-assets-fixture","rpc":"http://127.0.0.1:8545",',
                '"explorer":"https://explorer.invalid","explorerApiKey":"",',
                '"chainlinkSequencerFeed":"0x0000000000000000000000000000000000000000","nativeTokenSymbol":"ETH",',
                '"addresses":{"securityCouncil":"',
                vm.toString(safe),
                '","admin":"',
                vm.toString(admin),
                '","manager":"',
                vm.toString(navCalculatorManager),
                '"}}'
            )
        );
    }

    /// @dev Records the NAV proxy, and the `AssetKindRegistry` only when `withRegistry` is true. Absence is expressed
    ///      by OMITTING the key, not by writing a zero address — `ConfigReader` treats an all-zero address as a
    ///      placeholder, so both spellings read back as `address(0)`, but omission is what a chain that has not run
    ///      `08` actually looks like on disk.
    function _writeDeployments(bool withRegistry) internal {
        string memory json = string.concat('{"NAVCalculatorProxy":"', vm.toString(address(nav)), '"');
        if (withRegistry) json = string.concat(json, ',"AssetKindRegistry":"', vm.toString(address(registry)), '"');
        vm.writeFile(_deploymentsPath(), string.concat(json, "}"));
    }

    /// @dev The shared config for the fail-closed / happy-path pair: ONE unregistered asset with two pricing feeds and
    ///      one monitor feed. `accrualKind` and `labels` are both present and valid, so the only thing that can stop
    ///      the run is the registry's absence — which is the whole point of using one builder for both tests.
    ///
    ///      Planned actions, in order: `registry.registerAsset` (primary), `nav.addPriceFeed` (second pricing feed),
    ///      `nav.setDivergenceTolerance`, `nav.addMonitorFeed`. That is a MIXED-TARGET batch with the registry at
    ///      index 0 and the NAV everywhere else, which is what {test_happyPath_batchIsMixedTarget_andLabelsLand}
    ///      asserts.
    function _writeTwoFeedAssetConfig() internal {
        vm.writeFile(
            _assetsConfigPath(),
            string.concat(
                '{"TKA":{"address":"',
                vm.toString(address(tokenA)),
                '","accrualKind":"Appreciating","labels":["Lido","LST"],"divergenceToleranceBps":',
                vm.toString(uint256(DIVERGENCE_TOLERANCE_BPS)),
                ',"priceFeeds":[{"type":"Chainlink","address":"',
                vm.toString(address(feedPrimary)),
                '","heartbeat":',
                vm.toString(PRIMARY_HEARTBEAT),
                '},{"type":"Chainlink","address":"',
                vm.toString(address(feedSecondary)),
                '","heartbeat":',
                vm.toString(SECONDARY_HEARTBEAT),
                '}],"monitorFeeds":[{"type":"Chainlink","address":"',
                vm.toString(address(feedMonitor)),
                '","heartbeat":',
                vm.toString(MONITOR_HEARTBEAT),
                "}]}}"
            )
        );
    }

    /// @dev Removes every file a run can create. Called before assertions on every path (including the reverting ones)
    ///      so a failing assertion never leaves fixture debris in `script/config/**`.
    function _cleanup() internal {
        if (vm.exists(_assetsConfigPath())) vm.removeFile(_assetsConfigPath());
        if (vm.exists(_deploymentsPath())) vm.removeFile(_deploymentsPath());
        if (vm.exists(_chainConfigPath())) vm.removeFile(_chainConfigPath());
        if (vm.exists(_safeTxPath())) vm.removeFile(_safeTxPath());
    }

    /// @dev External so {_runScriptCatching} can drive it through `try`.
    function runScript() external {
        script.run();
    }

    /// @dev Runs the script, capturing a revert instead of propagating it. This is what makes cleanup unconditional:
    ///      an `expectRevert` that fails would abort the test before `_cleanup()`, leaving fixture files behind under
    ///      `script/config/**` — the debris a later run would silently read.
    function _runScriptCatching() internal returns (bool ok, bytes memory err) {
        try this.runScript() {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @dev Every `to` in a written Safe-tx batch, in order. Read index by index rather than with a wildcard path:
    ///      forge's json cheatcodes require a path to resolve to exactly one value, so a wildcard over a multi-entry
    ///      array is rejected outright and over a single-entry one silently yields a scalar. Probing until the index
    ///      is absent also gives the batch LENGTH, which several assertions here depend on.
    function _batchTargets(string memory json) internal view returns (address[] memory targets) {
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(n), "].to"))) {
            ++n;
        }
        targets = new address[](n);
        for (uint256 i; i < n; ++i) {
            targets[i] = vm.parseJsonAddress(json, string.concat(".transactions[", vm.toString(i), "].to"));
        }
    }

    /// @dev First four bytes of a calldata blob (its function selector).
    function _selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        assembly {
            sel := mload(add(data, 32))
        }
    }

    // ============================================================
    // Guard: AssetKindRegistryNotDeployed — the branch that fired in the fork rehearsal
    // ============================================================

    /// @notice With no `AssetKindRegistry` recorded for the chain, a run that still has an asset to register ABORTS,
    ///         and leaves the NAV untouched — no fallback registration, no Safe-tx batch.
    /// @dev **This is the branch that fired for real.** The assertions after the revert are the substance: the point
    ///      of the guard is not that it throws, it is that nothing was written. A fallback to
    ///      `NAVCalculator.registerAsset` would have left `isAssetRegistered(TKA) == true` and the asset permanently
    ///      unlabellable, which is why `assertFalse` below is the assertion that actually encodes the requirement.
    ///
    ///      The revert carries the chain id, so it is asserted as a full ABI-encoded payload rather than by selector —
    ///      a guard that names the wrong chain is a guard that sends the operator to the wrong runbook.
    function test_failsClosed_whenAssetKindRegistryNotDeployed() public {
        _useFixtureChain(987_601);
        _writeTwoFeedAssetConfig();
        _writeDeployments(false); // 08_DeployAssetKindRegistry has not run

        (bool ok, bytes memory err) = _runScriptCatching();
        bool safeTxWritten = vm.exists(_safeTxPath());
        _cleanup();

        assertFalse(ok, "run must abort when no AssetKindRegistry is recorded");
        assertEq(
            err,
            abi.encodeWithSelector(RegisterAssets.AssetKindRegistryNotDeployed.selector, fixtureChainId),
            "must revert AssetKindRegistryNotDeployed naming this chain"
        );
        assertFalse(
            nav.isAssetRegistered(address(tokenA)),
            "the guard must NOT fall back to NAVCalculator.registerAsset - a fallback succeeds while costing labels"
        );
        assertFalse(safeTxWritten, "no Safe-tx batch may be produced by an aborted run");
    }

    /// @notice The same config that aborts above registers, classifies and labels once the registry IS deployed —
    ///         and the batch it produces is mixed-target, with ONLY the primary registration pointing at the registry.
    /// @dev Paired with {test_failsClosed_whenAssetKindRegistryNotDeployed} through the shared config builder: the two
    ///      runs differ in exactly one fact. Together they show the guard discriminates rather than merely fires.
    ///
    ///      Targets are asserted on the Safe-tx JSON (the artifact an operator actually executes) AND, implicitly, on
    ///      the EOA broadcast — the on-chain state below can only exist if `_broadcastManagerMultiSend` dispatched
    ///      each `batch[i]` to its own `to`, since the registry and the NAV do not share a selector.
    function test_happyPath_batchIsMixedTarget_andLabelsLand() public {
        _useFixtureChain(987_602);
        _writeTwoFeedAssetConfig();
        _writeDeployments(true);
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        (bool ok, bytes memory err) = _runScriptCatching();
        string memory batchJson = ok ? vm.readFile(_safeTxPath()) : "";
        _cleanup();

        assertTrue(ok, string.concat("run must succeed; reverted with: ", vm.toString(err)));

        // ---- the batch, as written for the Safe ----
        address[] memory targets = _batchTargets(batchJson);
        assertEq(targets.length, 4, "TKA plans registerAsset + addPriceFeed + setDivergenceTolerance + addMonitorFeed");
        assertEq(targets[0], address(registry), "primary registration must target AssetKindRegistry, not the NAV");
        assertEq(targets[1], address(nav), "addPriceFeed must target the NAV");
        assertEq(targets[2], address(nav), "setDivergenceTolerance must target the NAV");
        assertEq(targets[3], address(nav), "addMonitorFeed must target the NAV");

        assertEq(
            bytes32(_selectorOf(vm.parseJsonBytes(batchJson, ".transactions[0].data"))),
            bytes32(IAssetKindRegistry.registerAsset.selector),
            "index 0 must be the registry's six-parameter registerAsset"
        );
        assertEq(
            bytes32(_selectorOf(vm.parseJsonBytes(batchJson, ".transactions[1].data"))),
            bytes32(NAVCalculator.addPriceFeed.selector),
            "index 1 must be addPriceFeed"
        );
        assertEq(
            bytes32(_selectorOf(vm.parseJsonBytes(batchJson, ".transactions[2].data"))),
            bytes32(NAVCalculator.setDivergenceTolerance.selector),
            "index 2 must be setDivergenceTolerance"
        );
        assertEq(
            bytes32(_selectorOf(vm.parseJsonBytes(batchJson, ".transactions[3].data"))),
            bytes32(NAVCalculator.addMonitorFeed.selector),
            "index 3 must be addMonitorFeed"
        );

        // ---- the on-chain result of executing it ----
        assertTrue(nav.isAssetRegistered(address(tokenA)), "TKA registered on the NAV");
        assertEq(IPrices(address(nav)).getPriceFeedCount(address(tokenA)), 2, "both configured pricing feeds wired");
        assertEq(IPrices(address(nav)).getMonitorFeeds(address(tokenA)).length, 1, "the monitor feed wired");
        assertEq(
            IPrices(address(nav)).getAssetPricing(address(tokenA)).divergenceToleranceBps,
            DIVERGENCE_TOLERANCE_BPS,
            "divergence tolerance from config"
        );

        // Classification AND labels landed in the SAME transaction as the registration — the property the whole
        // registry route exists for, and the one a NAV fallback would have silently destroyed.
        (PegKind pegKind, AccrualKind accrualKind, string[] memory labels) = nav.getAssetInfo(address(tokenA));
        assertEq(uint256(accrualKind), uint256(AccrualKind.Appreciating), "accrualKind from config");
        assertEq(uint256(pegKind), uint256(PegKind.Floating), "no peg tolerance configured -> Floating");
        assertEq(labels.length, 2, "both configured labels written");
        assertEq(labels[0], "Lido", "label 0");
        assertEq(labels[1], "LST", "label 1");
    }

    // ============================================================
    // Guard: AssetAccrualKindMissingOrInvalid
    // ============================================================

    /// @dev Both spellings of a bad kind reach the same guard, and both matter: an ABSENT key is what a newly-added
    ///      asset looks like, an UNRECOGNISED one is what a typo or a renamed enum member looks like. `ConfigReader`
    ///      has no default for either, deliberately, so neither can be silently absorbed as `AccrualKind.None`.
    function _assertAccrualKindGuard(string memory kindJsonFragment, string memory label) internal {
        vm.writeFile(
            _assetsConfigPath(),
            string.concat(
                '{"TKA":{"address":"',
                vm.toString(address(tokenA)),
                '",',
                kindJsonFragment,
                '"priceFeeds":[{"type":"Chainlink","address":"',
                vm.toString(address(feedPrimary)),
                '","heartbeat":',
                vm.toString(PRIMARY_HEARTBEAT),
                "}]}}"
            )
        );
        _writeDeployments(true);
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        (bool ok, bytes memory err) = _runScriptCatching();
        _cleanup();

        assertFalse(ok, string.concat(label, ": run must abort"));
        assertEq(
            err,
            abi.encodeWithSelector(RegisterAssets.AssetAccrualKindMissingOrInvalid.selector, string("TKA")),
            string.concat(label, ": must revert AssetAccrualKindMissingOrInvalid naming the symbol")
        );
        assertFalse(nav.isAssetRegistered(address(tokenA)), string.concat(label, ": nothing may be registered"));
    }

    function test_failsClosed_whenAccrualKindMissing() public {
        _useFixtureChain(987_603);
        _assertAccrualKindGuard("", "absent accrualKind");
    }

    function test_failsClosed_whenAccrualKindUnrecognised() public {
        _useFixtureChain(987_604);
        _assertAccrualKindGuard('"accrualKind":"Yielding",', "unrecognised accrualKind");
    }

    // ============================================================
    // Guard: NavNotPointedAtAssetKindRegistry
    // ============================================================

    /// @notice The registry exists and the deployments file records it, but the NAV's own pointer was never set — the
    ///         state left behind if `08`'s fourth broadcast alone failed. The run aborts BEFORE planning anything.
    /// @dev This is the subtler half of the pair the script guards: registration through the registry would have
    ///      worked, so the deploy would have gone green with every `getAssetInfo` reverting forever afterwards.
    ///
    ///      **Deliberately overlapping `AssetKindRegistryWiring.t.sol`'s `RegisterAssetsWiringGuardTest`**, which
    ///      reached this branch first — but against an empty assets config, where the run would have planned nothing
    ///      regardless. Here the config carries a real, fully-wireable asset, so the `assertFalse` on registration is
    ///      what pins "aborts BEFORE planning" rather than "aborts before doing nothing". The sibling additionally
    ///      covers the accepting side (guard does not fire once the NAV is wired); that is not repeated here, since
    ///      every other test in this file runs with the pointer correctly set.
    function test_failsClosed_whenNavDoesNotPointAtRegistry() public {
        _useFixtureChain(987_605);
        _writeTwoFeedAssetConfig();
        _writeDeployments(true);
        // Deliberately NOT calling nav.setAssetKindRegistry — the NAV still points at address(0).

        (bool ok, bytes memory err) = _runScriptCatching();
        _cleanup();

        assertFalse(ok, "run must abort when the NAV does not point back at the recorded registry");
        assertEq(
            err,
            abi.encodeWithSelector(
                RegisterAssets.NavNotPointedAtAssetKindRegistry.selector, address(nav), address(0), address(registry)
            ),
            "must revert NavNotPointedAtAssetKindRegistry carrying both sides of the mismatch"
        );
        assertFalse(nav.isAssetRegistered(address(tokenA)), "nothing may be registered");
    }

    // ============================================================
    // Idempotent re-run
    // ============================================================

    /// @notice A second run over an already-registered asset that carries NO tolerances and NO monitor feeds plans
    ///         ZERO actions and writes no batch at all.
    /// @dev Asserted by ABSENCE of the Safe-tx file: `run()` returns before `writeSafeTx` when `total == 0`, so
    ///      deleting the first run's output and finding it not recreated is a direct read of the planner's count —
    ///      stronger than re-parsing a stale artifact, which would pass even if the second run planned nothing
    ///      because it never got that far.
    function test_reRun_withoutTolerances_plansNothing() public {
        _useFixtureChain(987_606);
        vm.writeFile(
            _assetsConfigPath(),
            string.concat(
                '{"TKA":{"address":"',
                vm.toString(address(tokenA)),
                '","accrualKind":"None","priceFeeds":[{"type":"Chainlink","address":"',
                vm.toString(address(feedPrimary)),
                '","heartbeat":',
                vm.toString(PRIMARY_HEARTBEAT),
                '},{"type":"Chainlink","address":"',
                vm.toString(address(feedSecondary)),
                '","heartbeat":',
                vm.toString(SECONDARY_HEARTBEAT),
                "}]}}"
            )
        );
        _writeDeployments(true);
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        (bool firstOk,) = _runScriptCatching();
        // Guarded: if the first run failed, there is no batch to remove and an unguarded removeFile would abort the
        // test before `_cleanup()`, leaving fixture files behind.
        if (vm.exists(_safeTxPath())) vm.removeFile(_safeTxPath());

        (bool secondOk, bytes memory secondErr) = _runScriptCatching();
        bool safeTxRecreated = vm.exists(_safeTxPath());
        _cleanup();

        assertTrue(firstOk, "first run must succeed");
        assertTrue(secondOk, string.concat("re-run must not revert; reverted with: ", vm.toString(secondErr)));
        assertFalse(safeTxRecreated, "a re-run with nothing to do must plan 0 actions and write no batch");
        assertEq(IPrices(address(nav)).getPriceFeedCount(address(tokenA)), 2, "feeds not duplicated by the re-run");
    }

    /// @notice A re-run over an asset that DOES carry a divergence tolerance re-plans the tolerance setter — one
    ///         action, targeting the NAV — even though the value on-chain already matches config.
    /// @dev **Idempotency is per-action, and the tolerance setters are the exception.** `_buildMonitorActs` guards the
    ///      feed and monitor additions against on-chain state (they must — a duplicate `addPriceFeed`/`addMonitorFeed`
    ///      reverts and would abort the whole batch), but emits `setDivergenceTolerance`/`setPegTolerance` purely from
    ///      config, with no on-chain comparison. So the issue's expectation that a settled asset plans zero actions
    ///      holds only for the no-tolerance shape covered above; every real chain config sets tolerances, so in
    ///      practice a settled re-run still produces a batch.
    ///
    ///      Recorded here as behaviour rather than filed as a defect: re-setting a tolerance to the value it already
    ///      holds is harmless on-chain (unlike a duplicate feed add, which reverts), so the cost is a batch that reads
    ///      as work when there is none. This test is what will notice if that ever changes in either direction.
    ///
    ///      The on-chain assertions confirm the re-run did not double-wire anything else: a duplicate feed or monitor
    ///      add would have reverted during the broadcast and failed `secondOk`.
    function test_reRun_withTolerances_replansOnlyTheToleranceSetter() public {
        _useFixtureChain(987_607);
        _writeTwoFeedAssetConfig();
        _writeDeployments(true);
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        (bool firstOk,) = _runScriptCatching();
        // Guarded: if the first run failed, there is no batch to remove and an unguarded removeFile would abort the
        // test before `_cleanup()`, leaving fixture files behind.
        if (vm.exists(_safeTxPath())) vm.removeFile(_safeTxPath());

        (bool secondOk, bytes memory secondErr) = _runScriptCatching();
        string memory batchJson = secondOk && vm.exists(_safeTxPath()) ? vm.readFile(_safeTxPath()) : "";
        _cleanup();

        assertTrue(firstOk, "first run must succeed");
        assertTrue(secondOk, string.concat("re-run must not revert; reverted with: ", vm.toString(secondErr)));
        assertGt(bytes(batchJson).length, 0, "the re-run does write a batch (the tolerance setter is re-planned)");

        address[] memory targets = _batchTargets(batchJson);
        assertEq(targets.length, 1, "exactly one action survives the re-run");
        assertEq(targets[0], address(nav), "and it targets the NAV, not the registry");
        assertEq(
            bytes32(_selectorOf(vm.parseJsonBytes(batchJson, ".transactions[0].data"))),
            bytes32(NAVCalculator.setDivergenceTolerance.selector),
            "the re-planned action is setDivergenceTolerance"
        );

        assertEq(IPrices(address(nav)).getPriceFeedCount(address(tokenA)), 2, "feeds not duplicated by the re-run");
        assertEq(IPrices(address(nav)).getMonitorFeeds(address(tokenA)).length, 1, "monitor not duplicated");
    }

    // ============================================================
    // The silent skip
    // ============================================================

    /// @notice An unregistered asset whose PRIMARY feed is an undeployed `Custom` feed is dropped from the run — no
    ///         revert, no batch entry, no registration — even though a LATER feed of that asset resolves fine, and
    ///         while its neighbours are wired normally.
    /// @dev **TKB carries a resolvable SECOND feed, and that detail is the whole test.** With only an unresolvable
    ///      feed[0], the per-feed `continue` inside `_planFeedActs` drops the asset on its own and the early
    ///      `_feedResolvable(symbol, 0)` skip is unreachable-by-redundancy — a fixture shaped that way passes whether
    ///      the guard is there or not (confirmed by mutation: deleting the skip left it green). The skip only
    ///      DISCRIMINATES when a trailing feed resolves, because that is the case where its absence would silently
    ///      promote the fallback feed to primary and register TKB against the wrong oracle. So the batch length below
    ///      is the load-bearing assertion: 4 means TKB contributed nothing, 5 would mean it was registered against
    ///      `feedFallback`.
    ///
    ///      **This is a documented silent drop, and the test exists to make it visible rather than to endorse it.**
    ///      Refusing to guess the primary oracle is right, but the only trace is a `console2.log` line no CI reads. So
    ///      an operator who forgot to deploy a custom feed gets a green run with an asset missing from the NAV.
    function test_unresolvedPrimaryFeed_silentlySkipsTheAsset() public {
        _useFixtureChain(987_608);
        Mock_ERC20 tokenB = new Mock_ERC20("TKB", 18);
        vm.writeFile(
            _assetsConfigPath(),
            string.concat(
                '{"TKA":{"address":"',
                vm.toString(address(tokenA)),
                '","accrualKind":"Appreciating","labels":["Lido","LST"],"divergenceToleranceBps":',
                vm.toString(uint256(DIVERGENCE_TOLERANCE_BPS)),
                ',"priceFeeds":[{"type":"Chainlink","address":"',
                vm.toString(address(feedPrimary)),
                '","heartbeat":',
                vm.toString(PRIMARY_HEARTBEAT),
                '},{"type":"Chainlink","address":"',
                vm.toString(address(feedSecondary)),
                '","heartbeat":',
                vm.toString(SECONDARY_HEARTBEAT),
                '}],"monitorFeeds":[{"type":"Chainlink","address":"',
                vm.toString(address(feedMonitor)),
                '","heartbeat":',
                vm.toString(MONITOR_HEARTBEAT),
                '}]},"TKB":{"address":"',
                vm.toString(address(tokenB)),
                // A `Custom` feed named by a `customPriceFeeds` entry the deployments file does not contain, i.e.
                // 03_DeployPriceFeeds has not deployed it yet. `readAssetFeedAddress` resolves to "".
                '","accrualKind":"None","priceFeeds":[{"type":"Custom","feed":"NotYetDeployedFeed","heartbeat":',
                vm.toString(PRIMARY_HEARTBEAT),
                // A perfectly resolvable SECOND feed. Without the skip this one is promoted to primary and TKB is
                // registered against it; with the skip TKB is dropped whole.
                '},{"type":"Chainlink","address":"',
                vm.toString(address(feedFallback)),
                '","heartbeat":',
                vm.toString(SECONDARY_HEARTBEAT),
                "}]}}"
            )
        );
        _writeDeployments(true);
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        (bool ok, bytes memory err) = _runScriptCatching();
        string memory batchJson = ok ? vm.readFile(_safeTxPath()) : "";
        _cleanup();

        assertTrue(ok, string.concat("an unresolved primary feed must not abort the run; got: ", vm.toString(err)));

        address[] memory targets = _batchTargets(batchJson);
        assertEq(
            targets.length,
            4,
            "the batch must carry TKA's four actions and nothing for TKB - a 5th would be TKB promoted to its fallback"
        );

        assertTrue(nav.isAssetRegistered(address(tokenA)), "TKA is wired normally alongside the skipped asset");
        assertFalse(
            nav.isAssetRegistered(address(tokenB)),
            "TKB is dropped from the run, silently - NOT registered against its resolvable second feed"
        );
    }
}
