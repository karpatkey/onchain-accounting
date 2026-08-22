// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Types} from "@optimism/libraries/Types.sol";

/// @title Superchain (Optimism) Bridge Interfaces
/// @notice Aggregated interfaces for Optimism Superchain canonical bridge integration
/// @author KPK

// ============================================================================
// Optimism L1 Standard Bridge Interface
// ============================================================================

/// @title IL1StandardBridge Interface
/// @notice Interface for Optimism L1 Standard Bridge
/// @dev Used for bridging ETH and ERC20 tokens from L1 to L2
interface IL1StandardBridge {
    /// @notice Deposits ETH to a recipient's balance on L2
    /// @param _to Address on L2 to receive the ETH
    /// @param _l2Gas Gas limit for the L2 execution
    /// @param _data Optional data to forward to L2
    // forge-lint: disable-next-line(mixed-case-function)
    function depositETHTo(address _to, uint32 _l2Gas, bytes calldata _data) external payable;

    /// @notice Deposits an amount of ERC20 tokens to a recipient's balance on L2
    /// @param _l1Token Address of the L1 token
    /// @param _l2Token Address of the corresponding L2 token
    /// @param _to Address on L2 to receive the tokens
    /// @param _amount Amount of tokens to deposit
    /// @param _l2Gas Gas limit for the L2 execution
    /// @param _data Optional data to forward to L2
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _l2Gas,
        bytes calldata _data
    ) external;

    /// @notice Event emitted when ETH deposit is initiated
    event ETHDepositInitiated(address indexed _from, address indexed _to, uint256 _amount, bytes _data);

    /// @notice Event emitted when ERC20 deposit is initiated
    event ERC20DepositInitiated(
        address indexed _l1Token,
        address indexed _l2Token,
        address indexed _from,
        address _to,
        uint256 _amount,
        bytes _data
    );
}

// ============================================================================
// Optimism L2 Standard Bridge Interface
// ============================================================================

/// @title IL2StandardBridge Interface
/// @notice Interface for Optimism L2 Standard Bridge
/// @dev Used for bridging ETH and ERC20 tokens from L2 to L1
interface IL2StandardBridge {
    /// @notice Withdraws ETH to a recipient on L1
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdraw(uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ETH to a specific recipient on L1
    /// @param _to Address on L1 to receive the ETH
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdrawTo(address _to, uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ERC20 tokens to a recipient on L1
    /// @param _l2Token Address of the L2 token
    /// @param _amount Amount of tokens to withdraw
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdraw(address _l2Token, uint256 _amount, uint32 _l1Gas, bytes calldata _data) external payable;

    /// @notice Withdraws ERC20 tokens to a specific recipient on L1
    /// @param _l2Token Address of the L2 token
    /// @param _to Address on L1 to receive the tokens
    /// @param _amount Amount of tokens to withdraw
    /// @param _l1Gas Gas limit for the L1 execution
    /// @param _data Optional data to forward to L1
    function withdrawTo(address _l2Token, address _to, uint256 _amount, uint32 _l1Gas, bytes calldata _data)
        external
        payable;

    /// @notice Event emitted when ETH withdrawal is initiated
    event ETHWithdrawalInitiated(address indexed _from, address indexed _to, uint256 _amount, bytes _data);

    /// @notice Event emitted when ERC20 withdrawal is initiated
    event ERC20WithdrawalInitiated(
        address indexed _l1Token,
        address indexed _l2Token,
        address indexed _from,
        address _to,
        uint256 _amount,
        bytes _data
    );
}

// ============================================================================
// Optimism Cross-Domain Messenger Interface
// ============================================================================

/// @title ICrossDomainMessenger Interface
/// @notice Minimal interface for the OP Stack Cross-Domain Messenger (L1 and L2)
/// @dev Used to authenticate the provenance of a relayed cross-domain message. On the destination chain the
///      messenger relays the message and exposes the original sender on the source chain via
///      `xDomainMessageSender()` (only meaningful during the relayed call). The Superchain adapter, as the
///      destination recipient, verifies `msg.sender == <messenger>` and
///      `messenger.xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`.
interface ICrossDomainMessenger {
    /// @notice Returns the address of the sender of the currently-being-relayed cross-domain message.
    /// @return The source-chain sender address (the sibling adapter for an authenticated bridge message).
    // forge-lint: disable-next-line(mixed-case-function)
    function xDomainMessageSender() external view returns (address);

    /// @notice Sends a cross-domain message to `_target` on the other chain (optionally carrying native value).
    /// @dev Used on L1 by the Superchain adapter to deliver an authenticated `completeDeposit` call to its L2
    ///      sibling: the L2CrossDomainMessenger relays it with `xDomainMessageSender()` set to this adapter, so
    ///      the L2 sibling can authenticate provenance (the deposit's funds are ordered ahead of this message).
    /// @param _target The destination contract on the other chain (the sibling adapter).
    /// @param _message The calldata to relay to `_target`.
    /// @param _minGasLimit Minimum gas to relay with on the destination chain.
    function sendMessage(address _target, bytes calldata _message, uint32 _minGasLimit) external payable;
}

// ============================================================================
// Optimism Portal Interface
// ============================================================================

/// @title IOptimismPortal Interface
/// @notice Interface for Optimism Portal (used for proving and finalizing withdrawals)
/// @dev Used for the two-step withdrawal process from L2 to L1
interface IOptimismPortal {
    /// @notice Proves a withdrawal transaction
    /// @param _tx Withdrawal transaction to prove
    /// @param _l2OutputIndex Index of the L2 output
    /// @param _outputRootProof Proof of the L2 output root
    /// @param _withdrawalProof Proof of the withdrawal
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256 _l2OutputIndex,
        Types.OutputRootProof memory _outputRootProof,
        bytes[] calldata _withdrawalProof
    ) external;

    /// @notice Finalizes a withdrawal transaction
    /// @param _tx Withdrawal transaction to finalize
    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external;

    /// @notice Checks if a withdrawal transaction has been proven
    /// @param _withdrawalHash Hash of the withdrawal transaction
    /// @return True if proven, false otherwise
    function provenWithdrawals(bytes32 _withdrawalHash) external view returns (bool);

    /// @notice Checks if a withdrawal transaction has already been finalized on the portal
    /// @dev The portal's finalize is permissionless and reverts on a second call for the same hash. The adapter
    ///      reads this to stay idempotent: if a third party front-ran the finalize (funds already delivered to the
    ///      adapter), it skips the re-finalize instead of reverting the whole completion.
    /// @param _withdrawalHash Hash of the withdrawal transaction
    /// @return True if already finalized, false otherwise
    function finalizedWithdrawals(bytes32 _withdrawalHash) external view returns (bool);

    /// @notice Gets the minimum time between proving and finalizing a withdrawal
    /// @return The minimum time in seconds
    function minimumWithdrawalDelay() external view returns (uint256);
}
