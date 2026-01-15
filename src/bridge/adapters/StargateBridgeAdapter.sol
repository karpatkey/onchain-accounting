// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {ILayerZeroReceiver, ILayerZeroEndpoint, IStargateRouter} from "./interfaces/IStargateInterfaces.sol";
import {IStargateBridgeAdapter} from "./interfaces/IStargateBridgeAdapter.sol";
import "src/errors.sol";

/// @title StargateBridgeAdapter
/// @notice Bridge adapter for Stargate Finance cross-chain protocol
/// @dev Enables bridging tokens and messages between chains using Stargate and LayerZero
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

    /// @inheritdoc IStargateBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address endpoint_,
        string memory version_
    ) external initializer {
        // Initialize parent BridgeAdapter
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = "Stargate";
        adapterVersion = version_;

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
        if (asset == address(0)) {
            revert InvalidBridgeData();
        }

        // Get pool IDs for source and destination chains
        uint256 srcPoolId = assetPoolId[asset][uint64(block.chainid)];
        uint256 dstPoolId = assetPoolId[asset][uint64(data.destinationChainId)];

        if (srcPoolId == 0 || dstPoolId == 0) {
            revert InvalidPoolId();
        }

        // Approve router to spend tokens
        IERC20(asset).forceApprove(address(router), data.amount);

        // Prepare LayerZero transaction parameters
        IStargateRouter.LzTxObj memory lzTxParams = IStargateRouter.LzTxObj({
            dstGasForCall: defaultDstGasForCall, dstNativeAmount: 0, dstNativeAddr: bytes("")
        });

        // Encode destination address (this adapter on destination chain)
        bytes memory toAddress = abi.encodePacked(address(this));

        // Quote LayerZero fee
        (uint256 nativeFee,) = router.quoteLayerZeroFee(
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
            data.amount,
            (data.amount * 95) / 100, // minAmountLD: 5% slippage tolerance
            lzTxParams,
            toAddress,
            messagePayload
        );

        // Note: LayerZero nonce is not available immediately after swap
        // We'll store the mapping in lzReceive when the message arrives
        // For now, we store the messagePayload for later correlation
        messagePayloads[data.invoiceId] = messagePayload;

        emit StargateBridgeInitiated(data.invoiceId, destinationLzChainId, srcPoolId, dstPoolId, data.amount);
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

        // Get source LayerZero chain ID from protocol data if available
        uint16 sourceLzChainId = 0;
        if (protocolData.length >= 2) {
            sourceLzChainId = abi.decode(protocolData, (uint16));
        }

        emit StargateBridgeCompleted(data.invoiceId, sourceLzChainId);
    }

    //
    // LayerZero Receiver Implementation
    //

    /// @inheritdoc ILayerZeroReceiver
    /// @dev Receives LayerZero messages from Stargate
    function lzReceive(
        uint16 _srcChainId,
        bytes calldata,
        /* _srcAddress */
        uint64 _nonce,
        bytes calldata _payload
    )
        external
        override
    {
        // Verify caller is the LayerZero endpoint
        if (msg.sender != endpoint) {
            revert InvalidEndpoint();
        }

        // Verify payload is not empty
        if (_payload.length == 0) {
            revert MessageReceiveFailed();
        }

        // Decode messagePayload from payload
        // The payload should contain the messagePayload (96 bytes: invoiceId + amount + meta)
        if (_payload.length < 96) {
            revert InvalidCompletionData();
        }

        // Extract messagePayload from payload
        bytes memory messagePayload = _payload;

        // Decode invoice data
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

        // Store nonce mapping for correlation
        nonceToInvoiceId[_nonce] = data.invoiceId;
        invoiceToNonce[data.invoiceId] = _nonce;

        // Store message payload
        messagePayloads[data.invoiceId] = messagePayload;

        // Tokens are automatically transferred by Stargate before lzReceive is called
        // The operator will need to call completeBridge() with the messagePayload
        // We emit an event here to signal that the message was received
        emit StargateBridgeCompleted(data.invoiceId, _srcChainId);
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
