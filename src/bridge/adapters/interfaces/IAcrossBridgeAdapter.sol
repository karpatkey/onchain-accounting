// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {IAcrossV3Receiver, ISpokePool} from "./IAcrossInterfaces.sol";

/// @title IAcrossBridgeAdapter Interface
/// @notice Interface for Across Protocol V3 Bridge Adapter
/// @dev Documents all events, errors, and public functions for the Across adapter (ADR 0012, V3 flow).
/// @author kpk
interface IAcrossBridgeAdapter is IBridgeAdapter, IAcrossV3Receiver {
    //
    // Events
    //

    /// @notice Event emitted when an Across bridge is initiated
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationChainId The destination chain ID
    /// @param depositId The Across deposit ID (0 — V3 assigns the id in the SpokePool event, not returned inline)
    /// @param amount The amount being bridged
    event AcrossBridgeInitiated(
        bytes32 indexed invoiceId, uint256 destinationChainId, uint32 depositId, uint256 amount
    );

    /// @notice Event emitted when an Across bridge is completed
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param sourceChainId The source chain ID
    /// @param depositId The Across deposit ID - indexed
    event AcrossBridgeCompleted(bytes32 indexed invoiceId, uint256 sourceChainId, uint32 indexed depositId);

    //
    // Errors
    //

    /// @notice Thrown when an invalid SpokePool address is provided
    error InvalidSpokePool();

    /// @notice Thrown when an invalid relayer fee percentage is provided
    error InvalidRelayerFee();

    /// @notice Thrown when attempting to bridge to an unsupported chain
    /// @param chainId The unsupported chain ID
    error UnsupportedChain(uint256 chainId);

    /// @notice Thrown when an inbound Across message fails authentication or validation
    error MessageReceiveFailed();

    /// @notice Thrown when bridge data is invalid (token/amount mismatch, or untrusted source)
    error InvalidBridgeData();

    //
    // State Variables (Public)
    //

    /// @notice SpokePool contract address
    /// @return The SpokePool contract instance
    function spokePool() external view returns (ISpokePool);

    /// @notice Default relayer + LP fee percentage (in 1e18, e.g., 0.01e18 = 1%) subtracted from input to
    ///         derive the V3 outputAmount the recipient receives on the destination chain
    /// @return The default relayer fee percentage
    function defaultRelayerFeePct() external view returns (int64);

    /// @notice Gets the invoice ID for a given deposit ID
    /// @param depositId The Across deposit ID
    /// @return The invoice ID, or bytes32(0) if not found
    function depositIdToInvoiceId(uint32 depositId) external view returns (bytes32);

    /// @notice Gets the deposit ID for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The deposit ID, or 0 if not found
    function invoiceToDepositId(bytes32 invoiceId) external view returns (uint32);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    //
    // Configuration Functions
    //

    /// @notice Initializes the Across Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param spokePool_ The SpokePool contract address
    /// @param defaultRelayerFeePct_ The default relayer fee percentage (in 1e18)
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address spokePool_,
        int64 defaultRelayerFeePct_,
        string memory version_
    ) external;

    /// @notice Sets the SpokePool contract address
    /// @param spokePool_ The SpokePool contract address
    /// @dev Only callable by admin role
    function setSpokePool(address spokePool_) external;

    /// @notice Sets the default relayer fee percentage
    /// @param relayerFeePct_ The relayer fee percentage (in 1e18, e.g., 0.01e18 = 1%)
    /// @dev Only callable by admin role
    function setDefaultRelayerFeePct(int64 relayerFeePct_) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);
}
