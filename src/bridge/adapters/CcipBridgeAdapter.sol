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
import "src/errors.sol";

/// @title CcipBridgeAdapter
/// @notice Bridge adapter for Chainlink's Cross-Chain Interoperability Protocol (CCIP)
/// @dev Enables bridging tokens and messages between chains with invoiceId relay support
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

    /// @inheritdoc ICcipBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address feeToken_,
        string memory version_
    ) external initializer {
        // Initialize parent BridgeAdapter
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = "CCIP";
        adapterVersion = version_;

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
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);

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

        // Encode receiver address - bridgeEscrow on destination chain (all BridgeEscrows have the same address)
        // BridgeEscrow will release to portfolioSafe via releaseByInvoiceId() using portfolioSafe from messagePayload
        // Note: CCIP requires receiver to implement ccipReceive callback, so we use adapter address
        // Tokens will be transferred to bridgeEscrow in _completeBridge before calling releaseByInvoiceId
        bytes memory receiver = abi.encode(address(this));

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

        // Validate checksum
        if (!IBridgeEscrow(bridgeEscrow)
                .validateInvoiceIdChecksum(data.invoiceId, data.amount, data.timestampByte, data.checksum24)) {
            revert InvalidInvoice();
        }

        // Store message payload if provided
        if (payloadToUse.length > 0) {
            messagePayloads[data.invoiceId] = payloadToUse;
        }

        // Transfer tokens from adapter to BridgeEscrow if they arrived at adapter
        // CCIP sends tokens to receiver (adapter) before calling ccipReceive
        // Get asset address from escrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);
        bool isNative = _isNativeToken(asset);

        if (!isNative) {
            // Transfer ERC20 tokens to BridgeEscrow if adapter has balance
            // CCIP transfers tokens before ccipReceive, so they should be at adapter
            // Note: We check adapter balance directly, not message.destTokenAmounts,
            // because the message may not include token amounts in all cases
            uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
            if (adapterBalance >= data.amount) {
                IERC20(asset).safeTransfer(bridgeEscrow, data.amount);
            }
        }

        emit CcipBridgeCompleted(data.invoiceId, message.messageId, message.sourceChainSelector);
    }

    //
    // CCIP Receiver Implementation
    //

    /// @inheritdoc ICcipBridgeAdapter
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        // Verify caller is the router
        if (msg.sender != address(router)) {
            revert InvalidRouter();
        }

        // Extract invoiceId, amount, and meta from message data (exactly 96 bytes = 3 slots)
        if (message.data.length >= 96) {
            (bytes32 invoiceId, uint256 amount, bytes32 meta) = abi.decode(message.data, (bytes32, uint256, bytes32));

            // Store invoiceId mapping for correlation
            messageIdToInvoiceId[message.messageId] = invoiceId;

            // Store message payload
            messagePayloads[invoiceId] = message.data;
        }

        // Note: Tokens are automatically transferred by CCIP router before this callback.
        // The operator still needs to call completeBridge to release funds from BridgeEscrow.
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
