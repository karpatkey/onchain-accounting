// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {ILayerZeroReceiver, IStargateRouter} from "./interfaces/IStargateInterfaces.sol";
import {IStargateBridgeAdapter} from "./interfaces/IStargateBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StargateBridgeAdapter
/// @notice Bridge adapter for Stargate Finance cross-chain protocol
/// @dev Recipient is always BridgeEscrow; escrow fallback forwards protocol callbacks (e.g. lzReceive) to this adapter.
/// @author kpk
contract StargateBridgeAdapter is BridgeAdapter, IStargateBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice Stargate Router contract address
    IStargateRouter public router;

    /// @notice LayerZero Endpoint contract address
    address public endpoint;

    /// @notice Mapping from LayerZero nonce to invoice ID
    /// @dev Used to correlate LayerZero messages with invoice IDs
    mapping(uint64 => bytes32) public nonceToInvoiceId;

    /// @notice Mapping from invoice ID to LayerZero nonce
    /// @dev Used to track which nonce was used for each invoice
    mapping(bytes32 => uint64) public invoiceToNonce;

    /// @notice Mapping from standard chain ID to LayerZero chain ID
    mapping(uint64 => uint16) public chainIdToLzChainId;

    /// @notice Mapping from LayerZero chain ID to standard chain ID
    mapping(uint16 => uint64) public lzChainIdToChainId;

    /// @notice Mapping from asset address and chain ID to pool ID
    /// @dev Used to get the correct pool ID for each asset on each chain
    mapping(address => mapping(uint64 => uint256)) public assetPoolId;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @notice Default destination gas for LayerZero calls
    uint256 public defaultDstGasForCall = 200000;

    /// @inheritdoc IStargateBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address endpoint_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super.initialize(admin_, bridgeEscrow_, "Stargate", version_);

        if (router_ == address(0)) revert InvalidRouter();
        if (endpoint_ == address(0)) revert InvalidEndpoint();
        router = IStargateRouter(router_);
        endpoint = endpoint_;
    }

    //
    // Configuration
    //

    /// @inheritdoc IStargateBridgeAdapter
    function setChainIdMapping(uint64 chainId, uint16 lzChainId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainIdToLzChainId[chainId] = lzChainId;
        lzChainIdToChainId[lzChainId] = chainId;
    }

    /// @inheritdoc IStargateBridgeAdapter
    function setRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router_ == address(0)) revert InvalidRouter();
        router = IStargateRouter(router_);
    }

    /// @inheritdoc IStargateBridgeAdapter
    function setEndpoint(address endpoint_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (endpoint_ == address(0)) revert InvalidEndpoint();
        endpoint = endpoint_;
    }

    /// @inheritdoc IStargateBridgeAdapter
    function setAssetPoolId(address asset, uint64 chainId, uint256 poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (poolId == 0) revert InvalidPoolId();
        assetPoolId[asset][chainId] = poolId;
    }

    /// @notice Sets the default destination gas for LayerZero calls
    /// @param dstGasForCall The destination gas amount
    /// @dev Only callable by admin role
    function setDefaultDstGasForCall(uint256 dstGasForCall) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultDstGasForCall = dstGasForCall;
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to Stargate-specific format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for LayerZero payload
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Convert chain ID to LayerZero chain ID
        uint16 destinationLzChainId = chainIdToLzChainId[uint64(data.destinationChainId)];
        if (destinationLzChainId == 0) {
            revert UnsupportedChain(uint16(data.destinationChainId));
        }

        // Get asset address from escrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(data.assetSymbol);

        // Stargate doesn't support native tokens directly - they must be wrapped first
        if (_isNativeToken(asset)) {
            revert InvalidBridgeData();
        }

        // Pull ERC20 tokens from escrow (escrow approved us in depositAndBridge)
        IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);

        // Prepare and execute the Stargate swap
        _executeStargateSwap(
            data.invoiceId, destinationLzChainId, asset, data.destinationChainId, data.amount, messagePayload
        );
    }

    /// @notice Executes the Stargate swap with LayerZero
    /// @param invoiceId The invoice ID
    /// @param destinationLzChainId LayerZero destination chain ID
    /// @param asset The asset address
    /// @param destinationChainId Standard destination chain ID
    /// @param amount The amount to bridge
    /// @param messagePayload Encoded invoice data
    function _executeStargateSwap(
        bytes32 invoiceId,
        uint16 destinationLzChainId,
        address asset,
        uint24 destinationChainId,
        uint256 amount,
        bytes memory messagePayload
    ) internal {
        // Get pool IDs for source and destination chains
        uint256 srcPoolId = assetPoolId[asset][uint64(block.chainid)];
        uint256 dstPoolId = assetPoolId[asset][uint64(destinationChainId)];

        if (srcPoolId == 0 || dstPoolId == 0) {
            revert InvalidPoolId();
        }

        // Approve router to spend tokens
        IERC20(asset).forceApprove(address(router), amount);

        // Calculate minimum amount with 5% slippage tolerance
        uint256 minAmountLd = (amount * 95) / 100;

        // Get LayerZero fee and execute swap
        _quoteAndSwap(destinationLzChainId, srcPoolId, dstPoolId, amount, minAmountLd, messagePayload);

        // Store the messagePayload for later correlation
        messagePayloads[invoiceId] = messagePayload;

        emit StargateBridgeInitiated(invoiceId, destinationLzChainId, srcPoolId, dstPoolId, amount);
    }

    /// @notice Quotes fee and executes the Stargate swap
    /// @param destinationLzChainId LayerZero destination chain ID
    /// @param srcPoolId Source pool ID
    /// @param dstPoolId Destination pool ID
    /// @param amount Amount to swap
    /// @param minAmountLd Minimum amount with slippage
    /// @param messagePayload Encoded invoice data
    /// @return nativeFee The native fee paid
    function _quoteAndSwap(
        uint16 destinationLzChainId,
        uint256 srcPoolId,
        uint256 dstPoolId,
        uint256 amount,
        uint256 minAmountLd,
        bytes memory messagePayload
    ) internal returns (uint256 nativeFee) {
        // Prepare LayerZero transaction parameters
        IStargateRouter.LzTxObj memory lzTxParams = IStargateRouter.LzTxObj({
            dstGasForCall: defaultDstGasForCall, dstNativeAmount: 0, dstNativeAddr: bytes("")
        });

        // Recipient is BridgeEscrow; escrow fallback forwards lzReceive to this adapter
        bytes memory toAddress = abi.encodePacked(bridgeEscrow);

        // Quote LayerZero fee
        (nativeFee,) = router.quoteLayerZeroFee(
            destinationLzChainId,
            1, // functionType: 1 = swap
            toAddress,
            messagePayload,
            lzTxParams
        );

        // Perform swap
        router.swap{value: nativeFee}(
            destinationLzChainId,
            srcPoolId,
            dstPoolId,
            payable(address(this)), // refundAddress
            amount,
            minAmountLd,
            lzTxParams,
            toAddress,
            messagePayload
        );
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

        // Note: Checksum validation is done in BridgeEscrow.releaseByInvoiceId()
        // No need to validate here to avoid redundant gas costs

        // Store message payload if provided
        if (messagePayload.length > 0) {
            messagePayloads[data.invoiceId] = messagePayload;
        }

        // When recipient is BridgeEscrow, tokens are already at escrow; no transfer needed
        uint16 sourceLzChainId = 0;
        if (protocolData.length >= 2) {
            sourceLzChainId = abi.decode(protocolData, (uint16));
        }
        emit StargateBridgeCompleted(data.invoiceId, sourceLzChainId);
    }

    /// @inheritdoc ILayerZeroReceiver
    /// @dev When called by BridgeEscrow (escrow fallback forwards here), completes delivery.
    ///      When called directly on the adapter, reverts.
    function lzReceive(uint16, bytes calldata, uint64, bytes calldata _payload) external override {
        if (msg.sender != bridgeEscrow) {
            if (msg.sender != endpoint) revert InvalidEndpoint();
            revert MessageReceiveFailed();
        }
        _completeDelivery(_payload);
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

    /// @inheritdoc IStargateBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view override returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc IStargateBridgeAdapter
    function getLzChainIdForChain(uint64 chainId) external view override returns (uint16) {
        return chainIdToLzChainId[chainId];
    }

    /// @inheritdoc IStargateBridgeAdapter
    function getChainForLzChainId(uint16 lzChainId) external view override returns (uint64) {
        return lzChainIdToChainId[lzChainId];
    }

    /// @inheritdoc IStargateBridgeAdapter
    function quoteLayerZeroFee(
        uint16 destinationChainId,
        uint256,
        /* srcPoolId */
        uint256,
        /* dstPoolId */
        uint256,
        /* amountLD */
        bytes calldata payload,
        uint256 dstGasForCall
    ) external view override returns (uint256 nativeFee, uint256 zroFee) {
        IStargateRouter.LzTxObj memory lzTxParams = IStargateRouter.LzTxObj({
            dstGasForCall: dstGasForCall, dstNativeAmount: 0, dstNativeAddr: bytes("")
        });

        bytes memory toAddress = abi.encodePacked(address(this));

        return router.quoteLayerZeroFee(destinationChainId, 1, toAddress, payload, lzTxParams);
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ILayerZeroReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Receive Function
    //

    /// @notice Allows contract to receive native tokens (for LayerZero fees)
    receive() external payable {}
}
