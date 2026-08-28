// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

uint8 constant NAV_DECIMALS = 8;

// Maximum safe exponent for 10^N calculations (max uint8 is 255)
// Used to prevent overflow in decimal exponentiation operations
uint256 constant MAX_DECIMAL_EXPONENT = 255;

// Maximum exponent such that 10^N fits in int256 (10^77 > type(int256).max)
uint256 constant MAX_DECIMAL_EXPONENT_INT256 = 76;

// Define the MANAGER role ID, used across NAVCalculator and bridge system for operational management
bytes32 constant MANAGER = keccak256("MANAGER"); // 0xaf290d8680820aad922855f39b306097b20e28774d6c1ad35a20325630c3a02c

/// @dev Gates the SUBMIT surface of the attested balance-adapter family (ADR 0022). Deliberately NOT used to gate
///      the family's clears — those stay permissionless and stale-gated, because role-gating removal is what audit
///      finding L-02 flagged: a compromised role-holder could delete valid LIVE allocations.
bytes32 constant SUBMITTER = keccak256("SUBMITTER");

bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
