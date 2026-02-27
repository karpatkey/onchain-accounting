// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

/// @title TestEnvConfigurator
/// @notice A test library contract dedicated to importing and managing environment variables
/// @notice Provides utilities for constructing RPC URLs and accessing environment configuration
/// @notice Includes fork creation helpers with cadence control to prevent RPC rate limiting
abstract contract TestEnvConfigurator is Test {
    error RpcUrlNotSet();

    // Storage slot for fork creation counter (helps with cadence tracking)
    uint256 private constant FORK_COUNTER_SLOT = uint256(keccak256("TestEnvConfigurator.forkCounter"));

    /// @notice Returns the RPC URL for the given network.
    /// @dev Prefer chain-specific env vars (MAINNET_URL, ARBITRUM_URL, BASE_URL, OP_URL, GNOSIS_URL), e.g. from CI
    ///      (vars.KNODE_URL + /ethereum?key= + secrets.KNODE_API_KEY). If none set, builds Alchemy URL from
    ///      ALCHEMY_API_KEY. Reverts if neither source is set.
    /// @param network Alchemy network identifier (e.g. "eth-mainnet", "arb-mainnet", "base-mainnet", "opt-mainnet", "gnosis-mainnet")
    /// @return url The RPC URL to use for forking
    function getAlchemyUrl(string memory network) internal view returns (string memory url) {
        url = _getChainUrl(network);
        if (bytes(url).length != 0) {
            return url;
        }
        string memory apiKey = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(apiKey).length == 0) {
            revert RpcUrlNotSet();
        }
        return string.concat("https://", network, ".g.alchemy.com/v2/", apiKey);
    }

    /// @notice Resolves chain-specific RPC URL from env (MAINNET_URL, ARBITRUM_URL, etc.). Returns empty if not set.
    function _getChainUrl(string memory network) internal view returns (string memory) {
        if (keccak256(bytes(network)) == keccak256("eth-mainnet")) {
            return vm.envOr("MAINNET_URL", string(""));
        }
        if (keccak256(bytes(network)) == keccak256("arb-mainnet")) {
            return vm.envOr("ARBITRUM_URL", string(""));
        }
        if (keccak256(bytes(network)) == keccak256("base-mainnet")) {
            return vm.envOr("BASE_URL", string(""));
        }
        if (keccak256(bytes(network)) == keccak256("opt-mainnet")) {
            return vm.envOr("OP_URL", string(""));
        }
        if (keccak256(bytes(network)) == keccak256("gnosis-mainnet")) {
            return vm.envOr("GNOSIS_URL", string(""));
        }
        return "";
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

