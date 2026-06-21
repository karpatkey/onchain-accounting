// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title Across Protocol V3 Interfaces
/// @notice Aggregated interfaces for Across Protocol V3 SpokePool integration
/// @dev Across migrated to the V3 deposit/fill flow (`depositV3` + `handleV3AcrossMessage`). See ADR 0012 (D3).
/// @author kpk

// ============================================================================
// Across V3 Message Handler Interface
// ============================================================================

/// @title IAcrossV3Receiver Interface
/// @notice Interface for contracts that receive V3 messages from Across Protocol
/// @dev On a filled relay that carries a message, the destination SpokePool transfers `tokenSent`/`amount`
///      to the recipient contract and then calls `handleV3AcrossMessage` on it. There is no `fillCompleted`
///      flag in V3 (partial fills were removed) and the SpokePool does NOT expose a source sender, so message
///      provenance must be enforced by the integrator (here: `msg.sender == spokePool` + token/amount match +
///      trusted-remote check keyed by the payload's source chain). Tokens are already on the recipient when
///      this fires (enforced by the SpokePool), so `tokenSent`/`amount` can be trusted as actually delivered.
interface IAcrossV3Receiver {
    /// @notice Handles a V3 message received from Across Protocol
    /// @param tokenSent The token address that was delivered to this contract (enforced by the SpokePool)
    /// @param amount The amount of tokens delivered (enforced by the SpokePool)
    /// @param relayer The address of the relayer that filled the deposit
    /// @param message The message payload authored on the origin chain (contains the invoice messagePayload)
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;
}

// ============================================================================
// Across V3 SpokePool Interface
// ============================================================================

/// @title ISpokePool Interface
/// @notice Interface for Across Protocol V3 SpokePool contract
/// @dev Uses the V3 `depositV3` entrypoint (the legacy `deposit` / `handleAcrossMessage` flow is removed).
interface ISpokePool {
    /// @notice Initiates a V3 deposit to be bridged to another chain
    /// @param depositor Address credited as the depositor on the origin chain
    /// @param recipient Address on the destination chain to receive tokens (and the V3 message callback)
    /// @param inputToken Token deposited on the origin chain
    /// @param outputToken Token to be received on the destination chain (address(0) = canonical equivalent)
    /// @param inputAmount Amount of input token deposited
    /// @param outputAmount Amount of output token to be received (input minus relayer/LP fees)
    /// @param destinationChainId Destination chain ID
    /// @param exclusiveRelayer Relayer with exclusive fill rights before exclusivityDeadline (address(0) = none)
    /// @param quoteTimestamp Timestamp of the fee quote (usually block.timestamp)
    /// @param fillDeadline Timestamp after which the deposit can no longer be filled
    /// @param exclusivityDeadline Timestamp until which exclusiveRelayer has exclusive fill rights
    /// @param message Arbitrary message delivered to `recipient` via handleV3AcrossMessage (the invoice payload)
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    /// @notice Maximum allowed offset of a deposit's fillDeadline beyond the current block timestamp.
    /// @dev The SpokePool reverts `InvalidFillDeadline()` if `fillDeadline > block.timestamp + fillDeadlineBuffer`.
    function fillDeadlineBuffer() external view returns (uint32);

    /// @notice Event emitted when a V3 deposit is made
    event V3FundsDeposited(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed destinationChainId,
        uint256 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address indexed depositor,
        address recipient,
        address exclusiveRelayer,
        bytes message
    );
}
