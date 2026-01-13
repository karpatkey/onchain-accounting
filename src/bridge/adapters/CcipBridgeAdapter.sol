// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {BridgeData} from "../BridgeData.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "src/errors.sol";

/// @title CcipBridgeAdapter
/// @notice Bridge adapter for Chainlink's Cross-Chain Interoperability Protocol (CCIP)
/// @dev Enables bridging tokens and messages between chains with invoiceId relay support
/// @author kpk
contract CcipBridgeAdapter is BridgeAdapter, IAny2EVMMessageReceiver {
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
    // Events
    //

    /// @notice Event emitted when a CCIP bridge is initiated
    /// @param invoiceId The invoice ID
    /// @param destinationChainSelector The CCIP chain selector of destination chain
    /// @param messageId The CCIP message ID
    /// @param amount The amount being bridged
    /// @param messagePayload The message payload being sent
    event CcipBridgeInitiated(
        bytes32 indexed invoiceId,
        uint64 destinationChainSelector,
        bytes32 messageId,
        uint256 amount,
        bytes messagePayload
    );

    /// @notice Event emitted when a CCIP bridge is completed
    /// @param invoiceId The invoice ID
    /// @param messageId The CCIP message ID
    /// @param sourceChainSelector The CCIP chain selector of source chain
    /// @param messagePayload The message payload that was delivered
    event CcipBridgeCompleted(
        bytes32 indexed invoiceId,
        bytes32 indexed messageId,
        uint64 sourceChainSelector,
        bytes messagePayload
    );

    //
    // Errors
    //

    error InvalidChainSelector();
    error InvalidRouter();
    error MessageReceiveFailed();
    error InvalidBridgeData();
    error InvalidCompletionData();
    error UnsupportedChain(uint64 chainSelector);

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

    /// @notice Initializes the CCIP Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param router_ The CCIP Router contract address
    /// @param feeToken_ The fee token address (address(0) for native, or LINK token)
    /// @param version_ The adapter version
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

    /// @notice Sets the CCIP chain selector mapping for a chain ID
    /// @param chainId The chain ID
    /// @param chainSelector The CCIP chain selector
    function setChainSelectorMapping(uint64 chainId, uint64 chainSelector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainIdToSelector[chainId] = chainSelector;
        selectorToChainId[chainSelector] = chainId;
    }

    /// @notice Sets the CCIP Router contract address
    /// @param router_ The Router contract address
    function setRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router_ == address(0)) revert InvalidRouter();
        router = IRouterClient(router_);
    }

    /// @notice Sets the fee token address
    /// @param feeToken_ The fee token address (address(0) for native)
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

    /// @notice Sets CCIP extraArgs for a chain selector
    /// @param chainSelector The CCIP chain selector
    /// @param extraArgs The extra args (e.g., gas limit, encoded using Client._argsToBytes())
    function setChainExtraArgs(uint64 chainSelector, bytes calldata extraArgs)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        chainExtraArgs[chainSelector] = extraArgs;
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives standardized bridge parameters and converts them to CCIP-specific format
    function _bridge(bytes32 invoiceId, BridgeData.BridgeParams memory params) internal override {
        // Convert chain ID to CCIP chain selector
        uint64 destinationChainSelector = chainIdToSelector[params.destinationChainId];
        if (destinationChainSelector == 0) {
            revert InvalidChainSelector();
        }

        // Validate chain is supported by CCIP router
        if (!router.isChainSupported(destinationChainSelector)) {
            revert UnsupportedChain(destinationChainSelector);
        }

        // Encode invoiceId and messagePayload in message data
        bytes memory messageData = abi.encode(invoiceId, params.messagePayload);

        // Prepare token amounts array
        Client.EVMTokenAmount[] memory tokenAmounts;
        if (params.asset != address(0) && params.amount > 0) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: params.asset, amount: params.amount});

            // Approve router to spend tokens
            IERC20(params.asset).forceApprove(address(router), params.amount);
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        // Encode receiver address (use recipient from params, or this contract as fallback)
        address receiverAddress = params.recipient != address(0) ? params.recipient : address(this);
        bytes memory receiver = abi.encode(receiverAddress);

        // Get extraArgs for this chain (use configured or empty for default)
        bytes memory extraArgsToUse = chainExtraArgs[destinationChainSelector];
        if (extraArgsToUse.length == 0) {
            extraArgsToUse = bytes("");
        }

        // Build CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: messageData,
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
        messageIdToInvoiceId[messageId] = invoiceId;
        invoiceToMessageId[invoiceId] = messageId;

        emit CcipBridgeInitiated(invoiceId, destinationChainSelector, messageId, params.amount, params.messagePayload);
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Extracts invoiceId from CCIP message data
    function _extractInvoiceIdFromBridgeData(bytes memory protocolData)
        internal
        view
        override
        returns (bytes32 extractedInvoiceId)
    {
        // protocolData for CCIP completion is the Any2EVMMessage
        Client.Any2EVMMessage memory message = abi.decode(protocolData, (Client.Any2EVMMessage));

        // First try to look up invoiceId using messageId (if stored from source chain)
        extractedInvoiceId = messageIdToInvoiceId[message.messageId];

        // If not found in mapping, extract from message data
        // The invoiceId is encoded in the message.data as: abi.encode(invoiceId, messagePayload)
        if (extractedInvoiceId == bytes32(0) && message.data.length >= 32) {
            // Decode invoiceId from message data
            (bytes32 decodedInvoiceId,) = abi.decode(message.data, (bytes32, bytes));
            extractedInvoiceId = decodedInvoiceId;
        }

        // If still not found, return 0 to use parameter as fallback
        return extractedInvoiceId;
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Receives CCIP message and processes it
    function _completeBridge(bytes32 invoiceId, BridgeData.CompletionParams memory params) internal override {
        // Decode protocol data (Any2EVMMessage)
        Client.Any2EVMMessage memory message = abi.decode(params.protocolData, (Client.Any2EVMMessage));

        if (message.data.length == 0) {
            revert InvalidCompletionData();
        }

        // Use messagePayload from params if available, otherwise decode from message data
        bytes memory messagePayload;
        if (params.messagePayload.length > 0) {
            messagePayload = params.messagePayload;
        } else {
            // Decode invoiceId and messagePayload from message data
            (bytes32 decodedInvoiceId, bytes memory decodedPayload) = abi.decode(message.data, (bytes32, bytes));
            // Verify invoiceId matches
            if (decodedInvoiceId != invoiceId) {
                revert InvalidCompletionData();
            }
            messagePayload = decodedPayload;
        }

        // Store message payload if provided
        if (messagePayload.length > 0) {
            messagePayloads[invoiceId] = messagePayload;
        }

        // Tokens are automatically transferred by CCIP router before ccipReceive is called
        // So we just need to emit the event

        emit CcipBridgeCompleted(invoiceId, message.messageId, message.sourceChainSelector, messagePayload);
    }

    //
    // CCIP Receiver Implementation
    //

    /// @notice Receives CCIP messages from the router
    /// @param message The CCIP message
    /// @dev This is called automatically by the CCIP router when a message arrives.
    ///      Tokens are automatically transferred before this callback.
    ///      We store the invoiceId mapping here, but the actual release is handled
    ///      by the operator calling completeBridge with the message data.
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        // Verify caller is the router
        if (msg.sender != address(router)) {
            revert InvalidRouter();
        }

        // Decode invoiceId from message data
        if (message.data.length >= 32) {
            (bytes32 invoiceId, bytes memory messagePayload) = abi.decode(message.data, (bytes32, bytes));

            // Store invoiceId mapping for extraction in completeBridge
            messageIdToInvoiceId[message.messageId] = invoiceId;

            // Store message payload if provided
            if (messagePayload.length > 0) {
                messagePayloads[invoiceId] = messagePayload;
            }
        }

        // Note: Tokens are automatically transferred by CCIP router before this callback.
        // The operator still needs to call completeBridge to release funds from BridgeEscrow.
    }

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @notice Gets the CCIP chain selector for a given chain ID
    /// @param chainId The chain ID
    /// @return The CCIP chain selector, or 0 if not set
    function getSelectorForChain(uint64 chainId) external view returns (uint64) {
        return chainIdToSelector[chainId];
    }

    /// @notice Gets the chain ID for a given CCIP chain selector
    /// @param chainSelector The CCIP chain selector
    /// @return The chain ID, or 0 if not set
    function getChainForSelector(uint64 chainSelector) external view returns (uint64) {
        return selectorToChainId[chainSelector];
    }

    /// @notice Gets the CCIP fee for a message
    /// @param destinationChainSelector The destination chain selector
    /// @param messageData The message data
    /// @param tokenAmounts The token amounts to send
    /// @param extraArgs The extra args for the message
    /// @return The fee amount
    function getFee(
        uint64 destinationChainSelector,
        bytes memory messageData,
        Client.EVMTokenAmount[] memory tokenAmounts,
        bytes memory extraArgs
    ) external view returns (uint256) {
        bytes memory receiver = abi.encode(address(this));
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: messageData,
            tokenAmounts: tokenAmounts,
            feeToken: feeToken,
            extraArgs: extraArgs
        });
        return router.getFee(destinationChainSelector, message);
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    /// @dev Required for CCIP to recognize this contract as a message receiver
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}
