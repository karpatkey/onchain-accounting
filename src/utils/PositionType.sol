// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice String constants for the `type` field appended to every `positionDetail` JSON.
/// @dev Import this library in balance adapters instead of inlining string literals.
///      Every constant here is a valid JSON string value (no quotes, no braces).
/// @author KPK
library PositionType {
    string internal constant SUPPLY = "Supply";
    string internal constant BORROW = "Borrow";
    string internal constant COLLATERAL = "Collateral";
    string internal constant STAKING = "Staking";
    string internal constant REWARDS = "Rewards";
    string internal constant FEES = "Fees";

    /// @notice Appends `,"type":"<typeVal>"}` to `base` and returns the complete positionDetail JSON.
    /// @param base     The partial JSON string (without closing `}`), e.g. `{"protocol":"Aave V3",...`.
    /// @param typeVal  One of the constants defined in this library (SUPPLY, BORROW, etc.).
    function withType(string memory base, string memory typeVal) internal pure returns (string memory) {
        return string.concat(base, ",\"type\":\"", typeVal, "\"}");
    }
}
