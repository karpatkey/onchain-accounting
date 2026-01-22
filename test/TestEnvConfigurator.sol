// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

/// @title TestEnvConfigurator
/// @notice A test library contract dedicated to importing and managing environment variables
/// @notice Provides utilities for constructing RPC URLs and accessing environment configuration
/// @notice Includes fork creation helpers with cadence control to prevent RPC rate limiting
abstract contract TestEnvConfigurator is Test {
    error AlchemyApiKeyNotSet();

    // Storage slot for fork creation counter (helps with cadence tracking)
    uint256 private constant FORK_COUNTER_SLOT = uint256(keccak256("TestEnvConfigurator.forkCounter"));

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

    /// @notice Creates a fork with cadence control to reduce simultaneous RPC requests
    /// @dev This function increments a counter to help stagger fork creations
    /// @dev For best results, run tests with --no-parallel or --jobs 1 to prevent rate limiting
    /// @param url The RPC URL to fork from
    /// @return forkId The fork ID
    function createForkWithCadence(string memory url) internal returns (uint256 forkId) {
        _incrementForkCounter();
        forkId = vm.createFork(url);
    }

    /// @notice Creates a fork at a specific block with cadence control
    /// @dev This function increments a counter to help stagger fork creations
    /// @dev For best results, run tests with --no-parallel or --jobs 1 to prevent rate limiting
    /// @param url The RPC URL to fork from
    /// @param blockNumber The block number to fork at
    /// @return forkId The fork ID
    function createForkWithCadence(string memory url, uint256 blockNumber) internal returns (uint256 forkId) {
        _incrementForkCounter();
        forkId = vm.createFork(url, blockNumber);
    }

    /// @notice Creates and selects a fork with cadence control
    /// @dev This function increments a counter to help stagger fork creations
    /// @dev For best results, run tests with --no-parallel or --jobs 1 to prevent rate limiting
    /// @param url The RPC URL to fork from
    /// @return forkId The fork ID
    function createSelectForkWithCadence(string memory url) internal returns (uint256 forkId) {
        _incrementForkCounter();
        forkId = vm.createSelectFork(url);
    }

    /// @notice Creates and selects a fork at a specific block with cadence control
    /// @dev This function increments a counter to help stagger fork creations
    /// @dev For best results, run tests with --no-parallel or --jobs 1 to prevent rate limiting
    /// @param url The RPC URL to fork from
    /// @param blockNumber The block number to fork at
    /// @return forkId The fork ID
    function createSelectForkWithCadence(string memory url, uint256 blockNumber) internal returns (uint256 forkId) {
        _incrementForkCounter();
        forkId = vm.createSelectFork(url, blockNumber);
    }

    /// @notice Increments the fork creation counter to help with cadence tracking
    /// @dev Uses a storage slot to maintain state across test contracts
    function _incrementForkCounter() private {
        uint256 slot = FORK_COUNTER_SLOT;
        uint256 counter;
        assembly {
            counter := sload(slot)
            sstore(slot, add(counter, 1))
        }
    }
}

