// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title Constants Invariant Tests
/// @notice Tests invariants and boundaries for global constants used in NAV and bridge
contract ConstantsInvariantTest is Test {
    /// @notice NAV_DECIMALS is the canonical USD precision (8 decimals)
    function test_invariant_navDecimals_is8() public pure {
        assertEq(NAV_DECIMALS, 8, "NAV_DECIMALS must be 8");
    }

    /// @notice MAX_DECIMAL_EXPONENT_INT256 must be <= MAX_DECIMAL_EXPONENT (exponent used in both uint and int contexts)
    function test_invariant_maxDecimalExponentInt256WithinMax() public pure {
        assertLe(
            MAX_DECIMAL_EXPONENT_INT256,
            MAX_DECIMAL_EXPONENT,
            "MAX_DECIMAL_EXPONENT_INT256 must be <= MAX_DECIMAL_EXPONENT"
        );
    }

    /// @notice 10^MAX_DECIMAL_EXPONENT_INT256 must fit in int256 (used in _toUsd / _fromUsd)
    function test_invariant_tenToMaxInt256ExponentFitsInInt256() public pure {
        uint256 pow = 10 ** MAX_DECIMAL_EXPONENT_INT256;
        assertLe(pow, uint256(type(int256).max), "10^MAX_DECIMAL_EXPONENT_INT256 must fit in int256");
    }

    /// @notice 10^(MAX_DECIMAL_EXPONENT_INT256 + 1) must exceed int256 max (boundary; 77 overflows)
    function test_invariant_tenToMaxInt256PlusOneOverflowsInt256() public pure {
        uint256 pow77 = 10 ** (MAX_DECIMAL_EXPONENT_INT256 + 1);
        assertGt(pow77, uint256(type(int256).max), "10^77 must overflow int256 (validates constant 76)");
    }

    /// @notice Role IDs must be distinct (no accidental overlap)
    function test_invariant_roleIdsDistinct() public pure {
        assertTrue(MANAGER != DEFAULT_ADMIN_ROLE, "MANAGER != DEFAULT_ADMIN_ROLE");
    }

    /// @notice DEFAULT_ADMIN_ROLE must be 0x00 (OpenZeppelin AccessControl convention)
    function test_invariant_defaultAdminRoleIsZero() public pure {
        assertEq(DEFAULT_ADMIN_ROLE, bytes32(0), "DEFAULT_ADMIN_ROLE must be 0x00");
    }
}
