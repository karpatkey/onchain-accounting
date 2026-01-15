// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title LayerZero and Stargate Interfaces
/// @notice Aggregated interfaces for LayerZero and Stargate Finance integration
/// @author kpk

// ============================================================================
// LayerZero Interfaces
// ============================================================================

/// @title ILayerZeroReceiver Interface
/// @notice Interface for LayerZero message receivers
/// @dev Based on LayerZero's ILayerZeroReceiver interface
interface ILayerZeroReceiver {
    /// @notice Receives LayerZero messages
    /// @param _srcChainId The source chain ID (LayerZero chain ID)
    /// @param _srcAddress The source address (bytes format)
    /// @param _nonce The message nonce
    /// @param _payload The message payload
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload) external;
}

/// @title ILayerZeroEndpoint Interface
/// @notice Interface for LayerZero endpoint contract
/// @dev Based on LayerZero's ILayerZeroEndpoint interface
interface ILayerZeroEndpoint {
    /// @notice Sends a LayerZero message
    /// @param _dstChainId The destination chain ID (LayerZero chain ID)
    /// @param _destination The destination address
    /// @param _payload The message payload
    /// @param _refundAddress The address to refund excess fees
    /// @param _zroPaymentAddress The ZRO payment address (address(0) for native)
    /// @param _adapterParams The adapter parameters
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}

// ============================================================================
// Stargate Interfaces
// ============================================================================

/// @title IStargateRouter Interface
/// @notice Interface for Stargate Router contract
/// @dev Based on Stargate's Router interface
interface IStargateRouter {
    /// @notice Struct for LayerZero fee quote
    struct LzTxObj {
        uint256 dstGasForCall;
        uint256 dstNativeAmount;
        bytes dstNativeAddr;
    }

    /// @notice Struct for swap parameters
    struct SwapParams {
        uint16 dstChainId; // Stargate/LayerZero chain ID
        uint256 srcPoolId; // Source pool ID
        uint256 dstPoolId; // Destination pool ID
        uint256 amountLD; // Amount in local decimals
        uint256 minAmountLD; // Minimum amount to receive (slippage protection)
        LzTxObj lzTxParams; // LayerZero transaction parameters
        bytes to; // Destination address (bytes format)
        bytes payload; // Message payload
    }

    /// @notice Quotes the LayerZero fee for a swap
    /// @param _dstChainId The destination chain ID (LayerZero chain ID)
    /// @param _functionType The function type (1 for swap)
    /// @param _toAddress The destination address (bytes format)
    /// @param _transferAndCallPayload The payload to send
    /// @param _lzTxParams The LayerZero transaction parameters
    /// @return nativeFee The native token fee
    /// @return zroFee The ZRO token fee (if applicable)
    function quoteLayerZeroFee(
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        IStargateRouter.LzTxObj memory _lzTxParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    /// @notice Performs a cross-chain swap
    /// @param _lzChainId The destination chain ID (LayerZero chain ID)
    /// @param _srcPoolId The source pool ID
    /// @param _dstPoolId The destination pool ID
    /// @param _refundAddress The address to refund excess fees
    /// @param _amountLD The amount in local decimals
    /// @param _minAmountLD The minimum amount to receive (slippage protection)
    /// @param _lzTxParams The LayerZero transaction parameters
    /// @param _to The destination address (bytes format)
    /// @param _payload The message payload
    function swap(
        uint16 _lzChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLD,
        uint256 _minAmountLD,
        IStargateRouter.LzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable;
}
