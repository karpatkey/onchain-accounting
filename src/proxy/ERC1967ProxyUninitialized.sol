// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title ERC1967ProxyUninitialized
/// @notice ERC1967 proxy that allows deployment with empty init data, so CREATE2 yields the same proxy address on every chain.
/// @dev Call initialize() on the proxy in a separate tx after deployment with chain-specific arguments.
contract ERC1967ProxyUninitialized is ERC1967Proxy {
    constructor(address implementation, bytes memory _data) payable ERC1967Proxy(implementation, _data) {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
