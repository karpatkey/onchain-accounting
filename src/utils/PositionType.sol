// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice LEGACY: string constants for the `type` field of the old string-based `positionDetail` JSON.
/// @dev Superseded and currently unused. Position type is now expressed by the typed `PositionKind`
///      enum (Wallet/Supplied/Borrowed/Collateral/Staking/Rewards/Fees) carried on every
///      `INAVCalculator.PositionBalance`, alongside the 3-level `protocolBrand`/`protocolId`/`protocolSubId`
///      taxonomy and the typed `positionInstanceId`; free-form labels are now lazy/verbose-only via
///      `IPositionDescribable.positionLabels`. No adapter imports this library today.
///      Each constant here is a valid JSON string value (no quotes, no braces).
/// @author KPK
library PositionType {
    string internal constant SUPPLY = "Supply";
    string internal constant BORROW = "Borrow";
    string internal constant COLLATERAL = "Collateral";
    string internal constant STAKING = "Staking";
    string internal constant REWARDS = "Rewards";
    string internal constant FEES = "Fees";

    /// @notice LEGACY helper: appends `,"type":"<typeVal>"}` to `base` and returns the complete
    ///         (old string-based) positionDetail JSON. Unused — see the library-level note.
    /// @param base     The partial JSON string (without closing `}`), e.g. `{"protocol":"Aave V3",...`.
    /// @param typeVal  One of the constants defined in this library (SUPPLY, BORROW, etc.).
    function withType(string memory base, string memory typeVal) internal pure returns (string memory) {
        return string.concat(base, ",\"type\":\"", typeVal, "\"}");
    }
}
