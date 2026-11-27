// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

uint8 constant NAV_DECIMALS = 8;

// Maximum safe exponent for 10^N calculations (max uint8 is 255)
// Used to prevent overflow in decimal exponentiation operations
uint256 constant MAX_DECIMAL_EXPONENT = 255;

// Maximum exponent such that 10^N fits in int256 (10^77 > type(int256).max)
uint256 constant MAX_DECIMAL_EXPONENT_INT256 = 76;

/// @dev Hard cap on how old a STALE price may be and still be used for valuation (ADR 0029). A feed past its
///      heartbeat keeps contributing its last-known price, flagged stale, until its `updatedAt` is this old; from
///      then on it is unusable and the asset prices at 0 (still flagged). Absolute rather than a multiple of the
///      heartbeat: heartbeats are liveness numbers that differ 300x across feeds for the same question ("is this
///      number still a fair value?"), and a multiple would re-introduce the value cliff after a short outage on
///      hourly feeds. Every registered finite primary heartbeat must be below it (enforced in preflight).
uint256 constant MAX_STALE_PRICE_AGE = 7 days;

// Define the MANAGER role ID, used across NAVCalculator and bridge system for operational management
bytes32 constant MANAGER = keccak256("MANAGER"); // 0xaf290d8680820aad922855f39b306097b20e28774d6c1ad35a20325630c3a02c

/// @dev Gates the SUBMIT surface of the attested balance-adapter family (ADR 0022). Deliberately NOT used to gate
///      the family's clears — those stay permissionless and stale-gated, because role-gating removal is what audit
///      finding L-02 flagged: a compromised role-holder could delete valid LIVE allocations.
bytes32 constant SUBMITTER = keccak256("SUBMITTER");

bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
