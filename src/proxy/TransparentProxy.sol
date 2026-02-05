// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title TransparentProxy
/// @notice Wrapper around TransparentUpgradeableProxy for consistent naming and usage.
/// @dev This is simply a re-export of OpenZeppelin's TransparentUpgradeableProxy.
///      The proxy is deployed with a placeholder implementation and a ProxyAdmin owned by Safe.
///      Use ProxyAdmin.upgradeAndCall() to upgrade from placeholder to real implementation.
/// @custom:security Uses OpenZeppelin's battle-tested TransparentUpgradeableProxy pattern.
contract TransparentProxy is TransparentUpgradeableProxy {
    /// @param placeholderImplementation The placeholder implementation address (e.g., Empty contract)
    /// @param initialOwner The owner of the ProxyAdmin contract (typically Safe multisig)
    /// @param _data Empty bytes (no initialization during deployment)
    constructor(address placeholderImplementation, address initialOwner, bytes memory _data)
        payable
        TransparentUpgradeableProxy(placeholderImplementation, initialOwner, _data)
    {}
}
