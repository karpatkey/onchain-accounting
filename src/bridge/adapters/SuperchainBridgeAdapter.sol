// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IL1StandardBridge, IL2StandardBridge, IOptimismPortal} from "./interfaces/ISuperchainInterfaces.sol";
import {Types} from "@optimism/libraries/Types.sol";
import {ISuperchainBridgeAdapter} from "./interfaces/ISuperchainBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title SuperchainBridgeAdapter
/// @notice Bridge adapter for Optimism Superchain canonical bridges
/// @dev Enables bridging ETH and ERC20 tokens between L1 and Superchain L2s (Optimism, Base, Unichain, etc.)
/// @dev Uses the canonical bridge contracts (L1StandardBridge, L2StandardBridge, OptimismPortal)
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
    /// @dev Used to correlate withdrawal transactions with invoice IDs
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

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //
    // Initialization
    //

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
    ) external initializer {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super.initialize(admin_, bridgeEscrow_, "Superchain", version_);
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
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Handles both L1 → L2 deposits and L2 → L1 withdrawals
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for Cross-Domain Messenger
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);
        bool isEth = _isNativeToken(asset);

        // Determine if this is L1 → L2 (deposit) or L2 → L1 (withdrawal)
        // If we're on L1 (mainnet), it's L1 → L2 deposit
        // Otherwise, it's L2 → L1 withdrawal (may not be Optimism, but we handle it)
        bool isL1ToL2 = (chainId == 1);

        if (isL1ToL2) {
            // L1 → L2 Deposit (fast, can be completed immediately)
            if (address(l1Bridge) == address(0)) revert InvalidL1Bridge();
            _depositToL2(data, asset, isEth, messagePayload);
        } else {
            // L2 → L1 Withdrawal (requires two-step process: prove + finalize)
            if (address(l2Bridge) == address(0)) revert InvalidL2Bridge();
            _withdrawToL1(data, asset, isEth, messagePayload);
        }
    }

    /// @notice Handles L1 → L2 deposit
    /// @param data The invoice data
    /// @param asset The asset address (address(0) for ETH)
    /// @param isEth Whether the asset is native ETH
    /// @param messagePayload The encoded message payload
    function _depositToL2(
        InvoiceDataLib.InvoiceData memory data,
        address asset,
        bool isEth,
        bytes memory messagePayload
    ) internal {
        // Use bridgeEscrow as receiver on L2 - bridgeEscrow on destination chain (all BridgeEscrows have the same address)
        // BridgeEscrow will release to account via releaseByInvoiceId() using account from messagePayload
        address receiver = bridgeEscrow;

        if (isEth) {
            // Deposit ETH to L2
            l1Bridge.depositETHTo{value: data.amount}(receiver, defaultL2GasLimit, messagePayload);
        } else {
            // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

            // Deposit ERC20 token to L2
            // Get L2 token address from mapping
            address l2Token = l1ToL2Token[asset];
            // Note: l2Token can be address(0) if not mapped, which is different from native token check
            // We use _isNativeToken() for asset checks, but l2Token == address(0) here means "not mapped"
            if (l2Token == address(0)) {
                // If not mapped, assume same address (for standard bridge tokens)
                l2Token = asset;
            }

            // Approve L1 bridge to spend tokens
            IERC20(asset).forceApprove(address(l1Bridge), data.amount);

            // Deposit ERC20 token to L2
            l1Bridge.depositERC20To(asset, l2Token, receiver, data.amount, defaultL2GasLimit, messagePayload);
        }

        // Store messagePayload for later retrieval
        messagePayloads[data.invoiceId] = messagePayload;

        emit SuperchainBridgeInitiated(data.invoiceId, uint64(data.destinationChainId), bytes32(data.amount), isEth);
    }

    /// @notice Handles L2 → L1 withdrawal
    /// @param data The invoice data
    /// @param asset The asset address (address(0) for ETH)
    /// @param isEth Whether the asset is native ETH
    /// @param messagePayload The encoded message payload
    function _withdrawToL1(
        InvoiceDataLib.InvoiceData memory data,
        address asset,
        bool isEth,
        bytes memory messagePayload
    ) internal {
        // Use bridgeEscrow as receiver on L1 - bridgeEscrow on destination chain (all BridgeEscrows have the same address)
        // BridgeEscrow will release to account via releaseByInvoiceId() using account from messagePayload
        address receiver = bridgeEscrow;

        if (isEth) {
            // Withdraw ETH to L1
            // L2StandardBridge.withdrawTo signature: withdrawTo(address _l2Token, address _to, uint256 _amount, uint32 _minGasLimit, bytes calldata _extraData)
            // For ETH, _l2Token should be Predeploys.LEGACY_ERC20_ETH (0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000)
            address legacyErc20Eth = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;
            l2Bridge.withdrawTo{value: data.amount}(
                legacyErc20Eth, receiver, data.amount, defaultL1GasLimit, messagePayload
            );
        } else {
            // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

            // Withdraw ERC20 token to L1
            // Approve L2 bridge to spend tokens
            IERC20(asset).forceApprove(address(l2Bridge), data.amount);

            // Withdraw ERC20 token to L1 using the 5-parameter version
            l2Bridge.withdrawTo(asset, receiver, data.amount, defaultL1GasLimit, messagePayload);
        }

        // Calculate withdrawal hash for tracking
        // The withdrawal hash is calculated from the withdrawal transaction
        // For now, we'll use a hash of the invoiceId and amount as a placeholder
        // In practice, this should be extracted from the withdrawal transaction
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 withdrawalHash = keccak256(abi.encodePacked(data.invoiceId, data.amount, block.timestamp));

        // Store mappings for correlation
        withdrawalHashToInvoiceId[withdrawalHash] = data.invoiceId;
        invoiceToWithdrawalHash[data.invoiceId] = withdrawalHash;

        // Store messagePayload for later retrieval
        messagePayloads[data.invoiceId] = messagePayload;

        emit SuperchainWithdrawalInitiated(
            data.invoiceId, uint64(data.destinationChainId), bytes32(data.amount), withdrawalHash
        );
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Handles completion for both deposits and withdrawals
    /// @notice For L1 → L2 deposits: Completion is automatic (tokens arrive on L2 immediately)
    ///         For L2 → L1 withdrawals: Requires two-step process (prove + finalize)
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        // Validate messagePayload is not empty
        if (messagePayload.length == 0) {
            revert InvalidCompletionData();
        }

        // Decode messagePayload into invoice data struct
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Note: Checksum validation is done in BridgeEscrow.releaseByInvoiceId()
        // No need to validate here to avoid redundant gas costs

        // Determine if this is L1 → L2 (deposit) or L2 → L1 (withdrawal)
        // If we're on L1 (mainnet), it's L1 → L2 deposit
        // Otherwise, it's L2 → L1 withdrawal
        bool isL1ToL2 = (chainId == 1);

        if (isL1ToL2) {
            // L1 → L2 deposits are fast - tokens should already be on L2
            // Just verify and complete
            _completeDeposit(data, messagePayload);
        } else {
            // L2 → L1 withdrawals require two-step process
            // Check if protocolData contains withdrawal finalization data
            if (protocolData.length > 0) {
                // Decode and finalize withdrawal
                _finalizeWithdrawal(protocolData);
            } else {
                // No protocol data - assume deposit completion or operator will provide finalization later
                // For withdrawals, tokens are not yet available until finalization
                _completeDeposit(data, messagePayload);
            }
        }

        // Store messagePayload if provided
        if (messagePayload.length > 0) {
            messagePayloads[data.invoiceId] = messagePayload;
        }

        emit SuperchainBridgeCompleted(data.invoiceId, uint64(data.sourceChainId));
    }

    /// @notice Completes a deposit (L1 → L2)
    /// @param data The invoice data
    function _completeDeposit(
        InvoiceDataLib.InvoiceData memory data,
        bytes calldata /* messagePayload */
    )
        internal
    {
        // For L1 → L2 deposits, tokens should be at bridgeEscrow (receiver = bridgeEscrow)
        // But if they arrived at adapter, transfer them to bridgeEscrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);

        // Transfer tokens to escrow (requires exact amount, reverts if insufficient)
        // This will also notify BridgeEscrow to emit TokensTransferredToEscrow event
        _transferTokensToEscrow(data.invoiceId, asset, data.amount);
    }

    /// @notice Finalizes a withdrawal (L2 → L1)
    /// @param protocolData The protocol data containing withdrawal transaction
    function _finalizeWithdrawal(bytes calldata protocolData) internal {
        // Decode withdrawal transaction from protocolData
        Types.WithdrawalTransaction memory withdrawalTx = abi.decode(protocolData, (Types.WithdrawalTransaction));

        // Calculate withdrawal hash (matches Optimism's calculation)
        // forge-lint: disable-start(asm-keccak256)
        bytes32 withdrawalHash = keccak256(
            abi.encodePacked(
                withdrawalTx.nonce,
                withdrawalTx.sender,
                withdrawalTx.target,
                withdrawalTx.value,
                withdrawalTx.gasLimit,
                withdrawalTx.data
            )
        );
        // forge-lint: disable-end(asm-keccak256)

        // Verify withdrawal has been proven
        if (!optimismPortal.provenWithdrawals(withdrawalHash)) {
            revert WithdrawalNotProven();
        }

        // Finalize the withdrawal (portal will check challenge period)
        optimismPortal.finalizeWithdrawalTransaction(withdrawalTx);

        // Get invoice ID from withdrawal hash
        bytes32 invoiceId = withdrawalHashToInvoiceId[withdrawalHash];
        if (invoiceId != bytes32(0)) {
            emit SuperchainBridgeCompleted(invoiceId, 1); // Source is L1
        }
    }

    /// @notice Proves a withdrawal transaction
    /// @param withdrawalTx The withdrawal transaction to prove
    /// @param l2OutputIndex The L2 output index
    /// @param outputRootProof The output root proof
    /// @param withdrawalProof The withdrawal proof
    /// @dev This function should be called by an operator after the withdrawal is initiated
    function proveWithdrawal(
        Types.WithdrawalTransaction memory withdrawalTx,
        uint256 l2OutputIndex,
        Types.OutputRootProof memory outputRootProof,
        bytes[] calldata withdrawalProof
    ) external onlyRole(OPERATOR_ROLE) {
        // Calculate withdrawal hash
        // forge-lint: disable-start(asm-keccak256)
        bytes32 withdrawalHash = keccak256(
            abi.encodePacked(
                withdrawalTx.nonce,
                withdrawalTx.sender,
                withdrawalTx.target,
                withdrawalTx.value,
                withdrawalTx.gasLimit,
                withdrawalTx.data
            )
        );
        // forge-lint: disable-end(asm-keccak256)

        // Prove the withdrawal
        optimismPortal.proveWithdrawalTransaction(withdrawalTx, l2OutputIndex, outputRootProof, withdrawalProof);

        // Get invoice ID from withdrawal hash
        bytes32 invoiceId = withdrawalHashToInvoiceId[withdrawalHash];
        if (invoiceId != bytes32(0)) {
            emit SuperchainWithdrawalProven(invoiceId, withdrawalHash);
        }
    }

    /// @notice Finalizes a withdrawal transaction (public function for operators)
    /// @param withdrawalTx The withdrawal transaction to finalize
    /// @dev This function should be called by an operator after the withdrawal is proven and challenge period has elapsed
    function finalizeWithdrawal(Types.WithdrawalTransaction memory withdrawalTx) external onlyRole(OPERATOR_ROLE) {
        // Calculate withdrawal hash
        // forge-lint: disable-start(asm-keccak256)
        bytes32 withdrawalHash = keccak256(
            abi.encodePacked(
                withdrawalTx.nonce,
                withdrawalTx.sender,
                withdrawalTx.target,
                withdrawalTx.value,
                withdrawalTx.gasLimit,
                withdrawalTx.data
            )
        );
        // forge-lint: disable-end(asm-keccak256)

        // Verify withdrawal has been proven
        if (!optimismPortal.provenWithdrawals(withdrawalHash)) {
            revert WithdrawalNotProven();
        }

        // Finalize the withdrawal (portal will check challenge period)
        optimismPortal.finalizeWithdrawalTransaction(withdrawalTx);

        // Get invoice ID from withdrawal hash
        bytes32 invoiceId = withdrawalHashToInvoiceId[withdrawalHash];
        if (invoiceId != bytes32(0)) {
            emit SuperchainBridgeCompleted(invoiceId, 1); // Source is L1
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
        // Check if withdrawal has been proven
        if (!optimismPortal.provenWithdrawals(withdrawalHash)) {
            return false;
        }

        // Note: The actual challenge period check is done in the OptimismPortal contract
        // This function just checks if the withdrawal is proven
        // The portal will revert if the challenge period hasn't elapsed
        return true;
    }

    //
    // Receive Function
    //

    /// @notice Receives native ETH
    /// @dev This function is called when native ETH is received
    receive() external payable {
        // Native ETH received - messagePayload should be provided via completeBridge
    }
}
