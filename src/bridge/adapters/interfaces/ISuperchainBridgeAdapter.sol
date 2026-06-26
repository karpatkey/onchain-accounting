// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {IL1StandardBridge, IL2StandardBridge, IOptimismPortal} from "./ISuperchainInterfaces.sol";

/// @title ISuperchainBridgeAdapter Interface
/// @notice Interface for Superchain (Optimism Canonical Bridge) Adapter
/// @dev Documents all events, errors, and public functions for the Superchain bridge adapter
/// @dev Supports Optimism, Base, Unichain, and other Superchain networks
/// @author KPK
interface ISuperchainBridgeAdapter is IBridgeAdapter {
    //
    // Events
    //

    /// @notice Event emitted when a Superchain bridge is initiated (L1 → L2 deposit)
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationChainId The destination chain ID (L2)
    /// @param amount The amount being bridged
    /// @param isEth Whether the asset is native ETH
    event SuperchainBridgeInitiated(bytes32 indexed invoiceId, uint64 destinationChainId, bytes32 amount, bool isEth);

    /// @notice Event emitted when a Superchain bridge is initiated (L2 → L1 withdrawal)
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationChainId The destination chain ID (L1)
    /// @param amount The amount being withdrawn
    /// @param withdrawalHash The withdrawal transaction hash
    event SuperchainWithdrawalInitiated(
        bytes32 indexed invoiceId, uint64 destinationChainId, bytes32 amount, bytes32 withdrawalHash
    );

    /// @notice Event emitted when a withdrawal is proven
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param withdrawalHash The withdrawal transaction hash - indexed
    event SuperchainWithdrawalProven(bytes32 indexed invoiceId, bytes32 indexed withdrawalHash);

    /// @notice Event emitted when a Superchain bridge is completed
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param sourceChainId The source chain ID
    event SuperchainBridgeCompleted(bytes32 indexed invoiceId, uint64 sourceChainId);

    //
    // Errors
    //

    /// @notice Thrown when an invalid L1 Standard Bridge address is provided
    error InvalidL1Bridge();

    /// @notice Thrown when an invalid L2 Standard Bridge address is provided
    error InvalidL2Bridge();

    /// @notice Thrown when an invalid Cross-Domain Messenger address is provided
    error InvalidCrossDomainMessenger();

    /// @notice Thrown when an invalid Optimism Portal address is provided
    error InvalidOptimismPortal();

    /// @notice Thrown when an invalid chain ID is provided
    error InvalidChainId();

    /// @notice Thrown when attempting to bridge to an unsupported chain
    /// @param chainId The unsupported chain ID
    error UnsupportedChain(uint64 chainId);

    /// @notice Thrown when attempting to bridge an unsupported asset
    error UnsupportedAsset();

    /// @notice Thrown when withdrawal proof data is invalid
    error InvalidWithdrawalProof();

    /// @notice Thrown when withdrawal finalization data is invalid
    error InvalidWithdrawalFinalization();

    /// @notice Thrown when withdrawal has not been proven yet
    error WithdrawalNotProven();

    /// @notice Thrown when withdrawal challenge period has not elapsed
    error WithdrawalChallengePeriodNotElapsed();

    //
    // State Variables (Public)
    //

    /// @notice L1 Standard Bridge contract address
    /// @return The L1 Standard Bridge contract instance
    function l1Bridge() external view returns (IL1StandardBridge);

    /// @notice L2 Standard Bridge contract address
    /// @return The L2 Standard Bridge contract instance
    function l2Bridge() external view returns (IL2StandardBridge);

    /// @notice Cross-Domain Messenger contract address (L1)
    /// @return The Cross-Domain Messenger contract address
    function l1Messenger() external view returns (address);

    /// @notice Cross-Domain Messenger contract address (L2)
    /// @return The Cross-Domain Messenger contract address
    function l2Messenger() external view returns (address);

    /// @notice Optimism Portal contract address
    /// @return The Optimism Portal contract instance
    function optimismPortal() external view returns (IOptimismPortal);

    /// @notice The chain ID where this adapter is deployed
    /// @return The chain ID
    function chainId() external view returns (uint256);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the withdrawal hash for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The withdrawal hash, or bytes32(0) if not found
    function invoiceToWithdrawalHash(bytes32 invoiceId) external view returns (bytes32);

    /// @notice Gets the invoice ID for a given withdrawal hash
    /// @param withdrawalHash The withdrawal transaction hash
    /// @return The invoice ID, or bytes32(0) if not found
    function withdrawalHashToInvoiceId(bytes32 withdrawalHash) external view returns (bytes32);

    //
    // Configuration Functions
    //

    /// @notice Initializes the Superchain Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param l1Bridge_ The L1 Standard Bridge contract address
    /// @param l2Bridge_ The L2 Standard Bridge contract address
    /// @param l1Messenger_ The L1 Cross-Domain Messenger contract address
    /// @param l2Messenger_ The L2 Cross-Domain Messenger contract address
    /// @param optimismPortal_ The Optimism Portal contract address
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address l1Bridge_,
        address l2Bridge_,
        address l1Messenger_,
        address l2Messenger_,
        address optimismPortal_,
        string memory version_
    ) external;

    /// @notice Sets the L1 Standard Bridge contract address
    /// @param l1Bridge_ The L1 Standard Bridge contract address
    /// @dev Only callable by admin role
    function setL1Bridge(address l1Bridge_) external;

    /// @notice Sets the L2 Standard Bridge contract address
    /// @param l2Bridge_ The L2 Standard Bridge contract address
    /// @dev Only callable by admin role
    function setL2Bridge(address l2Bridge_) external;

    /// @notice Sets the L1 Cross-Domain Messenger contract address
    /// @param l1Messenger_ The L1 Cross-Domain Messenger contract address
    /// @dev Only callable by admin role
    function setL1Messenger(address l1Messenger_) external;

    /// @notice Sets the L2 Cross-Domain Messenger contract address
    /// @param l2Messenger_ The L2 Cross-Domain Messenger contract address
    /// @dev Only callable by admin role
    function setL2Messenger(address l2Messenger_) external;

    /// @notice Sets the Optimism Portal contract address
    /// @param optimismPortal_ The Optimism Portal contract address
    /// @dev Only callable by admin role
    function setOptimismPortal(address optimismPortal_) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the withdrawal hash for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The withdrawal hash, or bytes32(0) if not found
    function getWithdrawalHashByInvoiceId(bytes32 invoiceId) external view returns (bytes32);

    /// @notice Gets the invoice ID for a given withdrawal hash
    /// @param withdrawalHash The withdrawal transaction hash
    /// @return The invoice ID, or bytes32(0) if not found
    function getInvoiceIdByWithdrawalHash(bytes32 withdrawalHash) external view returns (bytes32);

    /// @notice Checks if a withdrawal has been proven
    /// @param withdrawalHash The withdrawal transaction hash
    /// @return True if proven, false otherwise
    function isWithdrawalProven(bytes32 withdrawalHash) external view returns (bool);

    /// @notice Checks if a withdrawal can be finalized (challenge period elapsed)
    /// @param withdrawalHash The withdrawal transaction hash
    /// @return True if can be finalized, false otherwise
    function canFinalizeWithdrawal(bytes32 withdrawalHash) external view returns (bool);
}
