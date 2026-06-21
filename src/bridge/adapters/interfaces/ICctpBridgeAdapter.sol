// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {ICircleTokenMessengerV2} from "./ICircleTokenMessengerV2.sol";
import {IMessageTransmitter} from "@chainlink/src/v0.8/ccip/pools/USDC/IMessageTransmitter.sol";

/// @title ICctpBridgeAdapter Interface
/// @notice Interface for CCTP Bridge Adapter
/// @dev Documents all events, errors, and public functions for the Circle CCTP adapter
/// @author kpk
interface ICctpBridgeAdapter is IBridgeAdapter {
    //
    // Events
    //

    /// @notice Event emitted when a CCTP bridge is initiated
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationDomain The CCTP domain ID of destination chain
    /// @param mintRecipient The recipient address on destination chain (as bytes32)
    /// @param amount The amount being bridged
    /// @param nonce The CCTP message nonce
    event CctpBridgeInitiated(
        bytes32 indexed invoiceId, uint32 destinationDomain, bytes32 mintRecipient, bytes32 amount, uint64 nonce
    );

    /// @notice Event emitted when a CCTP bridge is completed
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param sourceInvoiceId The source invoice ID (32 bytes) - indexed
    /// @param sourceDomain The CCTP domain ID of source chain
    event CctpBridgeCompleted(bytes32 indexed invoiceId, bytes32 indexed sourceInvoiceId, uint32 sourceDomain);

    //
    // Errors
    //

    /// @notice Thrown when an invalid CCTP domain is provided (destination/source not configured)
    error InvalidDomain();

    /// @notice Thrown when an invalid CCTP message is provided (too short / malformed)
    error InvalidMessage();

    /// @notice Thrown when message reception fails
    error MessageReceiveFailed();

    /// @notice Thrown when bridge data is invalid
    error InvalidBridgeData();

    /// @notice Thrown when the CCTP message body's mintRecipient is not this adapter
    error InvalidMintRecipient();

    /// @notice Thrown when the CCTP message body's burnToken does not match the invoice asset
    error BurnTokenMismatch();

    /// @notice Thrown when the CCTP message body's amount does not match the invoice amount
    error AmountMismatch();

    /// @notice Thrown when the CCTP message sourceDomain does not map to the invoice sourceChainId
    error SourceDomainMismatch();

    /// @notice Thrown when a CCTP message nonce has already been consumed (replay protection)
    error NonceAlreadyUsed(uint32 sourceDomain, uint64 nonce);

    //
    // State Variables (Public)
    //

    /// @notice TokenMessengerV2 contract address (source chain)
    /// @return The TokenMessengerV2 contract instance
    function tokenMessenger() external view returns (ICircleTokenMessengerV2);

    /// @notice MessageTransmitter contract address (source chain for sending, destination for receiving)
    /// @return The MessageTransmitter contract instance
    function messageTransmitter() external view returns (IMessageTransmitter);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the invoice ID for a given CCTP message
    /// @param sourceDomain The source CCTP domain
    /// @param nonce The CCTP message nonce
    /// @return The invoice ID, or bytes32(0) if not found
    function messageToInvoiceId(uint32 sourceDomain, uint64 nonce) external view returns (bytes32);

    /// @notice Gets the CCTP domain for a given chain ID
    /// @param chainId The chain ID
    /// @return The CCTP domain ID, or 0 if not set
    function chainIdToDomain(uint64 chainId) external view returns (uint32);

    /// @notice Gets the chain ID for a given CCTP domain
    /// @param domain The CCTP domain ID
    /// @return The chain ID, or 0 if not set
    function domainToChainId(uint32 domain) external view returns (uint64);

    /// @notice Whether a chain ID has an explicitly configured CCTP domain mapping
    /// @param chainId The chain ID
    /// @return True if a domain mapping has been set for this chain
    /// @dev Ethereum's canonical CCTP domain IS 0, so domain==0 cannot be used as an
    ///      "unconfigured" sentinel; this explicit flag distinguishes configured-as-0 from unset.
    function domainConfigured(uint64 chainId) external view returns (bool);

    /// @notice Whether a (sourceDomain, nonce) CCTP message has already been consumed
    /// @param sourceDomain The source CCTP domain
    /// @param nonce The CCTP message nonce
    /// @return True if the nonce was already used to complete a bridge (replay protection)
    function usedNonces(uint32 sourceDomain, uint64 nonce) external view returns (bool);

    //
    // Configuration Functions
    //

    /// @notice Initializes the CCTP Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param tokenMessenger_ The TokenMessenger contract address
    /// @param messageTransmitter_ The MessageTransmitter contract address
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address tokenMessenger_,
        address messageTransmitter_,
        string memory version_
    ) external;

    /// @notice Sets the CCTP domain mapping for a chain ID
    /// @param chainId The chain ID
    /// @param domain The CCTP domain ID
    /// @dev Only callable by admin role
    function setDomainMapping(uint64 chainId, uint32 domain) external;

    /// @notice Sets the TokenMessenger contract address
    /// @param tokenMessenger_ The TokenMessenger contract address
    /// @dev Only callable by admin role
    function setTokenMessenger(address tokenMessenger_) external;

    /// @notice Sets the MessageTransmitter contract address
    /// @param messageTransmitter_ The MessageTransmitter contract address
    /// @dev Only callable by admin role
    function setMessageTransmitter(address messageTransmitter_) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the CCTP domain for a given chain ID
    /// @param chainId The chain ID
    /// @return The CCTP domain ID, or 0 if not set
    function getDomainForChain(uint64 chainId) external view returns (uint32);

    /// @notice Gets the chain ID for a given CCTP domain
    /// @param domain The CCTP domain ID
    /// @return The chain ID, or 0 if not set
    function getChainForDomain(uint32 domain) external view returns (uint64);
}
