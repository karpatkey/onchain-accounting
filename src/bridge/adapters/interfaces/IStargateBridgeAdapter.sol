// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {ILayerZeroReceiver, IStargateRouter} from "./IStargateInterfaces.sol";

/// @title IStargateBridgeAdapter Interface
/// @notice Interface for Stargate Bridge Adapter
/// @dev Documents all events, errors, and public functions for the Stargate adapter
/// @author kpk
interface IStargateBridgeAdapter is IBridgeAdapter, ILayerZeroReceiver {
    //
    // Events
    //

    /// @notice Event emitted when a Stargate bridge is initiated
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param destinationChainId The LayerZero chain ID of destination chain
    /// @param srcPoolId The source pool ID
    /// @param dstPoolId The destination pool ID
    /// @param amount The amount being bridged
    event StargateBridgeInitiated(
        bytes32 indexed invoiceId, uint16 destinationChainId, uint256 srcPoolId, uint256 dstPoolId, uint256 amount
    );

    /// @notice Event emitted when a Stargate bridge is completed
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param sourceChainId The LayerZero chain ID of source chain
    event StargateBridgeCompleted(bytes32 indexed invoiceId, uint16 sourceChainId);

    //
    // Errors
    //

    /// @notice Thrown when an invalid Stargate router address is provided
    error InvalidRouter();

    /// @notice Thrown when an invalid LayerZero endpoint address is provided
    error InvalidEndpoint();

    /// @notice Thrown when an invalid pool ID is provided
    error InvalidPoolId();

    /// @notice Thrown when attempting to bridge to an unsupported chain
    /// @param chainId The unsupported chain ID
    error UnsupportedChain(uint16 chainId);

    /// @notice Thrown when LayerZero message reception fails
    error MessageReceiveFailed();

    /// @notice Thrown when bridge data is invalid
    error InvalidBridgeData();

    //
    // State Variables (Public)
    //

    /// @notice Stargate Router contract address
    /// @return The Router contract instance
    function router() external view returns (IStargateRouter);

    /// @notice LayerZero Endpoint contract address
    /// @return The Endpoint contract instance
    function endpoint() external view returns (address);

    /// @notice Gets the invoice ID for a given LayerZero nonce
    /// @param nonce The LayerZero message nonce
    /// @return The invoice ID, or bytes32(0) if not found
    function nonceToInvoiceId(uint64 nonce) external view returns (bytes32);

    /// @notice Gets the LayerZero nonce for a given invoice ID
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The nonce, or 0 if not found
    function invoiceToNonce(bytes32 invoiceId) external view returns (uint64);

    /// @notice Gets the LayerZero chain ID for a given chain ID
    /// @param chainId The standard chain ID
    /// @return The LayerZero chain ID, or 0 if not set
    function chainIdToLzChainId(uint64 chainId) external view returns (uint16);

    /// @notice Gets the standard chain ID for a given LayerZero chain ID
    /// @param lzChainId The LayerZero chain ID
    /// @return The standard chain ID, or 0 if not set
    function lzChainIdToChainId(uint16 lzChainId) external view returns (uint64);

    /// @notice Gets the pool ID for a given asset and chain
    /// @param asset The asset address
    /// @param chainId The chain ID
    /// @return The pool ID, or 0 if not set
    function assetPoolId(address asset, uint64 chainId) external view returns (uint256);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    //
    // Configuration Functions
    //

    /// @notice Initializes the Stargate Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param router_ The Stargate Router contract address
    /// @param endpoint_ The LayerZero Endpoint contract address
    /// @param version_ The adapter version
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address endpoint_,
        string memory version_
    ) external;

    /// @notice Sets the LayerZero chain ID mapping for a chain ID
    /// @param chainId The standard chain ID
    /// @param lzChainId The LayerZero chain ID
    /// @dev Only callable by admin role
    function setChainIdMapping(uint64 chainId, uint16 lzChainId) external;

    /// @notice Sets the Stargate Router contract address
    /// @param router_ The Router contract address
    /// @dev Only callable by admin role
    function setRouter(address router_) external;

    /// @notice Sets the LayerZero Endpoint contract address
    /// @param endpoint_ The Endpoint contract address
    /// @dev Only callable by admin role
    function setEndpoint(address endpoint_) external;

    /// @notice Sets the pool ID for an asset on a chain
    /// @param asset The asset address
    /// @param chainId The chain ID
    /// @param poolId The pool ID
    /// @dev Only callable by admin role
    function setAssetPoolId(address asset, uint64 chainId, uint256 poolId) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the LayerZero chain ID for a given chain ID
    /// @param chainId The standard chain ID
    /// @return The LayerZero chain ID, or 0 if not set
    function getLzChainIdForChain(uint64 chainId) external view returns (uint16);

    /// @notice Gets the standard chain ID for a given LayerZero chain ID
    /// @param lzChainId The LayerZero chain ID
    /// @return The standard chain ID, or 0 if not set
    function getChainForLzChainId(uint16 lzChainId) external view returns (uint64);

    /// @notice Quotes the LayerZero fee for a swap
    /// @param destinationChainId The destination LayerZero chain ID
    /// @param srcPoolId The source pool ID
    /// @param dstPoolId The destination pool ID
    /// @param amountLD The amount in local decimals
    /// @param payload The message payload
    /// @param dstGasForCall The destination gas for call
    /// @return nativeFee The native token fee
    /// @return zroFee The ZRO token fee (if applicable)
    function quoteLayerZeroFee(
        uint16 destinationChainId,
        uint256 srcPoolId,
        uint256 dstPoolId,
        uint256 amountLD,
        bytes calldata payload,
        uint256 dstGasForCall
    ) external view returns (uint256 nativeFee, uint256 zroFee);
}
