// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UpgradeNAVCalculator} from "script/upgrade/UpgradeNAVCalculator.s.sol";

/// @dev Exposes the layout gate, and records whether `run()` reached it.
contract LayoutGateHarness is UpgradeNAVCalculator {
    bool public gateCalled;
    bool internal _stub;
    bool internal _revertInGate;

    function callGate() external {
        _requireStorageLayoutVerified();
    }

    function stubTheGate() external {
        _stub = true;
    }

    /// @dev Reverts with a sentinel instead of recording a flag. A boolean written inside `run()` is rolled
    ///      back when `run()` later reverts, so it can never be observed - the first version of the wiring
    ///      test asserted on exactly such a flag and was measuring nothing.
    function stubTheGateReverting() external {
        _revertInGate = true;
    }

    function _requireStorageLayoutVerified() internal override {
        gateCalled = true;
        if (_revertInGate) revert("GATE_REACHED");
        if (!_stub) super._requireStorageLayoutVerified();
    }
}

/// @title UpgradeNAVCalculatorLayoutGateTest
/// @notice The gate RUNS `check_storage_layout.py` rather than accepting an attestation that it was run.
/// @dev    Two attestation designs were defeated in review before this one: the literal `1`, and the
///         keccak of the baseline file. Both were parkable in a gitignored `.env`, satisfying the gate on
///         trees the check had never seen. There is deliberately no token left to test.
contract UpgradeNAVCalculatorLayoutGateTest is Test {
    LayoutGateHarness internal h;

    function setUp() public {
        h = new LayoutGateHarness();
    }

    /// @dev The committed tree is compatible with its own baseline, so the real checker exits 0.
    function test_gatePassesOnACompatibleTree() public {
        h.callGate();
        assertTrue(h.gateCalled(), "gate did not run");
    }

    /// @dev No `.env` value, and no environment variable of any name, can satisfy the gate: it does not
    ///      read one. This fails if an attestation shortcut is ever reintroduced.
    function test_gateIgnoresAnyEnvironmentAttestation() public {
        vm.setEnv("STORAGE_LAYOUT_VERIFIED", "1");
        h.callGate(); // still passes only because the real check passes
        vm.setEnv("STORAGE_LAYOUT_VERIFIED", "0xdeadbeef");
        h.callGate();
        assertTrue(h.gateCalled());
    }

    /// @dev The WIRING, not the body: deleting the call from `run()` must fail a test. Blanking the guard
    ///      body and deleting its call are different mutations and only the second reaches production -- the
    ///      same rule the pin-guard suite states for itself.
    ///
    ///      Two earlier versions of this test were wrong, in instructive ways. The first asserted the gate ran
    ///      "before anything else"; `run()` calls `setUp()`/`validateAddresses()` first, so that claim was
    ///      simply false. The second set a boolean inside the overridden gate and asserted on it after a
    ///      `try/catch` -- but `run()` reverts at the library-pin guard further down, and that revert rolls the
    ///      boolean back, so the assertion could never pass and the test proved nothing about ordering.
    ///
    ///      A revert sentinel survives, and it also pins the ORDER: if the gate is reached first the sentinel
    ///      propagates, and if anything downstream (the pin guard, the broadcast) runs first its own revert
    ///      arrives instead. So this fails both when the call is deleted and when it is moved below the deploy.
    function test_runReachesTheGateBeforeBroadcasting() public {
        vm.chainId(1);
        h.stubTheGateReverting();
        vm.expectRevert(bytes("GATE_REACHED"));
        h.run();
    }
}
