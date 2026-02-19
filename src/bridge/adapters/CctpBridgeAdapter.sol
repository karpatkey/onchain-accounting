// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {ICircleTokenMessengerV2} from "./interfaces/ICircleTokenMessengerV2.sol";
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

    /// @notice TokenMessengerV2 contract address (source chain)
    ICircleTokenMessengerV2 private _tokenMessenger;

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
    function tokenMessenger() public view returns (ICircleTokenMessengerV2) {
        return _tokenMessenger;
    }

    /// @dev Internal helper to set both chainId -> domain and domain -> chainId mappings
    function _setChainDomain(uint64 chainId, uint32 domain) internal {
        chainIdToDomain[chainId] = domain;
        domainToChainId[domain] = chainId;
    }

    /// @inheritdoc ICctpBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address tokenMessenger_,
        address messageTransmitter_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "CCTP", version_);

        // Initialize CCTP-specific contracts
        _tokenMessenger = ICircleTokenMessengerV2(tokenMessenger_);
        messageTransmitter = IMessageTransmitter(messageTransmitter_);

        // Pre-configure known CCTP domains for supported EVM chains (mainnets)
        // Reference: Circle CCTP MessageTransmitterV2 domains
        _setChainDomain(1, 0); // Ethereum
        _setChainDomain(43114, 1); // Avalanche
        _setChainDomain(10, 2); // OP Mainnet
        _setChainDomain(42161, 3); // Arbitrum
        _setChainDomain(8453, 6); // Base
        _setChainDomain(137, 7); // Polygon PoS
        _setChainDomain(130, 10); // Unichain
        _setChainDomain(59144, 11); // Linea
        _setChainDomain(81224, 12); // Codex
        _setChainDomain(146, 13); // Sonic
        _setChainDomain(480, 14); // World Chain
        _setChainDomain(143, 15); // Monad
        _setChainDomain(1329, 16); // Sei
        _setChainDomain(50, 18); // XDC
        _setChainDomain(999, 19); // HyperEVM
        _setChainDomain(57073, 21); // Ink
        _setChainDomain(98866, 22); // Plume
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
        _tokenMessenger = ICircleTokenMessengerV2(tokenMessenger_);
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
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

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
        IERC20(asset).forceApprove(address(tokenMessenger()), data.amount);

        // Step 1: Burn USDC using TokenMessengerV2
        // This creates a message automatically that will mint USDC on destination
        // The destinationCaller is set to this contract's address so we can receive the message
        bytes32 destinationCaller = bytes32(uint256(uint160(address(this))));
        // Use zero maxFee (no fee charged) and standard finality threshold (2000) as per Circle docs
        tokenMessenger().depositForBurn(
            data.amount,
            destinationDomain,
            mintRecipient,
            asset,
            destinationCaller,
            0,      // maxFee: 0 units of USDC
            2000    // minFinalityThreshold: standard (fully finalized) transfers
        );

        // TokenMessengerV2 does not return the message nonce; it is only available in events.
        // We do not set messageToInvoiceId here; _completeBridge uses messagePayload.invoiceId when
        // the mapping is zero (see _completeBridge).
        uint64 nonce = 0;

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
