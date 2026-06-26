// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

/// @title Gnosis Bridge Interfaces
/// @notice Aggregated interfaces for Gnosis Omnibridge and AMB integration
/// @author KPK

// ============================================================================
// Gnosis AMB Interface
// ============================================================================

/// @title IAMB Interface
/// @notice Interface for Gnosis AMB (Arbitrary Message Bridge) (compatible with Solidity 0.8)
/// @dev Based on lib/omnibridge/contracts/interfaces/IAMB.sol
interface IAMB {
    event UserRequestForAffirmation(bytes32 indexed messageId, bytes encodedData);
    event UserRequestForSignature(bytes32 indexed messageId, bytes encodedData);
    event AffirmationCompleted(
        address indexed sender, address indexed executor, bytes32 indexed messageId, bool status
    );
    event RelayedMessage(address indexed sender, address indexed executor, bytes32 indexed messageId, bool status);

    function messageSender() external view returns (address);
    function maxGasPerTx() external view returns (uint256);
    function transactionHash() external view returns (bytes32);
    function messageId() external view returns (bytes32);
    function messageSourceChainId() external view returns (bytes32);
    function messageCallStatus(bytes32 _messageId) external view returns (bool);
    function failedMessageDataHash(bytes32 _messageId) external view returns (bytes32);
    function failedMessageReceiver(bytes32 _messageId) external view returns (address);
    function failedMessageSender(bytes32 _messageId) external view returns (address);
    function requireToPassMessage(address _contract, bytes calldata _data, uint256 _gas) external returns (bytes32);
    function requireToConfirmMessage(address _contract, bytes calldata _data, uint256 _gas) external returns (bytes32);
    function sourceChainId() external view returns (uint256);
    function destinationChainId() external view returns (uint256);
}

// ============================================================================
// Gnosis Omnibridge Interface
// ============================================================================

/// @title IOmnibridge Interface
/// @notice Interface for Gnosis Omnibridge contract (compatible with Solidity 0.8)
/// @dev Based on lib/omnibridge/contracts/interfaces/IOmnibridge.sol
interface IOmnibridge {
    /// @notice Relays ERC20 tokens to the other side of the bridge
    /// @param _token The token address
    /// @param _receiver The receiver address on the destination chain
    /// @param _value The amount to bridge
    function relayTokens(address _token, address _receiver, uint256 _value) external;

    /// @notice Relays ERC20 tokens to the other side of the bridge with additional data
    /// @param token The token address
    /// @param receiver The receiver address on the destination chain
    /// @param value The amount to bridge
    /// @param data Additional data to send (messagePayload)
    function relayTokensAndCall(address token, address receiver, uint256 value, bytes memory data) external;
}
