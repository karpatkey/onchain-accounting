// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title UUPSPlaceholder
/// @notice UUPS-compatible placeholder implementation for proxy deployment
/// @dev This placeholder allows upgrades without authorization checks (since it's temporary)
///      The real implementation will have proper _authorizeUpgrade checks
/// @author KPK
contract UUPSPlaceholder is Initializable, UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the placeholder (no-op, but required for UUPS compatibility)
    function initialize() external initializer {
        // UUPSUpgradeable doesn't require initialization - it's stateless
    }

    /// @notice Allow upgrades without authorization (placeholder only)
    /// @dev Real implementations will override this with proper access control
    function _authorizeUpgrade(address) internal override {}
}
