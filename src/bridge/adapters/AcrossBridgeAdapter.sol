// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IAcrossReceiver, ISpokePool} from "./interfaces/IAcrossInterfaces.sol";
import {IAcrossBridgeAdapter} from "./interfaces/IAcrossBridgeAdapter.sol";
import "src/errors.sol";

/// @title AcrossBridgeAdapter
/// @notice Bridge adapter for Across Protocol cross-chain bridge
/// @dev Enables bridging tokens and messages between chains using Across Protocol
/// @author kpk
contract AcrossBridgeAdapter is BridgeAdapter, IAcrossBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice SpokePool contract address
    ISpokePool public spokePool;

    /// @notice Default relayer fee percentage (in 1e18, e.g., 0.01e18 = 1%)
    int64 public defaultRelayerFeePct;

    /// @notice Mapping from deposit ID to invoice ID
    /// @dev Used to correlate Across deposits with invoice IDs
    mapping(uint32 => bytes32) public depositIdToInvoiceId;

    /// @notice Mapping from invoice ID to deposit ID
    /// @dev Used to track which deposit ID was used for each invoice
    mapping(bytes32 => uint32) public invoiceToDepositId;

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

    /// @inheritdoc IAcrossBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address spokePool_,
        int64 defaultRelayerFeePct_,
        string memory version_
    ) external initializer {
        // Initialize parent BridgeAdapter
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = "Across";
        adapterVersion = version_;

        if (spokePool_ == address(0)) revert InvalidSpokePool();
        if (defaultRelayerFeePct_ < 0 || defaultRelayerFeePct_ > 1e18) {
            revert InvalidRelayerFee();
        }
        spokePool = ISpokePool(spokePool_);
        defaultRelayerFeePct = defaultRelayerFeePct_;
    }

    //
    // Configuration
    //

    /// @inheritdoc IAcrossBridgeAdapter
    function setSpokePool(address spokePool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (spokePool_ == address(0)) revert InvalidSpokePool();
        spokePool = ISpokePool(spokePool_);
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function setDefaultRelayerFeePct(int64 relayerFeePct_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (relayerFeePct_ < 0 || relayerFeePct_ > 1e18) {
            revert InvalidRelayerFee();
        }
        defaultRelayerFeePct = relayerFeePct_;
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to Across-specific format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for Across message
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Get asset address from escrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);
        if (asset == address(0)) {
            revert InvalidBridgeData();
        }

        // Get recipient address (this adapter on destination chain)
        address recipient = address(this);

        // Approve SpokePool to spend tokens (if ERC20)
        if (asset != address(0)) {
            IERC20(asset).forceApprove(address(spokePool), data.amount);
        }

        // Call SpokePool.deposit()
        if (asset == address(0)) {
            // Native token (ETH)
            spokePool.deposit{value: data.amount}(
                recipient, // recipient
                asset, // originToken (address(0) for native)
                data.amount, // amount
                uint256(data.destinationChainId), // destinationChainId
                defaultRelayerFeePct, // relayerFeePct
                uint32(block.timestamp), // quoteTimestamp
                messagePayload, // message (contains messagePayload)
                type(uint256).max // maxCount
            );
        } else {
            // ERC20 token
            spokePool.deposit(
                recipient, // recipient
                asset, // originToken
                data.amount, // amount
                uint256(data.destinationChainId), // destinationChainId
                defaultRelayerFeePct, // relayerFeePct
                uint32(block.timestamp), // quoteTimestamp
                messagePayload, // message (contains messagePayload)
                type(uint256).max // maxCount
            );
        }

        // Note: Deposit ID is emitted in FundsDeposited event
        // We'll store the mapping in handleAcrossMessage when the deposit is filled
        // For now, we store the messagePayload for later correlation
        messagePayloads[data.invoiceId] = messagePayload;

        // We can't get the deposit ID immediately, so we'll store it when handleAcrossMessage is called
        // Emit event with placeholder deposit ID (0)
        emit AcrossBridgeInitiated(data.invoiceId, uint256(data.destinationChainId), 0, data.amount);
    }

    /// @inheritdoc BridgeAdapter
    /// @dev Completes bridge on destination chain
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

        // Store message payload if provided
        if (messagePayload.length > 0) {
            messagePayloads[data.invoiceId] = messagePayload;
        }

        // Get deposit ID from protocol data if available
        uint32 depositId = 0;
        uint256 sourceChainId = 0;
        if (protocolData.length >= 36) {
            // Decode depositId (uint32) and sourceChainId (uint256)
            (depositId, sourceChainId) = abi.decode(protocolData, (uint32, uint256));
        }

        emit AcrossBridgeCompleted(data.invoiceId, sourceChainId, depositId);
    }

    //
    // Across Receiver Implementation
    //

    /// @inheritdoc IAcrossReceiver
    /// @dev Receives messages from Across Protocol when deposit is filled
    function handleAcrossMessage(
        address,
        /* tokenSent */
        uint256,
        /* amount */
        bool,
        /* fillCompleted */
        address,
        /* relayer */
        bytes memory message
    )
        external
        override
    {
        // Verify caller is the SpokePool
        if (msg.sender != address(spokePool)) {
            revert InvalidSpokePool();
        }

        // Verify message is not empty
        if (message.length == 0) {
            revert MessageReceiveFailed();
        }

        // Verify message payload is at least 96 bytes (invoiceId + amount + meta)
        if (message.length < 96) {
            revert InvalidCompletionData();
        }

        // Extract messagePayload from message
        bytes memory messagePayload = message;

        // Decode invoice data
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Try to extract deposit ID from event logs or use a mapping
        // Note: We can't directly get depositId from handleAcrossMessage parameters
        // We'll need to track it via events or use a different approach
        // For now, we'll store the messagePayload and let the operator provide depositId in completeBridge

        // Store invoiceId mapping and messagePayload
        messagePayloads[data.invoiceId] = messagePayload;

        // Tokens are automatically transferred by Across relayer before this callback
        // The operator will need to call completeBridge() with the messagePayload
        // We emit an event here to signal that the message was received
        emit AcrossBridgeCompleted(data.invoiceId, 0, 0);
    }

    //
    // View Functions
    //

    /// @inheritdoc IAcrossBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view override returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAcrossReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Receive Function
    //

    /// @notice Allows contract to receive native tokens (for ETH deposits)
    receive() external payable {}
}
