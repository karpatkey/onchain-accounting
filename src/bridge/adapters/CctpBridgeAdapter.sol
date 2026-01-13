// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {BridgeData} from "../BridgeData.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {ITokenMessenger} from "@chainlink/src/v0.8/ccip/pools/USDC/ITokenMessenger.sol";
import {IMessageTransmitter} from "@chainlink/src/v0.8/ccip/pools/USDC/IMessageTransmitter.sol";
import "src/errors.sol";

/// @title CctpBridgeAdapter
/// @notice Bridge adapter for Circle's Cross-Chain Transfer Protocol (CCTP)
/// @dev Enables bridging USDC between chains with message payload support
/// @author kpk
contract CctpBridgeAdapter is BridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice TokenMessenger contract address (source chain)
    ITokenMessenger public tokenMessenger;

    /// @notice MessageTransmitter contract address (source chain for sending, destination for receiving)
    IMessageTransmitter public messageTransmitter;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Mapping from CCTP message identifier to invoice ID
    /// @dev Used to correlate CCTP messages with invoice IDs
    ///      Format: messageToInvoiceId[sourceDomain][messageIdentifier] = invoiceId
    ///      For CCTP, the messageIdentifier is the nonce (unique per message)
    mapping(uint32 => mapping(uint64 => bytes32)) public messageToInvoiceId;

    /// @notice Mapping from chain ID to CCTP domain ID
    mapping(uint64 => uint32) public chainIdToDomain;

    /// @notice Mapping from domain ID to chain ID
    mapping(uint32 => uint64) public domainToChainId;

    //
    // Events
    //

    /// @notice Event emitted when a CCTP bridge is initiated
    /// @param invoiceId The invoice ID
    /// @param destinationDomain The CCTP domain ID of destination chain
    /// @param mintRecipient The recipient address on destination chain
    /// @param amount The amount being bridged
    /// @param nonce The CCTP message nonce
    /// @param messagePayload The message payload being sent
    event CctpBridgeInitiated(
        bytes32 indexed invoiceId,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 amount,
        uint64 nonce,
        bytes messagePayload
    );

    /// @notice Event emitted when a CCTP bridge is completed
    /// @param invoiceId The invoice ID
    /// @param sourceInvoiceId The source invoice ID
    /// @param sourceDomain The CCTP domain ID of source chain
    /// @param messagePayload The message payload that was delivered
    event CctpBridgeCompleted(
        bytes32 indexed invoiceId,
        bytes32 indexed sourceInvoiceId,
        uint32 sourceDomain,
        bytes messagePayload
    );

    //
    // Errors
    //

    error InvalidDomain();
    error InvalidMessage();
    error MessageReceiveFailed();
    error InvalidBridgeData();
    error InvalidCompletionData();

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

    /// @notice Initializes the CCTP Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param tokenMessenger_ The TokenMessenger contract address
    /// @param messageTransmitter_ The MessageTransmitter contract address
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address tokenMessenger_,
        address messageTransmitter_,
        string memory version_
    ) external initializer {
        // Initialize parent BridgeAdapter
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = "CCTP";
        adapterVersion = version_;
        
        // Initialize CCTP-specific contracts
        tokenMessenger = ITokenMessenger(tokenMessenger_);
        messageTransmitter = IMessageTransmitter(messageTransmitter_);
    }

    //
    // Configuration
    //

    /// @notice Sets the CCTP domain mapping for a chain ID
    /// @param chainId The chain ID
    /// @param domain The CCTP domain ID
    function setDomainMapping(uint64 chainId, uint32 domain) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainIdToDomain[chainId] = domain;
        domainToChainId[domain] = chainId;
    }

    /// @notice Sets the TokenMessenger contract address
    /// @param tokenMessenger_ The TokenMessenger contract address
    function setTokenMessenger(address tokenMessenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenMessenger = ITokenMessenger(tokenMessenger_);
    }

    /// @notice Sets the MessageTransmitter contract address
    /// @param messageTransmitter_ The MessageTransmitter contract address
    function setMessageTransmitter(address messageTransmitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        messageTransmitter = IMessageTransmitter(messageTransmitter_);
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives standardized bridge parameters and converts them to CCTP-specific format
    function _bridge(bytes32 invoiceId, BridgeData.BridgeParams memory params) internal override {
        // Convert chain ID to CCTP domain
        uint32 destinationDomain = chainIdToDomain[params.destinationChainId];
        if (destinationDomain == 0) {
            revert InvalidDomain();
        }

        // Convert recipient address to bytes32 (CCTP format)
        bytes32 mintRecipient = bytes32(uint256(uint160(params.recipient)));

        // Validate asset is not native (CCTP only supports USDC)
        if (params.asset == address(0)) {
            revert InvalidArguments();
        }

        // Approve TokenMessenger to spend tokens
        // Use forceApprove if available, otherwise use approve after resetting
        IERC20(params.asset).forceApprove(address(tokenMessenger), params.amount);

        // Step 1: Burn USDC using TokenMessenger
        // This creates a message automatically that will mint USDC on destination
        // The destinationCaller is set to this contract's address so we can receive the message
        bytes32 destinationCaller = bytes32(uint256(uint160(address(this))));
        uint64 nonce = tokenMessenger.depositForBurnWithCaller(
            params.amount, destinationDomain, mintRecipient, params.asset, destinationCaller
        );

        // Step 2: Store invoiceId mapping for correlation with CCTP message
        // The invoiceId will be extracted from the CCTP message on the destination chain
        // We store it keyed by the source domain and nonce (CCTP's unique message identifier)
        uint32 sourceDomain = messageTransmitter.localDomain();
        messageToInvoiceId[sourceDomain][nonce] = invoiceId;

        emit CctpBridgeInitiated(invoiceId, destinationDomain, mintRecipient, params.amount, nonce, params.messagePayload);
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Extracts invoiceId from CCTP message using source domain and nonce
    function _extractInvoiceIdFromBridgeData(bytes memory protocolData)
        internal
        view
        override
        returns (bytes32 extractedInvoiceId)
    {
        // Decode protocol data to get CCTP message
        (bytes memory usdcMessage, bytes memory usdcAttestation) = abi.decode(protocolData, (bytes, bytes));
        // usdcAttestation is not used here, but required for decoding
        usdcAttestation;

        if (usdcMessage.length < 116) {
            // Invalid message format, return 0 to use parameter
            return bytes32(0);
        }

        // Extract source domain and nonce from CCTP message
        // CCTP message format: version (4) + sourceDomain (4) + destinationDomain (4) + 
        // nonce (8) + sender (32) + recipient (32) + destinationCaller (32) + messageBody (variable)
        uint32 sourceDomain;
        uint64 nonce;
        assembly {
            // Extract sourceDomain from bytes 4-8 (offset 4, length 4)
            let ptr := add(usdcMessage, 4)
            sourceDomain := mload(ptr)
            sourceDomain := shr(224, sourceDomain) // Right shift to get first 4 bytes (uint32)
            
            // Extract nonce from bytes 12-20 (offset 12, length 8)
            ptr := add(usdcMessage, 12)
            nonce := mload(ptr)
            nonce := shr(192, nonce) // Right shift to get first 8 bytes (uint64)
        }

        // Look up invoiceId using source domain and nonce
        // The nonce is CCTP's unique message identifier, which we use to correlate
        // the message with the invoiceId stored on the source chain
        extractedInvoiceId = messageToInvoiceId[sourceDomain][nonce];
        
        // If not found, return 0 to use the parameter as fallback
        return extractedInvoiceId;
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Receives USDC message and mints USDC on destination
    function _completeBridge(bytes32 invoiceId, BridgeData.CompletionParams memory params) internal override {
        // Decode protocol data (CCTP message and attestation)
        (bytes memory usdcMessage, bytes memory usdcAttestation) =
            abi.decode(params.protocolData, (bytes, bytes));

        if (usdcMessage.length == 0 || usdcAttestation.length == 0) {
            revert InvalidCompletionData();
        }

        // Receive USDC message and mint USDC
        bool success = messageTransmitter.receiveMessage(usdcMessage, usdcAttestation);
        if (!success) {
            revert MessageReceiveFailed();
        }

        // Extract source domain for event emission
        uint32 sourceDomain;
        if (usdcMessage.length >= 8) {
            assembly {
                let ptr := add(usdcMessage, 4)
                sourceDomain := mload(ptr)
                sourceDomain := shr(224, sourceDomain)
            }
        }

        // Emit CCTP-specific event (sourceInvoiceId is the same as invoiceId)
        emit CctpBridgeCompleted(invoiceId, invoiceId, sourceDomain, "");
    }


    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    //
    // View Functions
    //

    /// @notice Gets the CCTP domain for a given chain ID
    /// @param chainId The chain ID
    /// @return The CCTP domain ID, or 0 if not set
    function getDomainForChain(uint64 chainId) external view returns (uint32) {
        return chainIdToDomain[chainId];
    }

    /// @notice Gets the chain ID for a given CCTP domain
    /// @param domain The CCTP domain ID
    /// @return The chain ID, or 0 if not set
    function getChainForDomain(uint32 domain) external view returns (uint64) {
        return domainToChainId[domain];
    }
}
