// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";

/// @title DormantInstanceCleanupForkTest
/// @author KPK
/// @notice Rehearses the five-transaction cleanup of the dormant meta-instance set left on the
///         2026-08-26 PolygonStakingMeta predecessor, before any of it is broadcast.
/// @dev Removing a meta adapter does not clear its instance set (`Balances.sol:190`), and
///      `addMetaBalanceAdapter` APPENDS and accepts an empty list — so re-registering the superseded
///      `0x59039882…` revives validator 192 alongside the live adapter and NAV sums both (+$11,375.92,
///      no health flag). The set cannot be cleared directly because `removeMetaInstances` reverts
///      `InvalidBalanceAdapter` for an unregistered adapter, which is what forces this ordering.
///
///      **The property under test is that the two adapters are NEVER both reporting.** Every
///      intermediate state must be an under-report (the position missing) and never an over-report.
///      Asserted after each step rather than only at the end, because a sequencing error would show up
///      as a transient double-count that a final-state check cannot see.
contract DormantInstanceCleanupForkTest is Test, TestEnvConfigurator {
    uint256 constant FORK_BLOCK = 25870316;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant MANAGER_EOA = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    address constant LIVE = 0x5144b5855e753Fa6E2BBac95Cc880A73e1eec187;
    address constant RESIDUE = 0x590398827f2a2709e80DF9BD5C7D02BD51FC51fD;
    bytes32 constant V192 = bytes32(uint256(uint160(0x97997023aAB1D6b9760538Eb621bF10cfCD84868)));

    function setUp() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _addrs(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    /// @dev How many REGISTERED adapters currently advertise validator 192. Must never exceed 1.
    function _reporters() internal view returns (uint256 n) {
        address[2] memory cands = [LIVE, RESIDUE];
        for (uint256 i; i < 2; ++i) {
            if (!NAVCalculator(NAV).isAdapterRegistered(cands[i])) continue;
            bytes32[] memory inst = NAVCalculator(NAV).getMetaInstances(cands[i]);
            for (uint256 j; j < inst.length; ++j) {
                if (inst[j] == V192) ++n;
            }
        }
    }

    function test_fiveStepCleanup_neverDoubleCounts() public {
        assertTrue(NAVCalculator(NAV).isAdapterRegistered(LIVE), "precondition: live registered");
        assertFalse(NAVCalculator(NAV).isAdapterRegistered(RESIDUE), "precondition: residue deregistered");
        assertEq(NAVCalculator(NAV).getMetaInstances(RESIDUE).length, 1, "precondition: residue holds v192");
        assertEq(_reporters(), 1, "precondition: exactly one reporter");

        vm.startPrank(MANAGER_EOA);

        NAVCalculator(NAV).removeMetaInstances(LIVE, _one(V192));
        assertEq(_reporters(), 0, "step 1: expected an under-report window");

        NAVCalculator(NAV).addMetaBalanceAdapter(RESIDUE, new bytes32[](0));
        assertEq(_reporters(), 1, "step 2: residue must be the ONLY reporter -- a 2 here is the double-count");

        NAVCalculator(NAV).removeMetaInstances(RESIDUE, _one(V192));
        assertEq(_reporters(), 0, "step 3: under-report window");

        NAVCalculator(NAV).removeBalanceAdapters(_addrs(RESIDUE));
        assertEq(_reporters(), 0, "step 4: under-report window");

        NAVCalculator(NAV).addMetaInstances(LIVE, _one(V192));
        vm.stopPrank();

        assertEq(_reporters(), 1, "final: exactly one reporter");
        assertTrue(NAVCalculator(NAV).isAdapterRegistered(LIVE), "final: live still registered");
        assertFalse(NAVCalculator(NAV).isAdapterRegistered(RESIDUE), "final: residue deregistered again");
        assertEq(NAVCalculator(NAV).getMetaInstances(RESIDUE).length, 0, "final: RESIDUE SET MUST BE EMPTY");
        assertEq(NAVCalculator(NAV).getMetaInstances(LIVE).length, 1, "final: live holds v192");
        assertEq(NAVCalculator(NAV).getMetaInstances(LIVE)[0], V192, "final: live holds the RIGHT coordinate");
    }

    /// @notice The ordering matters: registering the residue FIRST double-counts.
    /// @dev Revert-probe for the sequence itself. If this ever stops double-counting, the underlying
    ///      append-on-register behaviour has changed and the five-step dance may no longer be needed.
    function test_wrongOrder_doubleCounts() public {
        vm.prank(MANAGER_EOA);
        NAVCalculator(NAV).addMetaBalanceAdapter(RESIDUE, new bytes32[](0));
        assertEq(_reporters(), 2, "expected the naive ordering to double-count");
    }
}
