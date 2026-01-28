// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IOmnibridge, IAMB} from "./interfaces/IGnosisInterfaces.sol";
import {IGnosisBridgeAdapter} from "./interfaces/IGnosisBridgeAdapter.sol";
import "src/errors.sol";

/// @title GnosisBridgeAdapter
/// @notice Bridge adapter for Gnosis Omnibridge (Ethereum ↔ Gnosis Chain)
/// @dev Enables bridging tokens and messages between Ethereum and Gnosis Chain via AMB
/// @author kpk
contract GnosisBridgeAdapter is BridgeAdapter, IGnosisBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice Omnibridge contract address
    IOmnibridge public omnibridge;

    /// @notice AMB contract address (for message verification)
    IAMB public amb;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Mapping from AMB transaction hash to invoice ID
    /// @dev Used to correlate AMB messages with invoice IDs
    mapping(bytes32 => bytes32) public transactionHashToInvoiceId;

    /// @notice Mapping from invoice ID to AMB transaction hash
    /// @dev Used to track which transaction hash was used for each invoice
    mapping(bytes32 => bytes32) public invoiceToTransactionHash;

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

    /// @inheritdoc IGnosisBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address omnibridge_,
        address amb_,
        string memory version_
    ) external initializer {
        // Initialize parent BridgeAdapter
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = "Gnosis";
        adapterVersion = version_;

        if (omnibridge_ == address(0)) revert InvalidOmnibridge();
        if (amb_ == address(0)) revert InvalidAMB();

        omnibridge = IOmnibridge(omnibridge_);
        amb = IAMB(amb_);
    }

    //
    // Configuration
    //

    /// @inheritdoc IGnosisBridgeAdapter
    function setOmnibridge(address omnibridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (omnibridge_ == address(0)) revert InvalidOmnibridge();
        omnibridge = IOmnibridge(omnibridge_);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function setAmb(address amb_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amb_ == address(0)) revert InvalidAMB();
        amb = IAMB(amb_);
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to Gnosis Omnibridge format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for Omnibridge message data
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);

        // Validate destination chain is supported (Ethereum or Gnosis Chain)
        // Chain ID 1 = Ethereum, Chain ID 100 = Gnosis Chain
        // Gnosis Omnibridge only supports bridging between these two chains
        if (uint64(data.destinationChainId) != 1 && uint64(data.destinationChainId) != 100) {
            revert UnsupportedChain(uint64(data.destinationChainId));
        }

        // Recipient is BridgeEscrow; escrow fallback forwards onTokenTransfer to this adapter
        address receiver = bridgeEscrow;

        // messagePayload already contains invoiceId + amount + timestamp + checksum, so we send it as-is
        bytes memory messageData = messagePayload;

        // Check if asset is native token (address(0) or NATIVE_ADDRESS_ERC7528)
        if (_isNativeToken(asset)) {
            // Native tokens (ETH/xDAI) are not directly supported by Omnibridge
            // They must be wrapped first (e.g., WETH/WXDAI) before bridging
            revert NativeTokenNotSupported();
        }

        // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

        // ERC20 token
        // Approve Omnibridge to spend tokens
        IERC20(asset).forceApprove(address(omnibridge), data.amount);

        // Call relayTokensAndCall with token address
        omnibridge.relayTokensAndCall(asset, receiver, data.amount, messageData);

        // Store messagePayload for later retrieval
        messagePayloads[data.invoiceId] = messageData;

        // Note: AMB transaction hash is not available immediately, it will be set when message is received
        // We emit event with zero hash for now, will be updated on completion
        emit GnosisBridgeInitiated(
            data.invoiceId, uint64(data.destinationChainId), receiver, bytes32(data.amount), bytes32(0)
        );
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Completes bridge on destination chain (operator fallback when callback path not used).
    ///      When recipient is BridgeEscrow, tokens are delivered to escrow; we only record and release.
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        if (messagePayload.length == 0) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        bytes32 transactionHash = bytes32(0);
        try amb.transactionHash() returns (bytes32 txHash) {
            transactionHash = txHash;
            transactionHashToInvoiceId[transactionHash] = data.invoiceId;
            invoiceToTransactionHash[data.invoiceId] = transactionHash;
        } catch {}

        if (messagePayload.length > 0) messagePayloads[data.invoiceId] = messagePayload;
        emit GnosisBridgeCompleted(data.invoiceId, uint64(data.sourceChainId), transactionHash);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    /// @dev When called by BridgeEscrow (escrow fallback forwards here), completes delivery.
    ///      When called directly on the adapter, reverts.
    function onTokenTransfer(address, bytes32 value, bytes memory data) external returns (bool) {
        if (msg.sender != bridgeEscrow) revert NotAuthorized();
        _completeDelivery(data);
        return true;
    }

    function _completeDelivery(bytes memory messagePayload) internal {
        if (messagePayload.length == 0) revert InvalidCompletionData();
        if (messagePayload.length >= 96) {
            InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
            messagePayloads[data.invoiceId] = messagePayload;
            try amb.transactionHash() returns (bytes32 txHash) {
                transactionHashToInvoiceId[txHash] = data.invoiceId;
                invoiceToTransactionHash[data.invoiceId] = txHash;
            } catch {}
        }
        IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
    }

    /// @inheritdoc IGnosisBridgeAdapter
    receive() external payable {
        // Native tokens received - messagePayload should be provided via completeBridge
        // We cannot extract messagePayload from receive() directly, so operator must provide it
    }

    //
    // View Functions
    //

    /// @inheritdoc IGnosisBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function getInvoiceIdByTransactionHash(bytes32 transactionHash) external view returns (bytes32) {
        return transactionHashToInvoiceId[transactionHash];
    }

    /// @inheritdoc IGnosisBridgeAdapter
    function getTransactionHashByInvoiceId(bytes32 invoiceId) external view returns (bytes32) {
        return invoiceToTransactionHash[invoiceId];
    }

    /// @inheritdoc IGnosisBridgeAdapter
    /// @dev Checks if tokens are available in the adapter for a given invoice.
    ///      On Gnosis Chain, tokens are automatically transferred via onTokenTransfer.
    ///      On Mainnet, tokens may need to be manually claimed from Omnibridge first.
    function areTokensAvailable(bytes32 invoiceId, address asset) external view returns (bool) {
        if (_isNativeToken(asset)) {
            return false;
        }

        // Get the expected amount from the stored messagePayload
        bytes memory payload = messagePayloads[invoiceId];
        if (payload.length == 0) {
            return false;
        }

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(payload);
        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));

        return adapterBalance >= data.amount;
    }

    /// @notice Checks if the contract supports an interface
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
