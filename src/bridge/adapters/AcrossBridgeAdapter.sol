// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IAcrossReceiver, ISpokePool} from "./interfaces/IAcrossInterfaces.sol";
import {IAcrossBridgeAdapter} from "./interfaces/IAcrossBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AcrossBridgeAdapter
/// @notice Bridge adapter for Across Protocol cross-chain bridge
/// @dev Recipient is always BridgeEscrow; escrow fallback forwards protocol callbacks (e.g. handleAcrossMessage) to this adapter.
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

    /// @inheritdoc IAcrossBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address spokePool_,
        int64 defaultRelayerFeePct_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super.initialize(admin_, bridgeEscrow_, "Across", version_);

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

        // Check if asset is native token (address(0) or NATIVE_ADDRESS_ERC7528)
        bool isNative = _isNativeToken(asset);

        // Pull ERC20 tokens from escrow if not native (escrow approved us in depositAndBridge)
        if (!isNative) {
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
        }

        // Recipient is BridgeEscrow; escrow fallback forwards handleAcrossMessage to this adapter
        address recipient = bridgeEscrow;

        // Approve SpokePool to spend tokens (if ERC20)
        if (!isNative) {
            IERC20(asset).forceApprove(address(spokePool), data.amount);
        }

        // Call SpokePool.deposit()
        if (isNative) {
            // Native token (ETH) - use address(0) for SpokePool
            spokePool.deposit{value: data.amount}(
                recipient, // recipient
                address(0), // originToken (address(0) for native)
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
    /// @dev Completes bridge on destination chain (manager fallback when callback path not used)
    ///      When recipient is BridgeEscrow, tokens are already at escrow; we only trigger release.
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        if (messagePayload.length == 0) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
        if (messagePayload.length > 0) {
            messagePayloads[data.invoiceId] = messagePayload;
        }
        uint32 depositId = 0;
        uint256 sourceChainId = 0;
        if (protocolData.length >= 36) {
            (depositId, sourceChainId) = abi.decode(protocolData, (uint32, uint256));
        }
        emit AcrossBridgeCompleted(data.invoiceId, sourceChainId, depositId);
    }

    /// @dev IAcrossReceiver: when called by BridgeEscrow (escrow fallback forwards here), completes delivery.
    ///      When called directly on the adapter, reverts so the protocol must call the escrow.
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
        if (msg.sender != bridgeEscrow) revert MessageReceiveFailed();
        _completeDelivery(message);
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
