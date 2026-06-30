// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title UUPSProxy
/// @notice Wrapper around ERC1967Proxy for UUPS pattern.
/// @dev The proxy is deployed with a placeholder implementation.
///      Use upgradeToAndCall() directly on the proxy to upgrade to real implementation.
///      Upgrades are protected by _authorizeUpgrade in the implementation (checks DEFAULT_ADMIN_ROLE).
/// @author KPK
contract UUPSProxy is ERC1967Proxy {
    /// @param placeholderImplementation The placeholder implementation address (e.g., Empty contract)
    /// @param _data Empty bytes (no initialization during deployment); the real impl + init are set via
    ///              upgradeToAndCall by the deployer EOA in 02_DeployProxies (02_2 for NAV).
    constructor(address placeholderImplementation, bytes memory _data)
        payable
        ERC1967Proxy(placeholderImplementation, _data)
    {}

    /// @dev Allow deploying with empty init data; the real impl + initialize(...) are set later via
    ///      upgradeToAndCall by the deployer EOA in 02_DeployProxies (02_2 for NAV).
    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
