// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {
    IL1StandardBridge,
    IL2StandardBridge,
    IOptimismPortal,
    ICrossDomainMessenger
} from "./interfaces/ISuperchainInterfaces.sol";
import {Types} from "@optimism/libraries/Types.sol";
import {ISuperchainBridgeAdapter} from "./interfaces/ISuperchainBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title SuperchainBridgeAdapter
/// @notice Bridge adapter for Optimism Superchain canonical bridges (L1 <-> L2, both directions).
/// @dev The destination recipient is always the sibling adapter (`address(this)`, same address across chains
///      via CREATE2) for both L1->L2 deposits and L2->L1 withdrawals, so delivered ETH/tokens land on the
///      adapter and the funded pass-through release (ADR 0012) draws from the adapter's own balance.
///
///      Provenance (ADR 0012, D1/D2): there is no escrow fallback dispatcher. Each inbound completion path
///      authenticates the genuine OP Stack contract and the source-chain sender:
///        - L1->L2 deposit: the L2CrossDomainMessenger relays the message to this adapter. The adapter
///          requires `msg.sender == l2Messenger` AND
///          `l2Messenger.xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`.
///        - L2->L1 withdrawal: proof-gated through the OptimismPortal. The adapter computes the REAL OP
///          withdrawal hash (`keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))`,
///          matching `Hashing.hashWithdrawal`) and only completes once the portal reports the withdrawal
///          proven, then finalizes it (the portal delivers the ETH to this adapter as the withdrawal target).
/// @author kpk
contract SuperchainBridgeAdapter is BridgeAdapter, ISuperchainBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice L1 Standard Bridge contract address
    IL1StandardBridge public l1Bridge;

    /// @notice L2 Standard Bridge contract address
    IL2StandardBridge public l2Bridge;

    /// @notice L1 Cross-Domain Messenger contract address
    address public l1Messenger;

    /// @notice L2 Cross-Domain Messenger contract address
    address public l2Messenger;

    /// @notice Optimism Portal contract address
    IOptimismPortal public optimismPortal;

    /// @notice The chain ID where this adapter is deployed
    uint256 public chainId;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Mapping from withdrawal hash to invoice ID
    /// @dev Used to correlate withdrawal transactions with invoice IDs. The key is the REAL OP withdrawal
    ///      hash (see `_hashWithdrawal`), set on L1 when the manager proves the withdrawal.
    mapping(bytes32 => bytes32) public withdrawalHashToInvoiceId;

    /// @notice Mapping from invoice ID to withdrawal hash
    /// @dev Used to track which withdrawal hash was used for each invoice
    mapping(bytes32 => bytes32) public invoiceToWithdrawalHash;

    /// @notice Mapping from L1 token address to L2 token address
    /// @dev Used for ERC20 token deposits (L1 → L2)
    mapping(address => address) public l1ToL2Token;

    /// @notice Default L2 gas limit for deposits
    uint32 public defaultL2GasLimit = 200000;

    /// @notice Default L1 gas limit for withdrawals
    uint32 public defaultL1GasLimit = 200000;

    /// @inheritdoc ISuperchainBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address l1Bridge_,
        address l2Bridge_,
        address l1Messenger_,
        address l2Messenger_,
        address optimismPortal_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "Superchain", version_);
        chainId = block.chainid;

        // On L1 (mainnet), only initialize L1 contracts
        if (chainId == 1) {
            if (l1Bridge_ == address(0)) revert InvalidL1Bridge();
            if (l1Messenger_ == address(0)) revert InvalidCrossDomainMessenger();
            if (optimismPortal_ == address(0)) revert InvalidOptimismPortal();

            l1Bridge = IL1StandardBridge(l1Bridge_);
            l1Messenger = l1Messenger_;
            optimismPortal = IOptimismPortal(optimismPortal_);
        } else {
            // On L2, only initialize L2 contracts
            if (l2Bridge_ == address(0)) revert InvalidL2Bridge();
            if (l2Messenger_ == address(0)) revert InvalidCrossDomainMessenger();

            l2Bridge = IL2StandardBridge(l2Bridge_);
            l2Messenger = l2Messenger_;
        }
    }

    //
    // Configuration
    //

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL1Bridge(address l1Bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != 1) revert InvalidChainId();
        if (l1Bridge_ == address(0)) revert InvalidL1Bridge();
        l1Bridge = IL1StandardBridge(l1Bridge_);
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL2Bridge(address l2Bridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId == 1) revert InvalidChainId();
        if (l2Bridge_ == address(0)) revert InvalidL2Bridge();
        l2Bridge = IL2StandardBridge(l2Bridge_);
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL1Messenger(address l1Messenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != 1) revert InvalidChainId();
        if (l1Messenger_ == address(0)) revert InvalidCrossDomainMessenger();
        l1Messenger = l1Messenger_;
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setL2Messenger(address l2Messenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId == 1) revert InvalidChainId();
        if (l2Messenger_ == address(0)) revert InvalidCrossDomainMessenger();
        l2Messenger = l2Messenger_;
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function setOptimismPortal(address optimismPortal_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainId != 1) revert InvalidChainId();
        if (optimismPortal_ == address(0)) revert InvalidOptimismPortal();
        optimismPortal = IOptimismPortal(optimismPortal_);
    }

    /// @notice Sets the default L2 gas limit for deposits
    /// @param gasLimit The gas limit to use
    /// @dev Only callable by admin role
    function setDefaultL2GasLimit(uint32 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultL2GasLimit = gasLimit;
    }

    /// @notice Sets the default L1 gas limit for withdrawals
    /// @param gasLimit The gas limit to use
    /// @dev Only callable by admin role
    function setDefaultL1GasLimit(uint32 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultL1GasLimit = gasLimit;
    }

    /// @notice Sets the L2 token address for a given L1 token address
    /// @param l1Token The L1 token address
    /// @param l2Token The corresponding L2 token address
    /// @dev Only callable by admin role
    function setL1ToL2Token(address l1Token, address l2Token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        l1ToL2Token[l1Token] = l2Token;
    }

    //
    // BridgeAdapter Implementation (outbound)
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Handles both L1 → L2 deposits and L2 → L1 withdrawals
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for Cross-Domain Messenger
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
        bool isEth = _isNativeToken(asset);

        // If we're on L1 (mainnet), it's an L1 → L2 deposit; otherwise an L2 → L1 withdrawal.
        if (chainId == 1) {
            if (address(l1Bridge) == address(0)) revert InvalidL1Bridge();
            _depositToL2(data, asset, isEth, messagePayload);
        } else {
            if (address(l2Bridge) == address(0)) revert InvalidL2Bridge();
            _withdrawToL1(data, asset, isEth, messagePayload);
        }
    }

    /// @notice Handles L1 → L2 deposit
    /// @dev Recipient on L2 is the sibling adapter (`address(this)`, same address via CREATE2). Delivered
    ///      ETH/tokens land on the L2 adapter, which authenticates and releases on completion.
    function _depositToL2(
        InvoiceDataLib.InvoiceData memory data,
        address asset,
        bool isEth,
        bytes memory messagePayload
    ) internal {
        address receiver = address(this);

        if (isEth) {
            l1Bridge.depositETHTo{value: data.amount}(receiver, defaultL2GasLimit, messagePayload);
        } else {
            // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

            // Resolve the L2 token; default to the same address (standard bridge tokens) when unmapped.
            address l2Token = l1ToL2Token[asset];
            if (l2Token == address(0)) {
                l2Token = asset;
            }

            // Approve L1 bridge to spend tokens and deposit to L2
            IERC20(asset).forceApprove(address(l1Bridge), data.amount);
            l1Bridge.depositERC20To(asset, l2Token, receiver, data.amount, defaultL2GasLimit, messagePayload);
        }

        // Store messagePayload for later retrieval
        messagePayloads[data.invoiceId] = messagePayload;

        emit SuperchainBridgeInitiated(data.invoiceId, uint64(data.destinationChainId), bytes32(data.amount), isEth);
    }

    /// @notice Handles L2 → L1 withdrawal
    /// @dev Recipient on L1 is the sibling adapter (`address(this)`). The real OP withdrawal hash is only
    ///      known on L1 (it depends on the L2ToL1MessagePasser nonce), so invoice↔withdrawalHash correlation
    ///      is established on L1 at prove time (see `proveWithdrawal`) from the actual WithdrawalTransaction.
    function _withdrawToL1(
        InvoiceDataLib.InvoiceData memory data,
        address asset,
        bool isEth,
        bytes memory messagePayload
    ) internal {
        address receiver = address(this);

        if (isEth) {
            // For ETH, _l2Token is the legacy ERC20 ETH predeploy.
            address legacyErc20Eth = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;
            l2Bridge.withdrawTo{value: data.amount}(
                legacyErc20Eth, receiver, data.amount, defaultL1GasLimit, messagePayload
            );
        } else {
            // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

            IERC20(asset).forceApprove(address(l2Bridge), data.amount);
            l2Bridge.withdrawTo(asset, receiver, data.amount, defaultL1GasLimit, messagePayload);
        }

        // Store messagePayload for later retrieval (withdrawal hash is set on L1 at prove time).
        messagePayloads[data.invoiceId] = messagePayload;

        emit SuperchainWithdrawalInitiated(
            data.invoiceId, uint64(data.destinationChainId), bytes32(data.amount), bytes32(0)
        );
    }

    //
    // Provenance helpers
    //

    /// @notice Computes the canonical OP Stack withdrawal hash for a withdrawal transaction.
    /// @dev Matches `Hashing.hashWithdrawal`: `keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))`.
    function _hashWithdrawal(Types.WithdrawalTransaction memory wtx) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(wtx.nonce, wtx.sender, wtx.target, wtx.value, wtx.gasLimit, wtx.data));
    }

    /// @notice Authenticates an inbound cross-domain message relayed by the L2CrossDomainMessenger.
    /// @dev Provenance check for L1 → L2 deposit completion: the genuine messenger must be the caller and the
    ///      original source-chain sender (revealed by `xDomainMessageSender()`) must be the trusted sibling
    ///      adapter configured for `srcChainId`.
    /// @param srcChainId The source chain id carried in the invoice (the L1 chain for a deposit).
    function _authenticateMessengerSource(uint64 srcChainId) internal view {
        if (msg.sender != l2Messenger) revert NotAuthorized();
        bytes32 expected = trustedRemoteAdapter[srcChainId];
        if (expected == bytes32(0)) revert NotAuthorized();
        address xSender = ICrossDomainMessenger(l2Messenger).xDomainMessageSender();
        if (_toBytes32(xSender) != expected) revert NotAuthorized();
    }

    //
    // BridgeAdapter Implementation (inbound completion)
    //

    /// @inheritdoc BridgeAdapter
    /// @dev MANAGER-operated completion. Performs only protocol verification here; the base
    ///      (`completeBridge`) then funds the escrow and releases (funded pass-through, ADR 0012).
    ///      - On L1 (an L2 → L1 withdrawal completion): finalize the proven withdrawal through the portal,
    ///        which delivers the ETH to this adapter; the base then releases.
    ///      - On L2 (an L1 → L2 deposit completion fallback): the canonical bridge already delivered the
    ///        tokens to this adapter; nothing to do here beyond bookkeeping. (The trust-minimized auto path
    ///        is `completeDeposit`, authenticated against the L2CrossDomainMessenger.)
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        if (messagePayload.length == 0) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        if (chainId == 1) {
            // L2 → L1 withdrawal: finalize via the portal (proof-gated).
            if (protocolData.length == 0) revert InvalidWithdrawalFinalization();
            address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
            _finalizeWithdrawal(protocolData, data.amount, _isNativeToken(asset));
        }
        // On L2 the tokens were delivered to this adapter by the canonical bridge; the base verifies the
        // adapter balance covers `amount` in `_fundAndRelease` and reverts otherwise.

        messagePayloads[data.invoiceId] = messagePayload;

        emit SuperchainBridgeCompleted(data.invoiceId, uint64(data.sourceChainId));
    }

    /// @notice Trust-minimized L1 → L2 deposit completion: the L2CrossDomainMessenger relays the deposit
    ///         message to this adapter, which authenticates the messenger + source sender, then funds the
    ///         escrow and releases (funded pass-through, ADR 0012).
    /// @param messagePayload The encoded invoice payload authored on L1 (forwarded through the messenger).
    /// @dev Authenticated path (no MANAGER role): `msg.sender == l2Messenger` and
    ///      `l2Messenger.xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`. The canonical bridge
    ///      credits the adapter with the bridged ETH/tokens before the messenger relays this call.
    function completeDeposit(bytes calldata messagePayload) external nonReentrant {
        if (messagePayload.length == 0) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Provenance: genuine L2 messenger + trusted sibling adapter as the L1 source sender.
        _authenticateMessengerSource(uint64(data.sourceChainId));

        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        messagePayloads[data.invoiceId] = messagePayload;

        // Funds-and-releases: the escrow validates checksum/replay/account and forwards to the account.
        _fundAndRelease(messagePayload, asset, data.amount);

        emit SuperchainBridgeCompleted(data.invoiceId, uint64(data.sourceChainId));
    }

    /// @notice Finalizes a withdrawal (L2 → L1) through the portal so the funds are delivered to this adapter.
    /// @param protocolData ABI-encoded `Types.WithdrawalTransaction`.
    /// @param amount The invoiced amount.
    /// @param isEth True for native-ETH withdrawals, false for ERC20.
    /// @dev For ETH the withdrawal `target` is this adapter and `value == amount`, so we bind both to the
    ///      invoice. For ERC20 the OP withdrawal `target` is the L1 bridge/messenger and `value == 0` (the
    ///      ERC20 is delivered to the adapter as the `withdrawTo` receiver, not via `target`/`value`), so those
    ///      bindings don't apply — provenance still comes from the proven withdrawal hash + portal Merkle
    ///      proof, and the base `_fundAndRelease` reverts unless the adapter actually received `amount`.
    ///      The withdrawal must already be proven; the portal enforces the challenge period.
    function _finalizeWithdrawal(bytes calldata protocolData, uint256 amount, bool isEth) internal {
        Types.WithdrawalTransaction memory withdrawalTx = abi.decode(protocolData, (Types.WithdrawalTransaction));

        if (isEth) {
            // ETH withdrawals deliver `value` directly to `target` (this adapter); bind both to the invoice.
            if (withdrawalTx.target != address(this)) revert InvalidWithdrawalFinalization();
            if (withdrawalTx.value != amount) revert InvalidWithdrawalFinalization();
        }

        bytes32 withdrawalHash = _hashWithdrawal(withdrawalTx);

        // Verify withdrawal has been proven (provenance: real OP withdrawal hash, portal Merkle proof).
        if (!optimismPortal.provenWithdrawals(withdrawalHash)) {
            revert WithdrawalNotProven();
        }

        // Finalize the withdrawal (portal checks the challenge period; delivers value to the target adapter).
        optimismPortal.finalizeWithdrawalTransaction(withdrawalTx);
    }

    /// @notice Proves a withdrawal transaction and correlates it to its invoice.
    /// @param withdrawalTx The withdrawal transaction to prove (its `target` must be this adapter).
    /// @param l2OutputIndex The L2 output index
    /// @param outputRootProof The output root proof
    /// @param withdrawalProof The withdrawal proof
    /// @param invoiceId The invoice this withdrawal settles (for invoice ↔ withdrawalHash correlation)
    /// @dev MANAGER-driven on L1 after the withdrawal is initiated on L2. Computes the REAL OP withdrawal
    ///      hash and records the invoice correlation so completion can be tracked.
    function proveWithdrawal(
        Types.WithdrawalTransaction memory withdrawalTx,
        uint256 l2OutputIndex,
        Types.OutputRootProof memory outputRootProof,
        bytes[] calldata withdrawalProof,
        bytes32 invoiceId
    ) external onlyRole(MANAGER_ROLE) {
        bytes32 withdrawalHash = _hashWithdrawal(withdrawalTx);

        optimismPortal.proveWithdrawalTransaction(withdrawalTx, l2OutputIndex, outputRootProof, withdrawalProof);

        // Correlate invoice ↔ real withdrawal hash.
        if (invoiceId != bytes32(0)) {
            withdrawalHashToInvoiceId[withdrawalHash] = invoiceId;
            invoiceToWithdrawalHash[invoiceId] = withdrawalHash;
            emit SuperchainWithdrawalProven(invoiceId, withdrawalHash);
        }
    }

    //
    // View Functions
    //

    /// @inheritdoc ISuperchainBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function getWithdrawalHashByInvoiceId(bytes32 invoiceId) external view returns (bytes32) {
        return invoiceToWithdrawalHash[invoiceId];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function getInvoiceIdByWithdrawalHash(bytes32 withdrawalHash) external view returns (bytes32) {
        return withdrawalHashToInvoiceId[withdrawalHash];
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function isWithdrawalProven(bytes32 withdrawalHash) external view returns (bool) {
        return optimismPortal.provenWithdrawals(withdrawalHash);
    }

    /// @inheritdoc ISuperchainBridgeAdapter
    function canFinalizeWithdrawal(bytes32 withdrawalHash) external view returns (bool) {
        // The portal enforces the actual challenge period at finalize; this just reports proven-ness.
        return optimismPortal.provenWithdrawals(withdrawalHash);
    }

    /// @notice Computes the canonical OP Stack withdrawal hash for a withdrawal transaction.
    /// @param withdrawalTx The withdrawal transaction
    /// @return The real OP withdrawal hash (matches `Hashing.hashWithdrawal`)
    function hashWithdrawal(Types.WithdrawalTransaction memory withdrawalTx) external pure returns (bytes32) {
        return _hashWithdrawal(withdrawalTx);
    }

    //
    // Receive Function
    //

    /// @notice Receives native ETH (canonical bridge deposits / portal withdrawal finalization deliver here).
    receive() external payable {}
}
