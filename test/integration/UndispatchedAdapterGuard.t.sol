// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UndispatchedAdapterGuard} from "test/integration/UndispatchedAdapterGuard.sol";

/// @dev The guard's failing paths are `revert`s inside an `internal` library function, which is INLINED into
///      whatever calls it — so `vm.expectRevert` cannot see them without a real CALL boundary. This harness
///      supplies one. Without it every "reverts" test below would pass vacuously.
contract GuardHarness {
    function check(Vm vm, string memory json, uint256 chainId, string[] memory skipped) external view {
        UndispatchedAdapterGuard.checkAgainst(vm, json, chainId, skipped);
    }

    function checkRealFile(Vm vm, uint256 chainId, string[] memory skipped) external view {
        UndispatchedAdapterGuard.check(vm, chainId, skipped);
    }
}

/// @title UndispatchedAdapterGuardTest
/// @author KPK
/// @notice Non-fork tests for the guard that stops an enabled-but-undispatched balance adapter from being
///         silently skipped by the integration harness (see {UndispatchedAdapterGuard} for the hazard: a
///         never-deployed adapter reports 0, and a snapshot refresh pins that under-report as the expected NAV).
/// @dev Two layers. The first exercises the mechanism against synthetic declarations. The second points the
///      guard at the REAL tracked `undispatched-adapters.json` and pins its exact contents, so this file fails
///      if someone adds a dispatch branch without deleting the matching declaration, or declares an adapter
///      that is not actually skipped. The end-to-end wiring (the harness calling the guard) is exercised by the
///      integration fork tests, which is also where the refresh hazard lives.
contract UndispatchedAdapterGuardTest is Test {
    GuardHarness internal harness;

    /// @dev The six chain-1 names, verified against `origin/main`'s deploy config and dispatch chain on
    ///      2026-07-30 rather than transcribed: every adapter `enabled: true` in
    ///      contracts-deployment-config/{balance-adapters,meta-balance-adapters}/1.json that no
    ///      `_equals`/`_startsWith` branch in `_deployBalanceAdapter` resolves.
    string[] internal CHAIN_1_SKIPPED = [
        "EthenaCooldown",
        "EtherFiWithdrawalQueueAssisted",
        "EulerVaultsMeta",
        "LidoWithdrawalQueue",
        "NexusMutualStakingPoolsAssisted",
        "StakeWiseV3ExitQueueAssisted"
    ];

    function setUp() public {
        harness = new GuardHarness();
    }

    // -----------------------------------------------------------------------
    // Mechanism — synthetic declarations
    // -----------------------------------------------------------------------

    function test_passes_whenSkippedMatchesDeclarationExactly() public view {
        harness.check(
            vm, '{"chains":{"1":{"Foo":"declared because X","Bar":"declared because Y"}}}', 1, _arr("Foo", "Bar")
        );
    }

    function test_reverts_whenSkippedNameIsNotDeclared() public {
        vm.expectRevert(
            abi.encodeWithSelector(UndispatchedAdapterGuard.UndispatchedAdapterNotDeclared.selector, 1, "Bar")
        );
        harness.check(vm, '{"chains":{"1":{"Foo":"declared because X"}}}', 1, _arr("Foo", "Bar"));
    }

    /// @notice An empty reason must fail, otherwise a deliberate omission is indistinguishable from someone
    ///         silencing the guard with a placeholder.
    function test_reverts_whenDeclaredReasonIsEmpty() public {
        vm.expectRevert(
            abi.encodeWithSelector(UndispatchedAdapterGuard.UndispatchedAdapterReasonMissing.selector, 1, "Foo")
        );
        harness.check(vm, '{"chains":{"1":{"Foo":""}}}', 1, _arr("Foo"));
    }

    /// @notice The reverse direction: a declaration for something that is no longer skipped (dispatch branch
    ///         added, or adapter disabled) must fail, so exemptions cannot accumulate unnoticed.
    function test_reverts_whenDeclarationIsStale() public {
        vm.expectRevert(
            abi.encodeWithSelector(UndispatchedAdapterGuard.UndispatchedAdapterDeclarationStale.selector, 1, "Bar")
        );
        harness.check(vm, '{"chains":{"1":{"Foo":"because X","Bar":"because Y"}}}', 1, _arr("Foo"));
    }

    function test_passes_whenChainAbsentFromDeclarationAndNothingSkipped() public view {
        harness.check(vm, '{"chains":{"1":{"Foo":"because X"}}}', 8453, new string[](0));
    }

    /// @notice Declarations are per chain: chain 1's entry must not excuse the same name on chain 8453.
    function test_declarationIsPerChain() public {
        vm.expectRevert(
            abi.encodeWithSelector(UndispatchedAdapterGuard.UndispatchedAdapterNotDeclared.selector, 8453, "Foo")
        );
        harness.check(vm, '{"chains":{"1":{"Foo":"because X"}}}', 8453, _arr("Foo"));
    }

    /// @notice A `$`-prefixed key is prose, not an adapter, so it must not read as a stale declaration.
    function test_dollarPrefixedKeysAreProse() public view {
        harness.check(vm, '{"chains":{"1":{"$note":"prose","Foo":"because X"}}}', 1, _arr("Foo"));
    }

    // -----------------------------------------------------------------------
    // The real tracked declaration
    // -----------------------------------------------------------------------

    /// @notice The real file accepts exactly today's chain-1 skipped set.
    function test_realDeclaration_acceptsChain1SkippedSet() public view {
        harness.checkRealFile(vm, 1, CHAIN_1_SKIPPED);
    }

    function test_realDeclaration_acceptsChain100SkippedSet() public view {
        harness.checkRealFile(vm, 100, _arr("StakeWiseV3ExitQueueAssisted"));
    }

    /// @notice Chains that dispatch everything must declare nothing.
    function test_realDeclaration_chainsWithNoSkipsDeclareNothing() public view {
        harness.checkRealFile(vm, 10, new string[](0));
        harness.checkRealFile(vm, 8453, new string[](0));
        harness.checkRealFile(vm, 42161, new string[](0));
    }

    /// @notice PROOF IT BITES, against the real file rather than a synthetic one: a newly added adapter that
    ///         nobody declared fails the guard. This is the scenario the tripwire exists for.
    function test_realDeclaration_bites_whenANewAdapterIsUndeclared() public {
        string[] memory withNewAdapter = new string[](CHAIN_1_SKIPPED.length + 1);
        for (uint256 i; i < CHAIN_1_SKIPPED.length; ++i) {
            withNewAdapter[i] = CHAIN_1_SKIPPED[i];
        }
        withNewAdapter[CHAIN_1_SKIPPED.length] = "SomeBrandNewAdapterNobodyDeclared";
        vm.expectRevert(
            abi.encodeWithSelector(
                UndispatchedAdapterGuard.UndispatchedAdapterNotDeclared.selector, 1, "SomeBrandNewAdapterNobodyDeclared"
            )
        );
        harness.checkRealFile(vm, 1, withNewAdapter);
    }

    /// @notice PROOF IT BITES, other direction: dropping one name from the skipped set — equivalent to adding
    ///         its dispatch branch, or to removing it from the declaration — fails against the real file. Run
    ///         once per declared chain-1 name so no single entry is exempt from the check.
    function test_realDeclaration_bites_whenADeclarationGoesStale() public {
        for (uint256 drop; drop < CHAIN_1_SKIPPED.length; ++drop) {
            string[] memory withoutOne = new string[](CHAIN_1_SKIPPED.length - 1);
            uint256 k;
            for (uint256 i; i < CHAIN_1_SKIPPED.length; ++i) {
                if (i != drop) withoutOne[k++] = CHAIN_1_SKIPPED[i];
            }
            vm.expectRevert(
                abi.encodeWithSelector(
                    UndispatchedAdapterGuard.UndispatchedAdapterDeclarationStale.selector, 1, CHAIN_1_SKIPPED[drop]
                )
            );
            harness.checkRealFile(vm, 1, withoutOne);
        }
    }

    /// @notice Every declared reason is non-empty. Reading each one explicitly rather than relying on the
    ///         accept-path above, so an empty reason is reported as such instead of as a generic failure.
    function test_realDeclaration_everyReasonIsNonEmpty() public view {
        string memory json = vm.readFile(UndispatchedAdapterGuard.DECLARATION_PATH);
        _assertReasonsNonEmpty(json, 1, CHAIN_1_SKIPPED);
        _assertReasonsNonEmpty(json, 100, _arr("StakeWiseV3ExitQueueAssisted"));
    }

    function _assertReasonsNonEmpty(string memory json, uint256 chainId, string[] memory names) internal pure {
        for (uint256 i; i < names.length; ++i) {
            string memory reason =
                vm.parseJsonString(json, string.concat(".chains.", vm.toString(chainId), ".", names[i]));
            assertGt(bytes(reason).length, 0, string.concat("empty reason for ", names[i]));
        }
    }

    function _arr(string memory a) internal pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = a;
    }

    function _arr(string memory a, string memory b) internal pure returns (string[] memory out) {
        out = new string[](2);
        out[0] = a;
        out[1] = b;
    }
}
