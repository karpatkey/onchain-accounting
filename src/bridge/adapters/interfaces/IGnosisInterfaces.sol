// SPDX-License-Identifier: BUSL-1.1
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

// ============================================================================
// Gnosis USDC Transmuter Interface
// ============================================================================

/// @title IUSDCTransmuter Interface
/// @notice Interface for the Gnosis USDCTransmuter (0x0392a2f5ac47388945d8c84212469f545fae52b2), which converts
///         1:1 (no fee) between the legacy OmniBridge "USD//C on xDai" (USDC_ON_XDAI, 0xDDAfbb50…) and Circle's
///         Bridged USDC.e (USDC_E, 0x2a22f9c3…). The GnosisBridgeAdapter uses it so the fee-free canonical
///         OmniBridge USDC route lands the USDC.e the escrow registers.
/// @dev Verified against the GnosisScan-verified source + on-chain. Both swaps are 1:1, send output to msg.sender,
///      and pull input via transferFrom (caller must approve first). `deposit` mints USDC.e (never liquidity-gated);
///      `withdraw` pays legacy from a held reserve (reverts "withdrawal amount exceeded!" if under-reserved). Both
///      revert if `isEnabled()` is false. The contract is immutable (not a proxy).
interface IUSDCTransmuter {
    /// @notice Swap legacy USDC_ON_XDAI -> USDC_E. Pulls `amount` legacy via transferFrom (approve first), mints
    ///         `amount` USDC.e to msg.sender. 1:1, no fee.
    function deposit(uint256 amount) external;

    /// @notice Swap USDC_E -> legacy USDC_ON_XDAI. Pulls + burns `amount` USDC.e (approve first), sends `amount`
    ///         legacy to msg.sender from the held reserve. 1:1, no fee. Reverts if the reserve < `amount`.
    function withdraw(uint256 amount) external;

    /// @notice The legacy OmniBridge USDC token (0xDDAfbb50…) — what the general OmniBridge delivers on Gnosis.
    function USDC_ON_XDAI() external view returns (address);

    /// @notice The USDC.e token (0x2a22f9c3…) — Circle's Bridged USDC Standard on Gnosis.
    function USDC_E() external view returns (address);

    /// @notice Whether swaps are active (owner can one-way disable). Both deposit/withdraw revert if false.
    function isEnabled() external view returns (bool);
}
