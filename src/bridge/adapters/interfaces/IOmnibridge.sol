// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IOmnibridge Interface
/// @notice Interface for Gnosis Omnibridge contract (compatible with Solidity 0.8)
/// @dev Based on lib/omnibridge/contracts/interfaces/IOmnibridge.sol
/// @author kpk
interface IOmnibridge {
    /// @notice Relays ERC20 tokens to the other side of the bridge
    /// @param _token The token address
    /// @param _receiver The receiver address on the destination chain
    /// @param _value The amount to bridge
    function relayTokens(
        address _token,
        address _receiver,
        uint256 _value
    ) external;

    /// @notice Relays ERC20 tokens to the other side of the bridge with additional data
    /// @param token The token address
    /// @param receiver The receiver address on the destination chain
    /// @param value The amount to bridge
    /// @param data Additional data to send (messagePayload)
    function relayTokensAndCall(
        address token,
        address receiver,
        uint256 value,
        bytes memory data
    ) external;
}
