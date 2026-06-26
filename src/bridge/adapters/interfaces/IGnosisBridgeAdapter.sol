// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {IOmnibridge, IAMB} from "./IGnosisInterfaces.sol";

/// @title IGnosisBridgeAdapter Interface
/// @notice Interface for Gnosis Bridge Adapter
/// @dev Documents all events, errors, and public functions for the Gnosis Omnibridge adapter
/// @author KPK
interface IGnosisBridgeAdapter is IBridgeAdapter {
    //
    // Events
    //

    /// @notice Event emitted when a Gnosis bridge is initiated
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationChainId The destination chain ID
    /// @param receiver The receiver address on destination chain
    /// @param amount The amount being bridged
    /// @param transactionHash The AMB transaction hash
    event GnosisBridgeInitiated(
        bytes32 indexed invoiceId, uint64 destinationChainId, address receiver, bytes32 amount, bytes32 transactionHash
    );

    /// @notice Event emitted when a Gnosis bridge is completed
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param sourceChainId The source chain ID
    /// @param transactionHash The AMB transaction hash - indexed
    event GnosisBridgeCompleted(bytes32 indexed invoiceId, uint64 sourceChainId, bytes32 indexed transactionHash);

    //
    // Errors
    //

    /// @notice Thrown when an invalid Omnibridge address is provided
    error InvalidOmnibridge();

    /// @notice Thrown when an invalid AMB address is provided
    error InvalidAMB();

    /// @notice Thrown when an invalid chain ID is provided
    error InvalidChainId();

    /// @notice Thrown when an invalid receiver address is provided
    error InvalidReceiver();

    /// @notice Thrown when message reception fails
    error MessageReceiveFailed();

    /// @notice Thrown when bridge data is invalid
    error InvalidBridgeData();

    /// @notice Thrown when attempting to bridge to an unsupported chain
    /// @param chainId The unsupported chain ID
    error UnsupportedChain(uint64 chainId);

    /// @notice Thrown when attempting to bridge native tokens (not supported, must wrap first)
    error NativeTokenNotSupported();

    /// @notice Thrown when tokens are not available in the adapter (may need to be claimed on Mainnet)
    error TokensNotAvailable();

    //
    // State Variables (Public)
    //

    /// @notice Omnibridge contract address
    /// @return The Omnibridge contract instance
    function omnibridge() external view returns (IOmnibridge);

    /// @notice AMB contract address (for message verification)
    /// @return The AMB contract instance
    function amb() external view returns (IAMB);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the invoice ID for a given AMB transaction hash
    /// @param transactionHash The AMB transaction hash
    /// @return The invoice ID, or bytes32(0) if not found
    function transactionHashToInvoiceId(bytes32 transactionHash) external view returns (bytes32);

    /// @notice Gets the AMB transaction hash for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The transaction hash, or bytes32(0) if not found
    function invoiceToTransactionHash(bytes32 invoiceId) external view returns (bytes32);

    //
    // Configuration Functions
    //

    /// @notice Initializes the Gnosis Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param omnibridge_ The Omnibridge contract address
    /// @param amb_ The AMB contract address
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address omnibridge_,
        address amb_,
        string memory version_
    ) external;

    /// @notice Sets the Omnibridge contract address
    /// @param omnibridge_ The Omnibridge contract address
    /// @dev Only callable by admin role
    function setOmnibridge(address omnibridge_) external;

    /// @notice Sets the AMB contract address
    /// @param amb_ The AMB contract address
    /// @dev Only callable by admin role
    function setAmb(address amb_) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the invoice ID for a given AMB transaction hash
    /// @param transactionHash The AMB transaction hash
    /// @return The invoice ID, or bytes32(0) if not found
    function getInvoiceIdByTransactionHash(bytes32 transactionHash) external view returns (bytes32);

    /// @notice Gets the AMB transaction hash for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The transaction hash, or bytes32(0) if not found
    function getTransactionHashByInvoiceId(bytes32 invoiceId) external view returns (bytes32);

    /// @notice Checks if tokens are available in the adapter for a given invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @param asset The asset address
    /// @return True if tokens are available, false otherwise
    /// @dev On Gnosis Chain, tokens are automatically transferred via onTokenTransfer.
    ///      On Mainnet, tokens may need to be manually claimed from Omnibridge first.
    function areTokensAvailable(bytes32 invoiceId, address asset) external view returns (bool);

    //
    // Receiver Functions
    //

    /// @notice Receives tokens from the Omnibridge mediator via ERC677 onTokenTransfer
    /// @param from The sender on the mediator side
    /// @param value The amount of tokens delivered to the adapter
    /// @param data The message payload (contains invoiceId + amount + nonce + meta)
    /// @return success Whether the transfer was successful
    /// @dev Auto completion path: the genuine Omnibridge mediator delivers the bridged tokens to this adapter
    ///      and then calls this. The adapter authenticates the mediator (`msg.sender == omnibridge`) and the
    ///      AMB-reported source (`amb.messageSender()` == the trusted remote adapter, `amb.messageSourceChainId()`
    ///      == the expected source chain), verifies the delivered token+amount match the invoice, then funds the
    ///      escrow and releases. Calling it from any other address reverts.
    function onTokenTransfer(address from, uint256 value, bytes calldata data) external returns (bool);

    /// @notice Receives native tokens from Omnibridge
    /// @dev This function is called when native tokens (ETH/xDAI) are received
    /// @dev The messagePayload should be extracted from the transaction data or stored separately
    receive() external payable;
}
