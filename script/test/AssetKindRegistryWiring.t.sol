// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployAssetKindRegistry} from "script/deploy/08_DeployAssetKindRegistry.s.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {RegisterAssets} from "script/manage/RegisterAssets.s.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title AssetKindRegistryWiringTest
/// @notice **The first execution harness for `08_DeployAssetKindRegistry`.** It runs the script's `run()` against a
///         real, locally deployed `NAVCalculator` and asserts the on-chain result — specifically that the NAV ends up
///         POINTING BACK at the registry the script deployed.
/// @dev **Why this exists, and why its absence was not a theoretical gap.** `NAVCalculator.setAssetKindRegistry`
///      shipped with the asset read surface and was called by NOTHING outside unit tests — no deploy script, no
///      runbook line, no preflight gate. Every deploy therefore finished with `assetKindRegistry == address(0)` and
///      every `getAssetInfo` call reverting, while every other check passed. The defect survived the PR that
///      introduced the getter, the PR that replaced it, and two independent reviews, because the two directions of the
///      NAV↔registry link are invisible from inside either contract.
///
///      **Nothing could have caught it, because `08`'s `run()` had never been executed by any test.** The only
///      script-side coverage was `AssetKindConfigParsing.t.sol`, which by its own docstring exercises `ConfigReader`'s
///      mapping rather than the script. So the rule this repo applies to guards — a branch that has never run is
///      indistinguishable from one that cannot run — had never been applied to the script's OUTCOME at all.
///
///      **This harness runs without RPC**, which is what makes it a unit-tier test the author can actually execute
///      rather than a fork-tier one taken on trust. `BaseDeployScript.setUp()` reads JSON and env only; the
///      `RpcUrlNotSet()` failure seen in `Test02_DeployProxies` comes from that suite forking, not from the base class.
///
///      **Fixture discipline, copied from `AssetKindConfigParsing.t.sol` and for the same reason.** The script is
///      config-driven, so the only way to run it is to give it a chain to read. Every fixture path is asserted
///      UNOCCUPIED before writing — `foundry.toml` grants read-write over all of `script/`, so a typo in the chain id
///      would otherwise overwrite a real chain's committed config and then remove it, with the assertions still
///      passing. The literal id is the only thing separating the two.
///
///      ⚠️ **The known limit, stated rather than implied:** a revert between write and cleanup, or an interrupted run,
///      leaves fixture files in the tree — untracked, un-ignored, and enough to break the clean-tree gate. If that
///      happens, delete `script/config/**/987654331.json`. It is test debris, never real config.
contract AssetKindRegistryWiringTest is Test {
    /// @dev Distinct from `AssetKindConfigParsing`'s 987_654_322 so the two suites cannot collide under `forge test`'s
    ///      parallel execution.
    uint256 internal constant FIXTURE_CHAIN = 987_654_331;

    /// @dev `vm.startBroadcast()` with no argument executes subsequent calls as forge's default sender, so THAT is the
    ///      address the script acts as — not this test contract. It must therefore hold the NAV roles `08` needs.
    address internal constant BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    NAVCalculator internal nav;
    DeployAssetKindRegistry internal script;

    string internal chainPath;
    string internal assetsPath;
    string internal deploymentsPath;

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory id = vm.toString(FIXTURE_CHAIN);
        chainPath = string(abi.encodePacked(root, "/script/config/chains/", id, ".json"));
        assetsPath = string(abi.encodePacked(root, "/script/config/nav-config/assets-and-price-feeds/", id, ".json"));
        deploymentsPath = string(abi.encodePacked(root, "/script/config/deployments/", id, ".json"));

        assertFalse(vm.exists(chainPath), "fixture chain config must be unoccupied");
        assertFalse(vm.exists(assetsPath), "fixture assets config must be unoccupied");
        assertFalse(vm.exists(deploymentsPath), "fixture deployments record must be unoccupied");

        // `NAVCalculator` is pre-linked against two libraries at deterministic CREATE2 addresses (`foundry.toml`
        // `[libraries]`), and a bare test EVM has no code there, so `initialize` DELEGATECALLs into nothing. Etch the
        // runtime code at the pinned addresses, exactly as `SuperTest` does. This is provisioning, not pinning — no
        // pin value is read, written or asserted here.
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        // A real NAV, not a mock: the whole point is to assert the script's effect on the actual storage slot the
        // read path uses. The broadcaster gets DEFAULT_ADMIN so it can grant, and MANAGER so it can classify —
        // exactly the privileges `08` documents needing, and exactly what `07` later revokes.
        address impl = address(new NAVCalculator());
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(NAVCalculator.initialize, (BROADCASTER, address(0), "ETH"))
            )
        );
        vm.prank(BROADCASTER);
        nav.grantRole(MANAGER, BROADCASTER);

        vm.writeFile(chainPath, _chainJson());
        vm.writeFile(assetsPath, _assetsJson());
        vm.writeFile(deploymentsPath, _deploymentsJson(address(nav)));

        script = new DeployAssetKindRegistry();
        vm.chainId(FIXTURE_CHAIN);
    }

    /// @dev Cleanup runs in `tearDown`-equivalent position: forge has no tearDown, so each test removes the fixtures
    ///      itself via {_cleanup} before asserting, mirroring `AssetKindConfigParsing`. Assertions come last so a
    ///      failure does not leave debris.
    function _cleanup() internal {
        if (vm.exists(chainPath)) vm.removeFile(chainPath);
        if (vm.exists(assetsPath)) vm.removeFile(assetsPath);
        if (vm.exists(deploymentsPath)) vm.removeFile(deploymentsPath);
    }

    function _chainJson() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"name":"AssetKindWiringFixture","rpc":"http://127.0.0.1:8545","explorer":"",',
                '"explorerApiKey":"","chainlinkSequencerFeed":"0x0000000000000000000000000000000000000000",',
                '"nativeTokenSymbol":"ETH","addresses":{"admin":"',
                vm.toString(BROADCASTER),
                '","manager":"',
                vm.toString(BROADCASTER),
                '","securityCouncil":"',
                vm.toString(BROADCASTER),
                '"}}'
            )
        );
    }

    function _assetsJson() internal pure returns (string memory) {
        return string(abi.encodePacked('{"USDC":{"address":"', vm.toString(USDC), '","accrualKind":"None"}}'));
    }

    function _deploymentsJson(address navProxy) internal pure returns (string memory) {
        return string(abi.encodePacked('{"NAVCalculatorProxy":"', vm.toString(navProxy), '"}'));
    }

    // ============================================================
    // L3 — the demonstration
    // ============================================================

    /// @dev **THE TEST THAT FAILED BEFORE THE FIX.** Runs `08` end to end against a real `NAVCalculator` and asserts
    ///      the on-chain result. Before `setAssetKindRegistry` was added to the script, the first assertion below
    ///      failed with `address(0)` — precisely the state every real deploy of this feature would have been left in.
    ///
    ///      **Deliberately ONE test rather than four, and the reason is a trap worth recording.** `forge` reverts EVM
    ///      state between tests but the FILESYSTEM is shared, and this harness is config-driven, so it must write
    ///      fixture files. Four tests each cleaning up after themselves means the first to finish deletes the config
    ///      the others are still using — which showed up as `AssetKindMissingOrInvalid` and a failed `removeFile` in
    ///      two of four, i.e. as if the SCRIPT were broken rather than the harness. One `run()` with grouped
    ///      assertions removes the shared-state hazard entirely, and each assertion carries its own message so a
    ///      failure still names the property that broke.
    function test_08_wiresBothDirectionsAndLeavesTheReadSurfaceAnswerable() public {
        script.run();

        address registry = address(nav.assetKindRegistry());
        bool granted = registry == address(0) ? false : nav.hasRole(MANAGER, registry);
        address boundNav = registry == address(0) ? address(0) : address(AssetKindRegistry(registry).NAV());

        // The read surface is what the pointer exists FOR, so exercise it rather than only inspecting the slot: a
        // pointer that is set but unusable would satisfy the slot assertion and still fail here. USDC is classified
        // by the fixture and carries no labels, so an empty list is the correct answer — the call RETURNING at all is
        // the property under test.
        uint256 labelCount = type(uint256).max;
        if (registry != address(0)) {
            (,, string[] memory labels) = nav.getAssetInfo(USDC);
            labelCount = labels.length;
        }

        // A second run must not revert, and must leave the NAV correctly wired.
        //
        // ⚠️ It must NOT assert the address is unchanged, and the reason is a real property of the script rather than
        // a concession: `08`'s deploy-skip guard reads the deployment RECORD, and `saveDeployedAddress` writes that
        // record only under `PERSIST_DEPLOYMENTS=1`. Without the flag a re-run cannot see the first registry and
        // deploys a second — which `08`'s own docstring states. Asserting address stability here would therefore pin
        // an environment variable, not the script, and it failed exactly that way when first written.
        //
        // Setting the flag from inside the test was rejected: `vm.setEnv` mutates the process environment for every
        // suite sharing the run, which would quietly authorise OTHER script tests to write real config files.
        script.run();
        address afterRerun = address(nav.assetKindRegistry());
        address afterRerunBound = afterRerun == address(0) ? address(0) : address(AssetKindRegistry(afterRerun).NAV());

        _cleanup();

        // READ direction — the one that was missing entirely, and the reason this harness exists.
        assertTrue(registry != address(0), "READ: the NAV must point back at the registry 08 deployed");
        assertEq(boundNav, address(nav), "READ: and it must be the registry bound to THIS nav, not another");
        // WRITE direction — asserted alongside, because the defect was assuming the two move together.
        assertTrue(granted, "WRITE: the registry must hold MANAGER on the NAV");
        // The surface itself.
        assertEq(labelCount, 0, "getAssetInfo must ANSWER, not revert; no labels configured so empty is correct");
        // Idempotence.
        assertTrue(afterRerun != address(0), "a second run must not leave the NAV unwired");
        assertEq(afterRerunBound, address(nav), "and whatever it points at after a re-run must be bound to THIS nav");
    }
}

/// @title RegisterAssetsWiringGuardTest
/// @notice L2 — drives the failure branch of `RegisterAssets`'s NAV-points-back guard.
/// @dev **A separate contract with its own fixture chain id, deliberately.** `forge` reverts EVM state between tests
///      but shares the FILESYSTEM, so two config-driven suites on the same fixture id would delete each other's
///      config mid-run — which presents as the SCRIPT failing rather than the harness, and cost two false failures
///      before it was understood.
///
///      **What this pins.** `08` writes the NAV→registry pointer, but `08` is four sequential broadcast transactions
///      and any one can fail alone. When the pointer transaction is the one that fails, registration still succeeds
///      and every `getAssetInfo` reverts forever. This guard makes that state stop at the NEXT step instead of
///      surviving to production — the same shape as a dead facade now blocking at the first asset.
///
///      It is not a guard for an unreachable state: it is reachable exactly when `08` partially failed.
contract RegisterAssetsWiringGuardTest is Test {
    uint256 internal constant FIXTURE_CHAIN = 987_654_332;
    address internal constant BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    NAVCalculator internal nav;
    RegisterAssets internal script;
    address internal strayRegistry;

    string internal chainPath;
    string internal assetsPath;
    string internal deploymentsPath;

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory id = vm.toString(FIXTURE_CHAIN);
        chainPath = string(abi.encodePacked(root, "/script/config/chains/", id, ".json"));
        assetsPath = string(abi.encodePacked(root, "/script/config/nav-config/assets-and-price-feeds/", id, ".json"));
        deploymentsPath = string(abi.encodePacked(root, "/script/config/deployments/", id, ".json"));

        assertFalse(vm.exists(chainPath), "fixture chain config must be unoccupied");
        assertFalse(vm.exists(assetsPath), "fixture assets config must be unoccupied");
        assertFalse(vm.exists(deploymentsPath), "fixture deployments record must be unoccupied");

        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        address impl = address(new NAVCalculator());
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                impl, abi.encodeCall(NAVCalculator.initialize, (BROADCASTER, address(0), "ETH"))
            )
        );

        // `setAssetKindRegistry` is MANAGER-gated, and `initialize` grants only DEFAULT_ADMIN. The accepting-side test
        // needs to wire the NAV, so grant it here rather than inside that test — the roles are setup, not the subject.
        vm.prank(BROADCASTER);
        nav.grantRole(MANAGER, BROADCASTER);

        // A registry that exists and is recorded, bound to this NAV — but which the NAV was never pointed at. This is
        // exactly the state `08` leaves behind when its pointer transaction alone fails.
        strayRegistry = address(new AssetKindRegistry(address(nav)));

        vm.writeFile(
            chainPath,
            string(
                abi.encodePacked(
                    '{"name":"RegisterAssetsGuardFixture","rpc":"http://127.0.0.1:8545","explorer":"",',
                    '"explorerApiKey":"","chainlinkSequencerFeed":"0x0000000000000000000000000000000000000000",',
                    '"nativeTokenSymbol":"ETH","addresses":{"admin":"',
                    vm.toString(BROADCASTER),
                    '","manager":"',
                    vm.toString(BROADCASTER),
                    '","securityCouncil":"',
                    vm.toString(BROADCASTER),
                    '"}}'
                )
            )
        );
        vm.writeFile(assetsPath, "{}");
        vm.writeFile(
            deploymentsPath,
            string(
                abi.encodePacked(
                    '{"NAVCalculatorProxy":"',
                    vm.toString(address(nav)),
                    '","AssetKindRegistry":"',
                    vm.toString(strayRegistry),
                    '"}'
                )
            )
        );

        script = new RegisterAssets();
        vm.chainId(FIXTURE_CHAIN);
    }

    function _cleanup() internal {
        if (vm.exists(chainPath)) vm.removeFile(chainPath);
        if (vm.exists(assetsPath)) vm.removeFile(assetsPath);
        if (vm.exists(deploymentsPath)) vm.removeFile(deploymentsPath);
    }

    /// @dev **Both sides of the guard in ONE test, for the same reason as the harness above** — and this one bit
    ///      twice before it was understood, so it is worth stating exactly. `forge` snapshots state after `setUp` and
    ///      reverts EVM state between tests, but `setUp`'s FILESYSTEM writes happen ONCE and are not reverted. So the
    ///      first test to clean up strands every later test in the same contract, which surfaces as `removeFile: No
    ///      such file` — a harness fault wearing the costume of a script fault.
    ///
    ///      **Rejecting side:** the NAV points at `address(0)` while the record names a real, correctly-bound
    ///      registry, so the script must refuse rather than register assets the NAV can never describe. Asserted on
    ///      the SPECIFIC error — a bare `expectRevert` would pass on any revert, including an unrelated config
    ///      failure, which is how a guard gets credited for a stop it did not cause.
    ///
    ///      **Accepting side:** once the NAV is wired, the script proceeds. Without it, the rejecting assertion would
    ///      pass equally well against a guard that refuses unconditionally.
    function test_registerAssets_refusesUnlessTheNavPointsBack() public {
        bytes memory expected = abi.encodeWithSelector(
            RegisterAssets.NavNotPointedAtAssetKindRegistry.selector, address(nav), address(0), strayRegistry
        );
        vm.expectRevert(expected);
        script.run();

        // Wire it, and the same call proceeds. The assets config is empty, so there is nothing to plan — the point is
        // that the guard does not fire.
        vm.prank(BROADCASTER);
        nav.setAssetKindRegistry(strayRegistry);
        script.run();

        _cleanup();
    }
}
