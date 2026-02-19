// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal interface for Circle's TokenMessengerV2 on EVM chains
/// @dev Matches the on-chain TokenMessengerV2: depositForBurn does not return a value;
///      the nonce is emitted in DepositForBurn (or MessageSent) and is not available in-call.
interface ICircleTokenMessengerV2 {
    /// @notice Deposits and burns tokens from sender to be minted on destination domain.
    /// @param amount Amount of tokens to burn.
    /// @param destinationDomain Destination CCTP domain ID.
    /// @param mintRecipient Address of mint recipient on destination domain, as bytes32.
    /// @param burnToken Address of token to burn on local domain.
    /// @param destinationCaller Authorized caller on destination domain, as bytes32.
    /// @param maxFee Maximum fee to pay on destination domain, in units of burnToken.
    /// @param minFinalityThreshold Minimum finality threshold for attestation.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

