// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBridgeAdapter} from "../../IBridgeAdapter.sol";
import {ILayerZeroComposer} from "./IStargateInterfaces.sol";

/// @title IStargateBridgeAdapter Interface
/// @notice Interface for the Stargate V2 (OFT / LayerZero V2) Bridge Adapter
/// @dev Documents events, errors, and public functions. Destination completion is provenance-checked
///      (ADR 0012): the genuine LayerZero V2 Endpoint calls `lzCompose` on the adapter after Stargate
///      delivers the tokens to it; the adapter authenticates the endpoint, the source eid and the source
///      sibling adapter against `trustedRemoteAdapter`, then funds the escrow and releases.
/// @author KPK
interface IStargateBridgeAdapter is IBridgeAdapter, ILayerZeroComposer {
    //
    // Events
    //

    /// @notice Emitted when a Stargate V2 bridge is initiated
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param dstEid The destination LayerZero endpoint ID
    /// @param guid The LayerZero message guid
    /// @param amount The amount being bridged
    event StargateBridgeInitiated(bytes32 indexed invoiceId, uint32 dstEid, bytes32 guid, uint256 amount);

    /// @notice Emitted when a Stargate V2 bridge is completed on the destination chain
    /// @param invoiceId The invoice ID (32 bytes) - indexed
    /// @param srcEid The source LayerZero endpoint ID
    event StargateBridgeCompleted(bytes32 indexed invoiceId, uint32 srcEid);

    //
    // Errors
    //

    /// @notice Thrown when a zero LayerZero endpoint address is provided to `initialize`/`setEndpoint`, or when
    ///         `lzCompose` is called by an address other than the configured endpoint
    error InvalidEndpoint();

    /// @notice Thrown when no Stargate V2 pool is configured for an asset on the bridge/completion path, or when
    ///         `setStargatePool` is given a zero pool address or a pool whose `token()` does not equal the asset
    error InvalidPool();

    /// @notice Thrown when attempting to bridge to a chain with no eid mapping, or when an inbound message
    ///         arrives from an eid that maps to no chain ID
    /// @param dstEid 0 on the outbound path (the destination chain has no eid mapping); the offending source
    ///        eid on the inbound path (no chain ID maps to it)
    error UnsupportedChain(uint32 dstEid);

    /// @notice Thrown when bridge data is invalid or provenance authentication fails
    error InvalidBridgeData();

    //
    // State Variables (Public)
    //

    /// @notice LayerZero V2 Endpoint contract address (the only authorized caller of lzCompose)
    /// @return The Endpoint address
    function endpoint() external view returns (address);

    /// @notice Gets the Stargate V2 pool (OFT) address configured for an asset
    /// @param asset The asset address
    /// @return The Stargate V2 pool address, or address(0) if not set
    function stargatePool(address asset) external view returns (address);

    /// @notice Gets the LayerZero endpoint ID (eid) for a given chain ID
    /// @param chainId The standard chain ID
    /// @return The LayerZero eid, or 0 if not set
    function chainIdToEid(uint64 chainId) external view returns (uint32);

    /// @notice Gets the standard chain ID for a given LayerZero endpoint ID (eid)
    /// @param eid The LayerZero eid
    /// @return The standard chain ID, or 0 if not set
    function eidToChainId(uint32 eid) external view returns (uint64);

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function messagePayloads(bytes32 invoiceId) external view returns (bytes memory);

    //
    // Configuration Functions
    //

    /// @notice Initializes the Stargate V2 Bridge Adapter
    /// @param admin_ The admin address
    /// @param bridgeEscrow_ The BridgeEscrow contract address
    /// @param endpoint_ The LayerZero V2 Endpoint contract address
    /// @param version_ The adapter version
    function initialize(address admin_, address bridgeEscrow_, address endpoint_, string memory version_) external;

    /// @notice Sets the LayerZero eid mapping for a chain ID
    /// @param chainId The standard chain ID
    /// @param eid The LayerZero endpoint ID
    /// @dev Only callable by admin role
    function setEidMapping(uint64 chainId, uint32 eid) external;

    /// @notice Sets the LayerZero V2 Endpoint contract address
    /// @param endpoint_ The Endpoint address
    /// @dev Only callable by admin role
    function setEndpoint(address endpoint_) external;

    /// @notice Sets the Stargate V2 pool (OFT) used to bridge an asset
    /// @param asset The asset address
    /// @param pool The Stargate V2 pool address (its `token()` must equal `asset`)
    /// @dev Only callable by admin role
    function setStargatePool(address asset, address pool) external;

    /// @notice Sets the destination executor options (extraOptions) used for the lzCompose gas budget
    /// @param dstEid The destination LayerZero eid
    /// @param options The encoded executor options (LayerZero OptionsBuilder output)
    /// @dev Only callable by admin role
    function setComposeOptions(uint32 dstEid, bytes calldata options) external;

    //
    // View Functions
    //

    /// @notice Gets the stored message payload for an invoice
    /// @param invoiceId The invoice ID (32 bytes)
    /// @return The message payload, or empty bytes if not found
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory);

    /// @notice Gets the LayerZero eid for a given chain ID
    /// @param chainId The standard chain ID
    /// @return The LayerZero eid, or 0 if not set
    function getEidForChain(uint64 chainId) external view returns (uint32);

    /// @notice Gets the standard chain ID for a given LayerZero eid
    /// @param eid The LayerZero eid
    /// @return The standard chain ID, or 0 if not set
    function getChainForEid(uint32 eid) external view returns (uint64);
}
