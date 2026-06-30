// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IBridgeAdapter Interface
/// @notice Interface for bridge adapter implementations
/// @author KPK
interface IBridgeAdapter {
    //
    // Errors
    //

    /// @notice Thrown when invalid arguments are provided
    error InvalidArguments();

    /// @notice Thrown when caller is not authorized
    error NotAuthorized();

    /// @notice Thrown when transfer operation fails
    error TransferFailed();

    /// @notice Thrown when contract has insufficient balance
    /// @param asset The asset address
    /// @param required The required amount
    /// @param available The available amount
    error InsufficientBalance(address asset, uint256 required, uint256 available);

    /// @notice Thrown when completion data is invalid
    error InvalidCompletionData();

    //
    // Events
    //

    /// @notice Event emitted when a bridge is initiated
    event BridgeInitiated(bytes32 indexed invoiceId, uint256 amount);

    /// @notice Event emitted when a bridge is completed
    event BridgeCompleted(bytes32 indexed invoiceId);

    /// @notice Event emitted when assets are recovered from an adapter
    event AssetsRecovered(address indexed asset, uint256 amount, address indexed to);

    /// @notice Event emitted when tokens are transferred from adapter to escrow
    event TokensTransferredToEscrow(bytes32 indexed invoiceId, address indexed asset, uint256 amount);

    //
    // Functions
    //

    /// @notice Initiates a bridge operation
    /// @param messagePayload Encoded payload from BridgeEscrow (exactly 4 slots: invoiceId, amount, nonce, meta)
    /// @dev Adapter should decode messagePayload to extract invoiceId, amount, and derive other needed data
    function bridge(bytes calldata messagePayload) external;

    /// @notice Completes a bridge operation on destination chain
    /// @param messagePayload The message payload (exactly 4 slots: invoiceId, amount, nonce, meta)
    /// @param protocolData Bridge-specific protocol data (e.g., CCTP message+attestation, CCIP Any2EVMMessage)
    /// @dev The base adapter calls BridgeEscrow.releaseByInvoiceId(messagePayload) after _completeBridge returns. Adapter implementations must not call releaseByInvoiceId; they only perform protocol-specific completion in _completeBridge.
    function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external;

    /// @notice Returns the bridge provider name (e.g., "CCTP", "Gnosis")
    /// @return The bridge provider name
    function bridgeProvider() external view returns (string memory);

    /// @notice Returns the bridge adapter version
    /// @return The adapter version
    function version() external view returns (string memory);

    /// @notice Recovers stuck assets from the adapter
    /// @param asset The asset address to recover (address(0) for native tokens)
    /// @param amount The amount to recover
    /// @param to The address to send recovered assets to; must be the escrow or an escrow-authorized account
    /// @dev Only the MANAGER_ROLE can call this. Recipient-restricted (ADR 0012, H11): recovered funds may
    ///      only go to the escrow or an escrow-authorized account, never an arbitrary address.
    function recoverStuckAssets(address asset, uint256 amount, address to) external;
}

