// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title AddressCheckLib
/// @author KPK
/// @notice Constructor-argument helper for the balance-adapter layer: asserts a dependency address actually points
///         to a deployed contract, reverting with the conventional `"<Name> must be a contract"` message.
/// @dev Centralises the `require(addr.code.length > 0, "<Name> must be a contract")` idiom that every adapter pins
///      its immutable dependencies with. The price-feed layer has its own equivalent (`OracleArgumentChecks`); this
///      is the balance-side analogue. `name` is the dependency's human label (e.g. "NAVCalculator") — the
///      " must be a contract" suffix is appended here so the revert string stays uniform across adapters.
library AddressCheckLib {
    /// @notice Reverts `"<name> must be a contract"` unless `addr` has non-empty code.
    /// @param addr The dependency address to validate.
    /// @param name The dependency's display name (revert-message prefix).
    function requireContract(address addr, string memory name) internal view {
        require(addr.code.length > 0, string.concat(name, " must be a contract"));
    }
}
