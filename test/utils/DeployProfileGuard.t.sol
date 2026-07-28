// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {BaseDeployScript} from "../../script/utils/BaseDeployScript.sol";

/// @dev Concrete subclass exposing the guard's `pure` decisions, plus an injectable profile so the `setUp()` wiring can
///      be exercised WITHOUT `vm.setEnv`. That matters: `setEnv` mutates the process environment for the whole
///      `forge test` run, test contracts execute in parallel (`threads` resolves to the core count on the default
///      profile), and forge-std has no `unsetEnv` — so an env-driven test cannot restore what it inherited and cannot
///      bound its blast radius to one file. This suite therefore mutates no shared state whatsoever.
///
///      `_assertNoBytecodeOverrides` is deliberately NOT overridden: none of the `FOUNDRY_*` keys is set in a normal
///      test environment (CI sets only `FOUNDRY_PROFILE`), so the real env plumbing runs on the allow path and is
///      exercised for free by `test_wiring_allowedProfileProceedsPastGuard`.
contract GuardHarness is BaseDeployScript {
    string private _profile = "default";

    function run() public override {}

    function setProfile(string memory profile) external {
        _profile = profile;
    }

    function _activeProfile() internal view override returns (string memory) {
        return _profile;
    }

    function checkName(string memory profile) external pure {
        _assertDeployProfileName(profile);
    }

    function checkOverride(string memory key, bool isSet, string memory value) external pure {
        _assertNotOverridden(key, isSet, value);
    }

    function overrideKeys() external pure returns (string[8] memory) {
        return _bytecodeOverrideKeys();
    }

    function runSetUp() external {
        setUp();
    }
}

/// @dev Second harness whose only job is to prove the override check is CALLED. The override decision is `pure` and
///      tested directly, which means deleting the `_assertNoBytecodeOverrides()` call from `_assertDeployProfile()`
///      would leave those tests green — the exact "passes with the change reverted" trap. Overriding it with a sentinel
///      revert detects the missing call site without setting any `FOUNDRY_*` variable (which could not be unset again
///      and would then trip the guard for every later test in the process).
contract OverrideWiringHarness is BaseDeployScript {
    error OverrideCheckReached();

    function run() public override {}

    function _activeProfile() internal view override returns (string memory) {
        return "default";
    }

    function _assertNoBytecodeOverrides() internal view override {
        revert OverrideCheckReached();
    }

    function runSetUp() external {
        setUp();
    }
}

/// @title DeployProfileGuardTest
/// @notice Guards the build-profile assertion on the deploy path (escalated out of PR #156).
/// @dev Why it matters: under a profile that clears `foundry.toml`'s `libraries` array — `dev` today, `lite` once #156
///      lands — or under a `FOUNDRY_*` override that does the same, `01_DeployImplementations` would CREATE2-deploy
///      libraries at non-pinned addresses, and the canonical factory returns `address(0)` instead of reverting, so the
///      run logs success and records a bogus address. `01` carries no `LibraryPins` assertions of its own.
contract DeployProfileGuardTest is Test {
    /// @dev Chain with no `script/config/chains/<id>.json`, so `ConfigReader.readChainConfig` reverts. Used to prove
    ///      ordering: reaching that revert means the guard already passed.
    uint256 internal constant UNCONFIGURED_CHAIN_ID = 31337;

    GuardHarness internal harness;

    function setUp() public {
        harness = new GuardHarness();
    }

    function _expectRejected(string memory profile) internal {
        vm.expectRevert(abi.encodeWithSelector(BaseDeployScript.DeployProfileNotAllowed.selector, profile));
        harness.checkName(profile);
    }

    // --- profile allowlist: accepted ----------------------------------------

    function test_allows_default() public view {
        harness.checkName("default");
    }

    /// @notice `slow` is required, not merely tolerated: the redeploy runbook runs `RegisterAssets` under it because
    ///         mainnet's 43 assets otherwise `MemoryOOG`. If this starts reverting, the documented deploy breaks.
    function test_allows_slow() public view {
        harness.checkName("slow");
    }

    /// @notice Empty means forge's own default. Covers both `FOUNDRY_PROFILE` unset and exported empty.
    function test_allows_empty() public view {
        harness.checkName("");
    }

    // --- profile allowlist: refused -----------------------------------------

    /// @notice `dev`'s entire body is `libraries = []`, so its artifacts link libraries at unpinned addresses.
    function test_rejects_dev() public {
        _expectRejected("dev");
    }

    /// @notice The profile PR #156 introduces. It does NOT exist in `foundry.toml` on this branch — that is the point:
    ///         an allowlist refuses profiles that do not exist yet, so #156 needs no follow-up here.
    function test_rejects_lite_beforeItExists() public {
        _expectRejected("lite");
    }

    /// @notice Refused despite being bytecode-identical to `default`, because nothing runs a deploy script under it.
    ///         Pins the second half of the documented allowlisting criterion.
    function test_rejects_coverage() public {
        _expectRejected("coverage");
    }

    function test_rejects_unknownProfile() public {
        _expectRejected("definitely-not-a-profile");
    }

    /// @notice Case-sensitive by construction (`keccak256` of the name); `DEFAULT` is not a profile that exists.
    function test_rejects_wrongCase() public {
        _expectRejected("DEFAULT");
    }

    // Near-misses, one per test so a regression in the first does not hide the others.

    function test_rejects_trailingSpace() public {
        _expectRejected("default ");
    }

    function test_rejects_truncatedName() public {
        _expectRejected("defaul");
    }

    function test_rejects_commaJoinedNames() public {
        _expectRejected("default,slow");
    }

    // --- FOUNDRY_* bytecode overrides ---------------------------------------

    /// @notice An override that is merely PRESENT is refused, including when exported empty — which is exactly the
    ///         dangerous shape: `FOUNDRY_LIBRARIES=` resolves to `libraries: [""]`, i.e. the pins are dropped, while
    ///         the profile name stays `default`.
    function test_rejects_presentOverride_evenWhenEmpty() public {
        vm.expectRevert(
            abi.encodeWithSelector(BaseDeployScript.DeployConfigOverridden.selector, "FOUNDRY_LIBRARIES", "")
        );
        harness.checkOverride("FOUNDRY_LIBRARIES", true, "");
    }

    function test_rejects_presentOverride_withValue() public {
        vm.expectRevert(
            abi.encodeWithSelector(BaseDeployScript.DeployConfigOverridden.selector, "FOUNDRY_OPTIMIZER", "false")
        );
        harness.checkOverride("FOUNDRY_OPTIMIZER", true, "false");
    }

    function test_allows_absentOverride() public view {
        harness.checkOverride("FOUNDRY_LIBRARIES", false, "");
    }

    /// @notice Pins the key list itself. Each of these was confirmed against `forge config` to change the resolved
    ///         build: LIBRARIES -> `[""]`, OPTIMIZER -> false, VIA_IR -> false, EVM_VERSION -> osaka,
    ///         BYTECODE_HASH -> ipfs. Dropping one silently reopens the bypass.
    function test_overrideKeyList_isPinned() public view {
        string[8] memory keys = harness.overrideKeys();
        assertEq(keys[0], "FOUNDRY_LIBRARIES");
        assertEq(keys[1], "FOUNDRY_OPTIMIZER");
        assertEq(keys[2], "FOUNDRY_OPTIMIZER_RUNS");
        assertEq(keys[3], "FOUNDRY_VIA_IR");
        assertEq(keys[4], "FOUNDRY_SOLC");
        assertEq(keys[5], "FOUNDRY_SOLC_VERSION");
        assertEq(keys[6], "FOUNDRY_EVM_VERSION");
        assertEq(keys[7], "FOUNDRY_BYTECODE_HASH");
    }

    // --- error payload -------------------------------------------------------

    /// @notice The error names the offending profile, so the operator need not guess which export is set.
    function test_errorCarriesTheProfileName() public {
        try harness.checkName("lite") {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), BaseDeployScript.DeployProfileNotAllowed.selector, "wrong selector");
            string memory reported = abi.decode(_stripSelector(err), (string));
            assertEq(reported, "lite", "error must name the offending profile");
        }
    }

    // --- setUp() wiring ------------------------------------------------------

    /// @notice The guard is reached from `setUp()` — this is what makes it cover all 18 `BaseDeployScript` subclasses
    ///         without editing any of them.
    function test_wiring_disallowedProfileBlocksSetUp() public {
        harness.setProfile("lite");
        vm.expectRevert(abi.encodeWithSelector(BaseDeployScript.DeployProfileNotAllowed.selector, "lite"));
        harness.runSetUp();
    }

    /// @notice The ALLOW direction, which is the half that silently bricks everything if it regresses: a wrong default
    ///         in `_activeProfile()`, or an over-broad override list, would make every one of the 18 operator scripts
    ///         revert out of `setUp()` while a reject-only suite stayed green.
    ///
    ///         Also proves ORDERING (the guard precedes the chain-config read) by error IDENTITY rather than by the
    ///         mere fact of a revert: with an allowed profile the failure must come from `ConfigReader`, i.e. execution
    ///         got past the guard. Paired with the test above — same call, disallowed profile, profile error — the two
    ///         together pin the order. This also exercises the real `_assertNoBytecodeOverrides` env plumbing, since
    ///         the harness does not stub it.
    function test_wiring_allowedProfileProceedsPastGuard() public {
        // Pin the precondition the ordering proof rests on, rather than assuming it: if someone adds a local-anvil
        // chain config, `readChainConfig` would stop reverting and this test would silently stop testing ordering.
        assertFalse(
            vm.exists(string.concat("script/config/chains/", vm.toString(UNCONFIGURED_CHAIN_ID), ".json")),
            "precondition: chain must have no config file, else the ordering proof is vacuous"
        );
        vm.chainId(UNCONFIGURED_CHAIN_ID);
        harness.setProfile("default");

        try harness.runSetUp() {
            fail();
        } catch (bytes memory err) {
            // Whatever ConfigReader raises, it must NOT be either guard error — that is the discriminator.
            if (err.length >= 4) {
                assertTrue(
                    bytes4(err) != BaseDeployScript.DeployProfileNotAllowed.selector,
                    "allowed profile must not be rejected by the profile guard"
                );
                assertTrue(
                    bytes4(err) != BaseDeployScript.DeployConfigOverridden.selector,
                    "no FOUNDRY_* override should be set in the test environment"
                );
            }
        }
    }

    /// @notice The override check is actually invoked from `_assertDeployProfile()`, and only AFTER the profile check
    ///         passes. Without this, deleting the call site would keep the whole suite green, because every other
    ///         override test drives the `pure` decision directly.
    function test_wiring_overrideCheckIsReached() public {
        OverrideWiringHarness h = new OverrideWiringHarness();
        vm.expectRevert(OverrideWiringHarness.OverrideCheckReached.selector);
        h.runSetUp();
    }

    function _stripSelector(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }
}
