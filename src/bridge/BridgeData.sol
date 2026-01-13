// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title BridgeData
/// @notice Standard bridge data structure for all bridge adapters
/// @author kpk
library BridgeData {
    /// @notice Standard bridge data structure
    /// @param asset The token address (address(0) for native)
    /// @param amount The amount to bridge
    /// @param destinationChainId The destination chain ID
    /// @param recipient The recipient address on destination chain
    /// @param messagePayload The message payload to deliver alongside funds
    struct BridgeParams {
        address asset;
        uint256 amount;
        uint64 destinationChainId;
        address recipient;
        bytes messagePayload;
    }

    /// @notice Encodes bridge parameters into bytes
    /// @param params The bridge parameters
    /// @return The encoded bridge data
    function encode(BridgeParams memory params) internal pure returns (bytes memory) {
        return abi.encode(params);
    }

    /// @notice Decodes bridge data into parameters
    /// @param data The encoded bridge data
    /// @return The decoded bridge parameters
    function decode(bytes calldata data) internal pure returns (BridgeParams memory) {
        return abi.decode(data, (BridgeParams));
    }

    /// @notice Standard completion data structure
    /// @param messagePayload The message payload extracted from the bridge message (if available)
    /// @param protocolData Bridge-specific protocol data (e.g., CCTP message+attestation, CCIP Any2EVMMessage)
    struct CompletionParams {
        bytes messagePayload;
        bytes protocolData;
    }

    /// @notice Encodes completion parameters into bytes
    /// @param params The completion parameters
    /// @return The encoded completion data
    function encodeCompletion(CompletionParams memory params) internal pure returns (bytes memory) {
        return abi.encode(params);
    }

    /// @notice Decodes completion data into parameters
    /// @param data The encoded completion data
    /// @return The decoded completion parameters
    function decodeCompletion(bytes calldata data) internal pure returns (CompletionParams memory) {
        return abi.decode(data, (CompletionParams));
    }
}
