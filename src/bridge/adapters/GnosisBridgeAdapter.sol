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
    function setAMB(address amb_) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

        // Use bridgeEscrow as receiver - bridgeEscrow on destination chain (all BridgeEscrows have the same address)
        // BridgeEscrow will release to portfolioSafe via releaseByInvoiceId() using portfolioSafe from messagePayload
        // Note: Gnosis requires receiver to implement onTokenTransfer callback, so we use adapter address
        // Tokens will be transferred to bridgeEscrow in _completeBridge before calling releaseByInvoiceId
        address receiver = address(this);

        // messagePayload already contains invoiceId + amount + timestamp + checksum, so we send it as-is
        bytes memory messageData = messagePayload;

        // Check if asset is native token (address(0) or NATIVE_ADDRESS_ERC7528)
        if (_isNativeToken(asset)) {
            // Native tokens (ETH/xDAI) are not directly supported by Omnibridge
            // They must be wrapped first (e.g., WETH/WXDAI) before bridging
            revert NativeTokenNotSupported();
        }

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
    /// @dev Receives AMB message and processes it
    /// @notice On Gnosis Chain: Tokens are automatically transferred via onTokenTransfer callback.
    ///         On Mainnet: Tokens need to be manually claimed from Omnibridge first (AMB message must be processed).
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        // Validate messagePayload is not empty
        if (messagePayload.length == 0) {
            revert InvalidCompletionData();
        }

        // Decode messagePayload into invoice data struct
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Validate checksum
        if (!IBridgeEscrow(bridgeEscrow)
                .validateInvoiceIdChecksum(data.invoiceId, data.amount, data.timestampByte, data.checksum24)) {
            revert InvalidInvoice();
        }

        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);
        bool isNative = _isNativeToken(asset);

        // Transfer tokens from adapter to BridgeEscrow if they arrived at adapter
        // Gnosis sends tokens to receiver (adapter) via onTokenTransfer callback
        if (!isNative) {
            uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
            if (adapterBalance >= data.amount) {
                IERC20(asset).safeTransfer(bridgeEscrow, data.amount);
            } else if (uint64(data.destinationChainId) == 1) {
                // On Mainnet, tokens need to be manually claimed from Omnibridge first
                // If tokens aren't available, revert (operator must ensure AMB message is processed)
                revert TokensNotAvailable();
            }
        }

        // Get AMB transaction hash if available
        bytes32 transactionHash = bytes32(0);
        try amb.transactionHash() returns (bytes32 txHash) {
            transactionHash = txHash;
            // Store mapping for correlation
            transactionHashToInvoiceId[transactionHash] = data.invoiceId;
            invoiceToTransactionHash[data.invoiceId] = transactionHash;
        } catch {
            // Transaction hash not available, continue without it
        }

        // Store messagePayload if provided
        if (messagePayload.length > 0) {
            messagePayloads[data.invoiceId] = messagePayload;
        }

        emit GnosisBridgeCompleted(data.invoiceId, uint64(data.sourceChainId), transactionHash);
    }

    //
    // Receiver Function (for ERC677 tokens)
    //

    /// @inheritdoc IGnosisBridgeAdapter
    function onTokenTransfer(address from, bytes32 value, bytes memory data) external returns (bool) {
        // Verify caller is Omnibridge
        if (msg.sender != address(omnibridge)) {
            revert InvalidOmnibridge();
        }

        // Extract messagePayload from data (exactly 96 bytes = 3 slots)
        if (data.length >= 96) {
            InvoiceDataLib.InvoiceData memory invoiceData = InvoiceDataLib.decode(data);

            // Validate checksum (value is the amount received)
            if (!IBridgeEscrow(bridgeEscrow)
                    .validateInvoiceIdChecksum(
                        invoiceData.invoiceId, invoiceData.amount, invoiceData.timestampByte, invoiceData.checksum24
                    )) {
                revert InvalidInvoice();
            }

            // Store invoiceId mapping and messagePayload
            messagePayloads[invoiceData.invoiceId] = data;

            // Get transaction hash if available
            bytes32 transactionHash = bytes32(0);
            try amb.transactionHash() returns (bytes32 txHash) {
                transactionHash = txHash;
                transactionHashToInvoiceId[transactionHash] = invoiceData.invoiceId;
                invoiceToTransactionHash[invoiceData.invoiceId] = transactionHash;
            } catch {
                // Transaction hash not available
            }
        }

        // Note: On Gnosis Chain, tokens are automatically transferred to this contract by Omnibridge
        //       via the ERC677 onTokenTransfer callback. On Mainnet, tokens need to be manually claimed
        //       from Omnibridge first (AMB message must be processed).
        //       The operator still needs to call completeBridge to release funds from BridgeEscrow
        return true;
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
}
