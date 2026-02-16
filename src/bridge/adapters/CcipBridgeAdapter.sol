// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICcipBridgeAdapter} from "./interfaces/ICcipBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title CcipBridgeAdapter
/// @notice Bridge adapter for Chainlink's Cross-Chain Interoperability Protocol (CCIP)
/// @dev Recipient is always BridgeEscrow; escrow fallback forwards protocol callbacks (e.g. ccipReceive) to this adapter.
/// @author kpk
contract CcipBridgeAdapter is BridgeAdapter, ICcipBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice CCIP Router contract address
    IRouterClient public router;

    /// @notice Fee token address (address(0) for native, or LINK token address)
    address public feeToken;

    /// @notice Mapping from CCIP message ID to invoice ID
    /// @dev Used to correlate CCIP messages with invoice IDs
    ///      Format: messageIdToInvoiceId[messageId] = invoiceId
    mapping(bytes32 => bytes32) public messageIdToInvoiceId;

    /// @notice Mapping from invoice ID to CCIP message ID
    /// @dev Used to track which messageId was used for each invoice
    mapping(bytes32 => bytes32) public invoiceToMessageId;

    /// @notice Mapping from chain ID to CCIP chain selector
    mapping(uint64 => uint64) public chainIdToSelector;

    /// @notice Mapping from CCIP chain selector to chain ID
    mapping(uint64 => uint64) public selectorToChainId;

    /// @notice Mapping to store CCIP extraArgs per chain selector
    /// @dev Used to configure gas limits and other CCIP-specific parameters
    mapping(uint64 => bytes) public chainExtraArgs;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @inheritdoc ICcipBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address feeToken_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "CCIP", version_);

        if (router_ == address(0)) revert InvalidRouter();
        router = IRouterClient(router_);
        feeToken = feeToken_;

        // Approve router to spend fee token if not native
        if (feeToken_ != address(0)) {
            IERC20(feeToken_).forceApprove(router_, type(uint256).max);
        }
    }

    //
    // Configuration
    //

    /// @inheritdoc ICcipBridgeAdapter
    function setChainSelectorMapping(uint64 chainId, uint64 chainSelector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainIdToSelector[chainId] = chainSelector;
        selectorToChainId[chainSelector] = chainId;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router_ == address(0)) revert InvalidRouter();
        router = IRouterClient(router_);
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setFeeToken(address feeToken_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Revoke old approval if needed
        if (feeToken != address(0) && feeToken != feeToken_) {
            IERC20(feeToken).forceApprove(address(router), 0);
        }

        feeToken = feeToken_;

        // Approve new fee token if not native
        if (feeToken_ != address(0)) {
            IERC20(feeToken_).forceApprove(address(router), type(uint256).max);
        }
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setChainExtraArgs(uint64 chainSelector, bytes calldata extraArgs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainExtraArgs[chainSelector] = extraArgs;
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to CCIP-specific format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for CCIP message data
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Convert chain ID to CCIP chain selector
        uint64 destinationChainSelector = chainIdToSelector[uint64(data.destinationChainId)];
        if (destinationChainSelector == 0) {
            revert InvalidChainSelector();
        }

        // Validate chain is supported by CCIP router
        if (!router.isChainSupported(destinationChainSelector)) {
            revert UnsupportedChain(destinationChainSelector);
        }

        // Get asset address from escrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Pull ERC20 tokens from escrow if not native (escrow approved us in depositAndBridge)
        // CCIP doesn't bridge native tokens directly - only ERC20 tokens
        if (!_isNativeToken(asset) && data.amount > 0) {
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
        }

        // Prepare token amounts array
        // CCIP doesn't bridge native tokens directly - only ERC20 tokens
        // Native tokens (address(0) or NATIVE_ADDRESS_ERC7528) are not included in tokenAmounts
        Client.EVMTokenAmount[] memory tokenAmounts;
        if (!_isNativeToken(asset) && data.amount > 0) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: data.amount});

            // Approve router to spend tokens
            IERC20(asset).forceApprove(address(router), data.amount);
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        // Recipient is BridgeEscrow; escrow fallback forwards ccipReceive to this adapter
        bytes memory receiver = abi.encode(bridgeEscrow);

        // Get extraArgs for this chain (use configured or empty for default)
        bytes memory extraArgsToUse = chainExtraArgs[destinationChainSelector];
        if (extraArgsToUse.length == 0) {
            extraArgsToUse = bytes("");
        }

        // Build CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: messagePayload,
            tokenAmounts: tokenAmounts,
            feeToken: feeToken,
            extraArgs: extraArgsToUse
        });

        // Get fee and send message
        uint256 fee = router.getFee(destinationChainSelector, message);
        bytes32 messageId;

        if (feeToken == address(0)) {
            // Pay with native token
            messageId = router.ccipSend{value: fee}(destinationChainSelector, message);
        } else {
            // Pay with fee token (already approved)
            messageId = router.ccipSend(destinationChainSelector, message);
        }

        // Store invoiceId mapping for correlation
        messageIdToInvoiceId[messageId] = data.invoiceId;
        invoiceToMessageId[data.invoiceId] = messageId;

        emit CcipBridgeInitiated(data.invoiceId, destinationChainSelector, messageId, bytes32(data.amount));
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Receives CCIP message and processes it
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        // Decode protocol data (Any2EVMMessage)
        Client.Any2EVMMessage memory message = abi.decode(protocolData, (Client.Any2EVMMessage));

        if (message.data.length == 0) {
            revert InvalidCompletionData();
        }

        // Use messagePayload parameter if available, otherwise use message data directly
        bytes memory payloadToUse = messagePayload.length > 0 ? messagePayload : message.data;

        // Decode payload using InvoiceDataLib
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(payloadToUse);

        // Note: Checksum validation is done in BridgeEscrow.releaseByInvoiceId()
        // No need to validate here to avoid redundant gas costs

        // Store message payload if provided
        if (payloadToUse.length > 0) {
            messagePayloads[data.invoiceId] = payloadToUse;
        }

        // When recipient is BridgeEscrow, tokens are already at escrow; no transfer needed
        emit CcipBridgeCompleted(data.invoiceId, message.messageId, message.sourceChainSelector);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev When called by BridgeEscrow (escrow fallback forwards here), completes delivery.
    ///      When called directly on the adapter, reverts.
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        if (msg.sender != bridgeEscrow) {
            if (msg.sender != address(router)) revert InvalidRouter();
            revert InvalidBridgeData();
        }
        _completeDelivery(message.data);
    }

    function _completeDelivery(bytes memory messagePayload) internal {
        if (messagePayload.length == 0) revert InvalidCompletionData();
        if (messagePayload.length >= 96) {
            InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
            messagePayloads[data.invoiceId] = messagePayload;
        }
        IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
    }

    //
    // View Functions
    //

    /// @inheritdoc ICcipBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getSelectorForChain(uint64 chainId) external view returns (uint64) {
        return chainIdToSelector[chainId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getChainForSelector(uint64 chainSelector) external view returns (uint64) {
        return selectorToChainId[chainSelector];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getFee(
        uint64 destinationChainSelector,
        bytes memory messageData,
        Client.EVMTokenAmount[] memory tokenAmounts,
        bytes memory extraArgs
    ) external view returns (uint256) {
        bytes memory receiver = abi.encode(address(this));
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver, data: messageData, tokenAmounts: tokenAmounts, feeToken: feeToken, extraArgs: extraArgs
        });
        return router.getFee(destinationChainSelector, message);
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    /// @dev Overrides to include IAny2EVMMessageReceiver interface support
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
