// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

/// @title TestEnvConfigurator
/// @notice A test library contract dedicated to importing and managing environment variables
/// @notice Provides utilities for constructing RPC URLs and accessing environment configuration
abstract contract TestEnvConfigurator is Test {
    error AlchemyApiKeyNotSet();

    /// @notice Constructs an Alchemy RPC URL for the given network
    /// @param network The Alchemy network identifier (e.g., "eth-mainnet", "opt-mainnet", "base-mainnet", "arb-mainnet", "gnosis-mainnet")
    /// @return url The full Alchemy RPC URL
    function getAlchemyUrl(string memory network) internal view returns (string memory url) {
        string memory apiKey = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(apiKey).length == 0) {
            revert AlchemyApiKeyNotSet();
        }
        url = string.concat("https://", network, ".g.alchemy.com/v2/", apiKey);
    }
}

