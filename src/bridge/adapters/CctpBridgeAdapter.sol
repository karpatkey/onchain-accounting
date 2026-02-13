// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {ITokenMessenger} from "@chainlink/src/v0.8/ccip/pools/USDC/ITokenMessenger.sol";
import {IMessageTransmitter} from "@chainlink/src/v0.8/ccip/pools/USDC/IMessageTransmitter.sol";
import {ICctpBridgeAdapter} from "./interfaces/ICctpBridgeAdapter.sol";
import {InvalidArguments, InvalidInvoice} from "src/errors.sol";

/// @title CctpBridgeAdapter
/// @notice Bridge adapter for Circle's Cross-Chain Transfer Protocol (CCTP)
/// @dev Enables bridging USDC between chains with message payload support
/// @author kpk
contract CctpBridgeAdapter is BridgeAdapter, ICctpBridgeAdapter {
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

    /// @inheritdoc ICctpBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address tokenMessenger_,
        address messageTransmitter_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super.initialize(admin_, bridgeEscrow_, "CCTP", version_);

        // Initialize CCTP-specific contracts
        tokenMessenger = ITokenMessenger(tokenMessenger_);
        messageTransmitter = IMessageTransmitter(messageTransmitter_);
    }

    //
    // Configuration
    //

    /// @inheritdoc ICctpBridgeAdapter
    function setDomainMapping(uint64 chainId, uint32 domain) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainIdToDomain[chainId] = domain;
        domainToChainId[domain] = chainId;
    }

    /// @inheritdoc ICctpBridgeAdapter
    function setTokenMessenger(address tokenMessenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenMessenger = ITokenMessenger(tokenMessenger_);
    }

    /// @inheritdoc ICctpBridgeAdapter
    function setMessageTransmitter(address messageTransmitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        messageTransmitter = IMessageTransmitter(messageTransmitter_);
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to CCTP-specific format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Get asset address from registry
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);

        // Validate asset is not native (CCTP only supports USDC)
        if (_isNativeToken(asset)) {
            revert InvalidArguments();
        }

        // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

        // Convert chain ID to CCTP domain
        uint32 destinationDomain = chainIdToDomain[uint64(data.destinationChainId)];
        if (destinationDomain == 0) {
            revert InvalidDomain();
        }

        // Convert recipient address to bytes32 (CCTP format)
        // Use bridgeEscrow as the recipient - all BridgeEscrows have the same address across chains
        // BridgeEscrow will then release to account via releaseByInvoiceId()
        bytes32 mintRecipient = bytes32(uint256(uint160(bridgeEscrow)));

        // Approve TokenMessenger to spend tokens
        // Use forceApprove if available, otherwise use approve after resetting
        IERC20(asset).forceApprove(address(tokenMessenger), data.amount);

        // Step 1: Burn USDC using TokenMessenger
        // This creates a message automatically that will mint USDC on destination
        // The destinationCaller is set to this contract's address so we can receive the message
        bytes32 destinationCaller = bytes32(uint256(uint160(address(this))));
        uint64 nonce = tokenMessenger.depositForBurnWithCaller(
            data.amount, destinationDomain, mintRecipient, asset, destinationCaller
        );

        // Step 2: Store invoiceId mapping for correlation with CCTP message
        // The invoiceId will be extracted from the CCTP message on the destination chain
        // We store it keyed by the source domain and nonce (CCTP's unique message identifier)
        uint32 sourceDomain = messageTransmitter.localDomain();
        messageToInvoiceId[sourceDomain][nonce] = data.invoiceId;

        emit CctpBridgeInitiated(data.invoiceId, destinationDomain, mintRecipient, bytes32(data.amount), nonce);
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Receives USDC message and mints USDC on destination
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        // Decode protocol data (CCTP message and attestation)
        (bytes memory usdcMessage, bytes memory usdcAttestation) = abi.decode(protocolData, (bytes, bytes));

        if (usdcMessage.length == 0 || usdcAttestation.length == 0) {
            revert InvalidCompletionData();
        }

        // Extract source domain and nonce from CCTP message for invoiceId lookup
        uint32 sourceDomain;
        uint64 nonce;
        if (usdcMessage.length >= 20) {
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
        }

        // Look up invoiceId using source domain and nonce
        bytes32 invoiceId = messageToInvoiceId[sourceDomain][nonce];

        // Extract invoiceId, amount, and meta from messagePayload if available
        if (messagePayload.length > 0) {
            InvoiceDataLib.InvoiceData memory payloadData = InvoiceDataLib.decode(messagePayload);

            // Verify invoiceId from mapping matches payload
            if (invoiceId != bytes32(0) && invoiceId != payloadData.invoiceId) {
                revert InvalidInvoice();
            }

            // Use payload invoiceId if mapping lookup failed
            if (invoiceId == bytes32(0)) {
                invoiceId = payloadData.invoiceId;
            }

            // Validate checksum
            if (!IBridgeEscrow(bridgeEscrow)
                    .validateInvoiceIdChecksum(
                        invoiceId, payloadData.amount, payloadData.timestamp, payloadData.checksum24
                    )) {
                revert InvalidInvoice();
            }
        }

        // Receive USDC message and mint USDC
        bool success = messageTransmitter.receiveMessage(usdcMessage, usdcAttestation);
        if (!success) {
            revert MessageReceiveFailed();
        }

        // Emit CCTP-specific event (sourceInvoiceId is the same as invoiceId)
        emit CctpBridgeCompleted(invoiceId, invoiceId, sourceDomain);
    }

    /// @inheritdoc ICctpBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc ICctpBridgeAdapter
    function getDomainForChain(uint64 chainId) external view returns (uint32) {
        return chainIdToDomain[chainId];
    }

    /// @inheritdoc ICctpBridgeAdapter
    function getChainForDomain(uint32 domain) external view returns (uint64) {
        return domainToChainId[domain];
    }
}
