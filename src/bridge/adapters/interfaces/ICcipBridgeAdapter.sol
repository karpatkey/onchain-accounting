// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";

/// @title ICcipBridgeAdapter Interface
/// @notice Interface for CCIP Bridge Adapter
/// @dev Documents all events, errors, and public functions for the Chainlink CCIP adapter
/// @author kpk
interface ICcipBridgeAdapter is IBridgeAdapter, IAny2EVMMessageReceiver {
    //
    // Events
    //

    /// @notice Event emitted when a CCIP bridge is initiated
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationChainSelector The CCIP chain selector of destination chain
    /// @param messageId The CCIP message ID
    /// @param amount The amount being bridged
    event CcipBridgeInitiated(
        bytes32 indexed invoiceId, uint64 destinationChainSelector, bytes32 messageId, bytes32 amount
    );

    /// @notice Event emitted when a CCIP bridge is completed
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param messageId The CCIP message ID - indexed
    /// @param sourceChainSelector The CCIP chain selector of source chain
    event CcipBridgeCompleted(bytes32 indexed invoiceId, bytes32 indexed messageId, uint64 sourceChainSelector);

    //
    // Errors
    //

    /// @notice Thrown when an invalid CCIP chain selector is provided
    error InvalidChainSelector();

    /// @notice Thrown when an invalid CCIP router address is provided
    error InvalidRouter();

    /// @notice Thrown when message reception fails
    error MessageReceiveFailed();

    /// @notice Thrown when bridge data is invalid
    error InvalidBridgeData();

    /// @notice Thrown when attempting to bridge to an unsupported chain
    /// @param chainSelector The unsupported chain selector
    error UnsupportedChain(uint64 chainSelector);

    //
    // State Variables (Public)
    //

    /// @notice CCIP Router contract address
    /// @return The Router contract instance
    function router() external view returns (IRouterClient);

    /// @notice Fee token address (address(0) for native, or LINK token address)
    /// @return The fee token address
    function feeToken() external view returns (address);

    /// @notice Gets the invoice ID for a given CCIP message ID
    /// @param messageId The CCIP message ID
    /// @return The invoice ID, or bytes32(0) if not found
    function messageIdToInvoiceId(bytes32 messageId) external view returns (bytes32);

    /// @notice Gets the CCIP message ID for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message ID, or bytes32(0) if not found
    function invoiceToMessageId(bytes32 invoiceId) external view returns (bytes32);

    /// @notice Gets the CCIP chain selector for a given chain ID
    /// @param chainId The chain ID
    /// @return The CCIP chain selector, or 0 if not set
    function chainIdToSelector(uint64 chainId) external view returns (uint64);

    /// @notice Gets the chain ID for a given CCIP chain selector
    /// @param chainSelector The CCIP chain selector
    /// @return The chain ID, or 0 if not set
    function selectorToChainId(uint64 chainSelector) external view returns (uint64);

    /// @notice Gets the CCIP extraArgs for a chain selector
    /// @param chainSelector The CCIP chain selector
    /// @return The extra args bytes
    function chainExtraArgs(uint64 chainSelector) external view returns (bytes memory);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    //
    // Configuration Functions
    //

    /// @notice Initializes the CCIP Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param router_ The CCIP Router contract address
    /// @param feeToken_ The fee token address (address(0) for native, or LINK token)
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address feeToken_,
        string memory version_
    ) external;

    /// @notice Sets the CCIP chain selector mapping for a chain ID
    /// @param chainId The chain ID
    /// @param chainSelector The CCIP chain selector
    /// @dev Only callable by admin role
    function setChainSelectorMapping(uint64 chainId, uint64 chainSelector) external;

    /// @notice Sets the CCIP Router contract address
    /// @param router_ The Router contract address
    /// @dev Only callable by admin role
    function setRouter(address router_) external;

    /// @notice Sets the fee token address
    /// @param feeToken_ The fee token address (address(0) for native)
    /// @dev Only callable by admin role
    function setFeeToken(address feeToken_) external;

    /// @notice Sets CCIP extraArgs for a chain selector
    /// @param chainSelector The CCIP chain selector
    /// @param extraArgs The extra args (e.g., gas limit, encoded using Client._argsToBytes())
    /// @dev Only callable by admin role
    function setChainExtraArgs(uint64 chainSelector, bytes calldata extraArgs) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the CCIP chain selector for a given chain ID
    /// @param chainId The chain ID
    /// @return The CCIP chain selector, or 0 if not set
    function getSelectorForChain(uint64 chainId) external view returns (uint64);

    /// @notice Gets the chain ID for a given CCIP chain selector
    /// @param chainSelector The CCIP chain selector
    /// @return The chain ID, or 0 if not set
    function getChainForSelector(uint64 chainSelector) external view returns (uint64);

    /// @notice Gets the CCIP fee for a message
    /// @param destinationChainSelector The destination chain selector
    /// @param messageData The message data
    /// @param tokenAmounts The token amounts to send
    /// @param extraArgs The extra args for the message
    /// @return The fee amount
    function getFee(
        uint64 destinationChainSelector,
        bytes memory messageData,
        Client.EVMTokenAmount[] memory tokenAmounts,
        bytes memory extraArgs
    ) external view returns (uint256);

    //
    // CCIP Receiver Functions
    //

    /// @notice Receives CCIP messages from the router
    /// @param message The CCIP message
    /// @dev This is called automatically by the CCIP router when a message arrives.
    ///      Tokens are automatically transferred before this callback.
    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}
