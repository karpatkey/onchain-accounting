// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseDeployScript} from "../../script/utils/BaseDeployScript.sol";

/// @dev Minimal concrete subclass exposing both halves of the guard: the `pure` allowlist predicate, and the
///      env-reading wrapper reached from `setUp()`.
contract GuardHarness is BaseDeployScript {
    function run() public override {}

    function checkName(string memory profile) external pure {
        _assertDeployProfileName(profile);
    }

    function runSetUp() external {
        setUp();
    }
}

/// @title DeployProfileGuardTest
/// @notice Guards the build-profile assertion on the deploy path (escalated out of PR #156).
/// @dev Why it matters: under a profile that clears `foundry.toml`'s `libraries` array — `dev` today, `lite` once #156
///      lands — `01_DeployImplementations` would CREATE2-deploy unoptimized libraries at non-pinned addresses, and the
///      canonical factory returns `address(0)` instead of reverting, so the run logs success and records a bogus
///      address. `01` carries no `LibraryPins` assertions of its own.
///
///      The profile matrix is driven through the `pure` predicate rather than `vm.setEnv`. `vm.setEnv` mutates the
///      process environment for the entire `forge test` run, and an earlier version of this suite that used it leaked
///      values between its own cases — `test_allows_default` failed reading `"lite"`. Exactly one test below mutates
///      the env, to prove the wiring.
contract DeployProfileGuardTest is Test {
    GuardHarness internal harness;

    function setUp() public {
        harness = new GuardHarness();
    }

    function _expectRejected(string memory profile) internal {
        vm.expectRevert(abi.encodeWithSelector(BaseDeployScript.DeployProfileNotAllowed.selector, profile));
        harness.checkName(profile);
    }

    // --- allowed -------------------------------------------------------------

    function test_allows_default() public view {
        harness.checkName("default");
    }

    /// @notice `slow` is required, not merely tolerated: the redeploy runbook runs `RegisterAssets` under it because
    ///         mainnet's 43 assets otherwise `MemoryOOG`. If this starts reverting, the runbook breaks.
    function test_allows_slow() public view {
        harness.checkName("slow");
    }

    /// @notice Empty means forge's own default, which is deploy-valid. Covers both `FOUNDRY_PROFILE` unset and
    ///         `FOUNDRY_PROFILE=` exported empty.
    function test_allows_empty() public view {
        harness.checkName("");
    }

    // --- refused -------------------------------------------------------------

    /// @notice `dev` clears the `libraries` array, so its artifacts link no libraries.
    function test_rejects_dev() public {
        _expectRejected("dev");
    }

    /// @notice The profile PR #156 introduces. It does NOT exist in `foundry.toml` on this branch — that is the point:
    ///         an allowlist refuses profiles that do not exist yet, so #156 needs no follow-up here.
    function test_rejects_lite_beforeItExists() public {
        _expectRejected("lite");
    }

    function test_rejects_coverage() public {
        _expectRejected("coverage");
    }

    function test_rejects_unknownProfile() public {
        _expectRejected("definitely-not-a-profile");
    }

    /// @notice Case-sensitive by construction — `keccak256` of the name. `DEFAULT` is not `default`, and silently
    ///         accepting it would accept a profile that does not exist.
    function test_rejects_wrongCase() public {
        _expectRejected("DEFAULT");
    }

    /// @notice Substring and whitespace variants are refused; a name is matched whole.
    function test_rejects_nearMisses() public {
        _expectRejected("default ");
        _expectRejected("defaul");
        _expectRejected("default,slow");
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

    // --- wiring --------------------------------------------------------------

    /// @notice The guard is reached from `setUp()`, not merely available — this is what makes it cover all 18
    ///         `BaseDeployScript` subclasses without touching any of them. Also pins that the guard runs BEFORE the
    ///         chain-config read, so an unconfigured chain cannot mask it with a different error: chain 31337 has no
    ///         `script/config/chains/31337.json`, yet the profile error is what surfaces.
    /// @dev The one test here that mutates the process environment. It restores immediately, and no other test in this
    ///      file reads the env, so the mutation cannot affect them.
    function test_guardRunsFromSetUp_beforeChainConfig() public {
        string memory original = vm.envOr("FOUNDRY_PROFILE", string(""));
        vm.chainId(31337);
        vm.setEnv("FOUNDRY_PROFILE", "lite");
        vm.expectRevert(abi.encodeWithSelector(BaseDeployScript.DeployProfileNotAllowed.selector, "lite"));
        harness.runSetUp();
        vm.setEnv("FOUNDRY_PROFILE", original);
    }

    function _stripSelector(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }
}
