// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {NotAContract} from "src/errors.sol";

/// @title AddressCheckLib
/// @author KPK
/// @notice Constructor-argument helper for the balance-adapter layer: asserts a dependency address actually points
///         to a deployed contract, reverting with the {NotAContract} custom error carrying the dependency label.
/// @dev Centralises the `addr.code.length > 0` dependency check that every adapter pins its immutables with. The
///      price-feed layer has its own equivalent (`OracleArgumentChecks`); this is the balance-side analogue. `name`
///      is the dependency's human label (e.g. "NAVCalculator"), surfaced in the {NotAContract} error.
library AddressCheckLib {
    /// @notice Reverts {NotAContract}(`name`) unless `addr` has non-empty code.
    /// @param addr The dependency address to validate.
    /// @param name The dependency's display name (carried in the revert).
    function requireContract(address addr, string memory name) internal view {
        if (addr.code.length == 0) revert NotAContract(name);
    }
}
