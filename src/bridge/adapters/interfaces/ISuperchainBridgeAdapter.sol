// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {IL1StandardBridge, IL2StandardBridge, IOptimismPortal} from "./ISuperchainInterfaces.sol";
import {Types} from "src/bridge/adapters/lib/OptimismTypes.sol";

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
    /// @param withdrawalHash Always bytes32(0) at initiation; the real OP withdrawal hash is only known on L1
    ///        and is set later at prove time (see SuperchainWithdrawalProven)
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

    /// @notice Thrown when an ERC20 L1→L2 deposit has no configured L2 token for the destination L2
    /// @dev Fail-closed guard: the adapter refuses to default the L2 token to the L1 address (wrong for tokens
    ///      like WETH). Wire the mapping via `setL2TokenForL2` before routing that ERC20 over Superchain.
    /// @param l2ChainId The destination L2 chain id
    /// @param l1Token The L1 token that has no L2 mapping
    error L2TokenNotConfigured(uint256 l2ChainId, address l1Token);

    /// @notice Thrown when an L1→L2 deposit has no configured L1CrossDomainMessenger for the destination L2
    /// @dev Each destination L2 (OP, Base) has a DISTINCT L1CrossDomainMessenger; wire it via `setL1MessengerForL2`
    ///      before routing a deposit to that L2 (a single messenger would route other L2s through the wrong one).
    /// @param l2ChainId The destination L2 chain id with no configured messenger
    error MessengerNotConfigured(uint256 l2ChainId);

    /// @notice Thrown when withdrawal proof data is invalid
    error InvalidWithdrawalProof();

    /// @notice Thrown when withdrawal finalization data is invalid
    error InvalidWithdrawalFinalization();

    /// @notice Thrown when withdrawal has not been proven yet
    error WithdrawalNotProven();

    /// @notice Thrown when `proveWithdrawal`'s `l2ChainId` does not match the invoice's encoded source chain id
    /// @param provided The `l2ChainId` passed to `proveWithdrawal`
    /// @param encoded The source chain id encoded in the invoice id (top 3 bytes)
    error WithdrawalChainIdMismatch(uint256 provided, uint256 encoded);

    //
    // State Variables (Public)
    //

    /// @notice L1 Standard Bridge for a destination L2 chain id (L1 side)
    /// @return The L1 Standard Bridge contract instance for that L2
    function l1BridgeForL2(uint256 l2ChainId) external view returns (IL1StandardBridge);

    /// @notice L2 Standard Bridge contract address
    /// @return The L2 Standard Bridge contract instance
    function l2Bridge() external view returns (IL2StandardBridge);

    /// @notice Cross-Domain Messenger contract address (L1) — legacy single value; outbound deposit messages use
    ///         the per-L2 `l1MessengerForL2` instead
    /// @return The Cross-Domain Messenger contract address
    function l1Messenger() external view returns (address);

    /// @notice L1 Cross-Domain Messenger for a destination L2 chain id (L1 side)
    /// @param l2ChainId The destination L2 chain id
    /// @return The L1CrossDomainMessenger address the deposit completion message is sent through for that L2
    function l1MessengerForL2(uint256 l2ChainId) external view returns (address);

    /// @notice The chain id treated as "the L1 side" for this deployment (mainnet = 1)
    /// @return The configured L1 chain id
    function l1ChainId() external view returns (uint256);

    /// @notice Min-gas limit for the authenticated `completeDeposit` cross-domain message
    /// @return The gas limit
    function completeDepositGasLimit() external view returns (uint32);

    /// @notice Cross-Domain Messenger contract address (L2)
    /// @return The Cross-Domain Messenger contract address
    function l2Messenger() external view returns (address);

    /// @notice Optimism Portal for a source L2 chain id (L1 side)
    /// @return The Optimism Portal contract instance for that L2
    function optimismPortalForL2(uint256 l2ChainId) external view returns (IOptimismPortal);

    /// @notice The chain ID where this adapter is deployed
    /// @return The chain ID
    function chainId() external view returns (uint256);

    /// @notice Gets the stored message payload for an operation, keyed by the per-operation invoice hash
    /// @param invoiceHash The per-operation invoice hash (checksum, 32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceHash) external view returns (bytes memory);

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
    /// @param l2Bridge_ The L2 Standard Bridge contract address (L2 side only)
    /// @param l1Messenger_ The L1 Cross-Domain Messenger contract address (L1 side only; legacy — outbound uses
    ///        the per-L2 `l1MessengerForL2`, seeded via `setL1MessengerForL2`)
    /// @param l2Messenger_ The L2 Cross-Domain Messenger contract address (L2 side only)
    /// @param l1ChainId_ The chain id that is "the L1 side" (mainnet = 1); the adapter plays the L1 role when
    ///        `block.chainid == l1ChainId_`. Pass the SAME value to both siblings so the CREATE2 address is unaffected.
    /// @param version_ The adapter version
    /// @dev L1 per-L2 bridges/portals/messengers are seeded after init via setL1BridgeForL2 / setOptimismPortalForL2
    ///      / setL1MessengerForL2.
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address l2Bridge_,
        address l1Messenger_,
        address l2Messenger_,
        uint256 l1ChainId_,
        string memory version_
    ) external;

    /// @notice Sets the L1 Standard Bridge for a destination L2 chain id
    /// @param l2ChainId The destination L2 chain id
    /// @param l1Bridge_ The L1 Standard Bridge contract address for that L2
    /// @dev Only callable by admin role; only valid on the L1 deployment (reverts InvalidChainId on an L2)
    function setL1BridgeForL2(uint256 l2ChainId, address l1Bridge_) external;

    /// @notice Sets the L2 Standard Bridge contract address
    /// @param l2Bridge_ The L2 Standard Bridge contract address
    /// @dev Only callable by admin role; only valid on an L2 deployment (reverts InvalidChainId on L1)
    function setL2Bridge(address l2Bridge_) external;

    /// @notice Sets the L1 Cross-Domain Messenger contract address (legacy single value)
    /// @param l1Messenger_ The L1 Cross-Domain Messenger contract address
    /// @dev Only callable by admin role; only valid on the L1 deployment (reverts InvalidChainId on an L2)
    function setL1Messenger(address l1Messenger_) external;

    /// @notice Sets the L1 Cross-Domain Messenger for a destination L2 chain id (used for the deposit message)
    /// @param l2ChainId The destination L2 chain id
    /// @param l1Messenger_ The L1CrossDomainMessenger address for that L2 (OP and Base differ)
    /// @dev Only callable by admin role; only valid on the L1 deployment (reverts InvalidChainId on an L2)
    function setL1MessengerForL2(uint256 l2ChainId, address l1Messenger_) external;

    /// @notice Sets the min-gas limit for the authenticated `completeDeposit` cross-domain message
    /// @param gasLimit The gas limit to use
    /// @dev Only callable by admin role
    function setCompleteDepositGasLimit(uint32 gasLimit) external;

    /// @notice Sets the L2 Cross-Domain Messenger contract address
    /// @param l2Messenger_ The L2 Cross-Domain Messenger contract address
    /// @dev Only callable by admin role; only valid on an L2 deployment (reverts InvalidChainId on L1)
    function setL2Messenger(address l2Messenger_) external;

    /// @notice Sets the Optimism Portal for a source L2 chain id
    /// @param l2ChainId The source L2 chain id
    /// @param optimismPortal_ The Optimism Portal contract address for that L2
    /// @dev Only callable by admin role; only valid on the L1 deployment (reverts InvalidChainId on an L2). When
    ///      enabling a NEW withdrawal-source L2, also wire its `setL1MessengerForL2` — the L2→L1 finalize path binds a
    ///      front-run withdrawal's target to `l1MessengerForL2[sourceChainId]`, so a portal-only config would revert
    ///      `MessengerNotConfigured` at completion. (The `05` deploy seeds both together, index-aligned.)
    function setOptimismPortalForL2(uint256 l2ChainId, address optimismPortal_) external;

    /// @notice Sets the L2 token for a (destination L2 chain id, L1 token)
    /// @param l2ChainId The destination L2 chain id
    /// @param l1Token The L1 token address
    /// @param l2Token The corresponding L2 token address (unset falls back to the same address)
    /// @dev Only callable by admin role; only valid on the L1 deployment.
    function setL2TokenForL2(uint256 l2ChainId, address l1Token, address l2Token) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an operation, keyed by the per-operation invoice hash
    /// @param invoiceHash The per-operation invoice hash (checksum, 32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceHash) external view returns (bytes memory);

    /// @notice Gets the full `WithdrawalTransaction` stored at prove time for an invoice (ADR 0028)
    /// @dev Lets the settlement keeper finalize an already-proven L2->L1 withdrawal without re-deriving the
    ///      transaction from the source L2 `MessagePassed` log. Keyed by the per-operation invoice HASH (not the
    ///      reusable route `invoiceId`). Returns a zero-valued struct if not proven.
    /// @param invoiceHash The per-operation invoice hash (checksum, 32 bytes)
    /// @return The stored withdrawal transaction
    function getWithdrawalTransaction(bytes32 invoiceHash) external view returns (Types.WithdrawalTransaction memory);

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
    function isWithdrawalProven(uint256 l2ChainId, bytes32 withdrawalHash) external view returns (bool);

    /// @notice Reports whether a `completeBridge` call would make progress settling this withdrawal's invoice
    ///         RIGHT NOW: true when the withdrawal is finalizable via the portal (proven, past the proof-maturity
    ///         delay and the dispute-game finality air-gap, its game resolved in the defender's favour and of the
    ///         respected type, not blacklisted) OR when a permissionless front-run has ALREADY finalized it on the
    ///         portal (completeBridge's skip branch settles it) — and false once the adapter has settled it.
    /// @dev For the not-yet-finalized case it delegates the maturity/air-gap/resolution gate to the portal's own
    ///      `checkWithdrawal` view, so it can never drift from what the portal enforces at finalize. An
    ///      already-finalized-but-unsettled withdrawal reports true so a settler does not strand it (the skip/settle
    ///      path still applies). A paused portal is not reflected (a rare, transient emergency the finalize call
    ///      itself would surface).
    /// @param l2ChainId The source L2 chain id whose portal proved the withdrawal
    /// @param withdrawalHash The withdrawal transaction hash
    /// @return True iff the withdrawal is finalizable now, false otherwise
    function canFinalizeWithdrawal(uint256 l2ChainId, bytes32 withdrawalHash) external view returns (bool);
}
