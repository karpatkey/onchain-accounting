// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title ConfigReader
/// @notice Utility for reading and parsing per-chain configuration JSON files
library ConfigReader {
    using stdJson for string;

    struct ChainConfig {
        uint256 chainId;
        string name;
        string rpc;
        string explorer;
        string explorerApiKey;
        address chainlinkSequencerFeed;
        string nativeTokenSymbol;
        address safeMultisig;
        address admin;
        address manager;
    }

    struct AdapterConfig {
        bool enabled;
        string deployed;
    }

    /// @notice Reads chain configuration for a specific chain ID from per-chain config file
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID to read config for
    /// @return config The chain configuration
    function readChainConfig(Vm vm, uint256 chainId) internal view returns (ChainConfig memory config) {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/chains/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);

        config.chainId = chainId;
        config.name = json.readString(".name");
        config.rpc = _resolveRpcUrl(vm, json.readString(".rpc"), chainId);
        config.explorer = json.readString(".explorer");
        config.explorerApiKey = _resolveEnvVar(vm, json.readString(".explorerApiKey"));
        config.chainlinkSequencerFeed = json.readAddress(".chainlinkSequencerFeed");
        config.nativeTokenSymbol = json.readString(".nativeTokenSymbol");
        config.safeMultisig = json.readAddress(".addresses.safeMultisig");
        config.admin = json.readAddress(".addresses.admin");
        config.manager = json.readAddress(".addresses.manager");
    }

    /// @notice Reads deployed address from chain config file
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param contractName The contract name to read address for
    /// @return The deployed contract address, or zero address if not found
    function readDeployedAddress(Vm vm, uint256 chainId, string memory contractName) internal view returns (address) {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/chains/", vm.toString(chainId), ".json"));

        string memory json = vm.readFile(path);
        string memory jsonPath = string(abi.encodePacked(".deployed.", contractName));

        // keyExists will tell us if the key is present
        if (!vm.keyExists(json, jsonPath)) {
            return address(0);
        }

        string memory addrStr = json.readString(jsonPath);
        if (bytes(addrStr).length == 0 || _isPlaceholder(addrStr)) {
            return address(0);
        }

        return vm.parseAddress(addrStr);
    }

    /// @notice Writes deployed address to chain config file
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param contractName The contract name
    /// @param contractAddress The deployed address
    function writeDeployedAddress(Vm vm, uint256 chainId, string memory contractName, address contractAddress)
        internal
    {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/chains/", vm.toString(chainId), ".json"));

        // Write to deployed.{contractName}
        string memory jsonPath = string(abi.encodePacked(".deployed.", contractName));
        vm.writeJson(vm.toString(contractAddress), path, jsonPath);
    }

    /// @notice Reads enabled adapters for a given type from chain config
    /// @dev Placeholder implementation - returns empty array
    /// @return names Array of adapter names that are enabled
    function getEnabledAdapters(
        Vm,
        /* vm */
        uint256,
        /* chainId */
        string memory /* adapterType */
    )
        internal
        pure
        returns (string[] memory names)
    {
        // This is a simplified version - in practice you'd need to parse the JSON
        // and iterate through the adapter type to find enabled ones
        // For now, returning empty array as placeholder
        names = new string[](0);
    }

    /// @notice Reads price feed constructor parameter from assets config (script/config/assets.json)
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param adapterName Price feed adapter name (e.g. "sDAI", "LDO")
    /// @param paramName Constructor parameter name
    /// @return The parameter value as a string, or empty if not found
    function readPriceFeedParam(Vm vm, uint256 chainId, string memory adapterName, string memory paramName)
        internal
        view
        returns (string memory)
    {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/assets.json"));
        string memory json = vm.readFile(path);
        string memory jsonPath = string(
            abi.encodePacked(".priceFeeds.", adapterName, ".", vm.toString(chainId), ".constructor.", paramName)
        );
        if (vm.keyExists(json, jsonPath)) {
            return json.readString(jsonPath);
        }
        return "";
    }

    /// @notice Returns whether a price feed adapter is enabled for a chain (from assets config)
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param adapterName Price feed adapter name
    /// @return True if enabled in script/config/assets.json
    function isPriceFeedEnabled(Vm vm, uint256 chainId, string memory adapterName) internal view returns (bool) {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/assets.json"));
        string memory json = vm.readFile(path);
        string memory jsonPath =
            string(abi.encodePacked(".priceFeeds.", adapterName, ".", vm.toString(chainId), ".enabled"));
        if (vm.keyExists(json, jsonPath)) {
            return json.readBool(jsonPath);
        }
        return false;
    }

    /// @notice Reads token address from assets config (tokens section)
    function readTokenAddress(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        return _readTokenField(vm, chainId, symbol, "address");
    }

    /// @notice Reads token oracle address from assets config (tokens section). Empty if none.
    function readTokenOracle(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        return _readTokenField(vm, chainId, symbol, "oracle");
    }

    /// @notice Reads token price type from assets config: "Chainlink", "Custom", or "None"
    function readTokenType(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        return _readTokenField(vm, chainId, symbol, "type");
    }

    /// @notice Reads token oracle heartbeat (seconds) from assets config. Returns "3600" if missing.
    function readTokenHeartbeat(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/assets.json"));
        string memory json = vm.readFile(path);
        string memory jsonPath = string(abi.encodePacked(".tokens.", vm.toString(chainId), ".", symbol, ".heartbeat"));
        if (vm.keyExists(json, jsonPath)) {
            return vm.toString(json.readUint(jsonPath));
        }
        return "3600";
    }

    /// @notice True if token has a usable oracle (Chainlink or Custom with non-empty oracle address)
    function hasTokenOracle(Vm vm, uint256 chainId, string memory symbol) internal view returns (bool) {
        string memory oracleType = readTokenType(vm, chainId, symbol);
        if (_equals(oracleType, "None")) return false;
        string memory oracle = readTokenOracle(vm, chainId, symbol);
        return bytes(oracle).length > 0 && !_isPlaceholder(oracle);
    }

    /// @notice Reads optional note for a token from assets config (e.g. "No oracle available").
    function readTokenNote(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        return _readTokenField(vm, chainId, symbol, "note");
    }

    function _readTokenField(Vm vm, uint256 chainId, string memory symbol, string memory field)
        private
        view
        returns (string memory)
    {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/assets.json"));
        string memory json = vm.readFile(path);
        string memory jsonPath = string(abi.encodePacked(".tokens.", vm.toString(chainId), ".", symbol, ".", field));
        if (vm.keyExists(json, jsonPath)) {
            return json.readString(jsonPath);
        }
        return "";
    }

    /// @notice Reads adapter constructor parameters from chain config (balanceAdapters, bridgeAdapters)
    ///         or "deployed" for any adapter type from chain config. For price feed constructor params use readPriceFeedParam.
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param adapterType Type of adapter ("priceFeeds", "balanceAdapters", "bridgeAdapters")
    /// @param adapterName Name of the adapter
    /// @param paramName Name of the constructor parameter (or "deployed" for price feeds)
    /// @return The parameter value as a string
    function readAdapterParam(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        string memory paramName
    ) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/chains/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);

        // Note: priceFeeds has been removed from chain config schema
        // For priceFeeds, constructor params live in assets.json; deployed addresses are no longer stored in chain config
        string memory jsonPath = string(abi.encodePacked(".", adapterType, ".", adapterName, ".", paramName));
        if (vm.keyExists(json, jsonPath)) {
            return json.readString(jsonPath);
        }

        // Try constructor path (for balanceAdapters)
        jsonPath = string(abi.encodePacked(".", adapterType, ".", adapterName, ".constructor.", paramName));
        if (vm.keyExists(json, jsonPath)) {
            return json.readString(jsonPath);
        }

        // Try initialize path (for bridgeAdapters)
        jsonPath = string(abi.encodePacked(".", adapterType, ".", adapterName, ".initialize.", paramName));
        if (vm.keyExists(json, jsonPath)) {
            return json.readString(jsonPath);
        }

        return "";
    }

    /// @notice Checks if an adapter is enabled for a chain. For "priceFeeds" reads from assets.json; otherwise from chain config.
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param adapterType Type of adapter ("priceFeeds", "balanceAdapters", "bridgeAdapters")
    /// @param adapterName Name of the adapter
    /// @return True if enabled
    function isAdapterEnabled(Vm vm, uint256 chainId, string memory adapterType, string memory adapterName)
        internal
        view
        returns (bool)
    {
        if (_equals(adapterType, "priceFeeds")) {
            return isPriceFeedEnabled(vm, chainId, adapterName);
        }
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/chains/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);
        string memory jsonPath = string(abi.encodePacked(".", adapterType, ".", adapterName, ".enabled"));
        if (vm.keyExists(json, jsonPath)) {
            return json.readBool(jsonPath);
        }
        return false;
    }

    /// @notice Writes adapter deployed address to chain config
    /// @param vm The Foundry Vm instance
    /// @param chainId The chain ID
    /// @param adapterType Type of adapter
    /// @param adapterName Name of the adapter
    /// @param deployedAddress The deployed address
    function writeAdapterAddress(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        address deployedAddress
    ) internal {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/script/config/chains/", vm.toString(chainId), ".json"));

        string memory jsonPath = string(abi.encodePacked(".", adapterType, ".", adapterName, ".deployed"));
        vm.writeJson(vm.toString(deployedAddress), path, jsonPath);
    }

    /// @notice Computes a deterministic salt for CREATE2 deployment
    /// @param contractName The contract name
    /// @param version The version number (increment to get new address)
    /// @return The CREATE2 salt
    function computeSalt(string memory contractName, uint256 version) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(contractName, version));
    }

    /// @dev Resolves RPC URL: if value is $ALCHEMY, build from ALCHEMY_API_KEY (or ALCHEMY_APİ_KEY) + chain's Alchemy network (same pattern as TestEnvConfigurator.getAlchemyUrl).
    ///      Otherwise resolve $VAR_NAME env vars as usual.
    function _resolveRpcUrl(Vm vm, string memory value, uint256 chainId) private view returns (string memory) {
        if (_equals(value, "$ALCHEMY")) {
            string memory network = _alchemyNetworkForChainId(chainId);
            if (bytes(network).length == 0) return "";
            string memory apiKey = vm.envOr("ALCHEMY_API_KEY", string(""));
            if (bytes(apiKey).length == 0) {
                apiKey = vm.envOr("ALCHEMY_API_KEY", string(""));
            }
            if (bytes(apiKey).length == 0) return "";
            return string.concat("https://", network, ".g.alchemy.com/v2/", apiKey);
        }
        return _resolveEnvVar(vm, value);
    }

    /// @dev Alchemy network identifier for chain ID (matches TestEnvConfigurator.getAlchemyUrl network names).
    function _alchemyNetworkForChainId(uint256 chainId) private pure returns (string memory) {
        if (chainId == 1) return "eth-mainnet";
        if (chainId == 10) return "opt-mainnet";
        if (chainId == 100) return "gnosis-mainnet";
        if (chainId == 42161) return "arb-mainnet";
        if (chainId == 8453) return "base-mainnet";
        return "";
    }

    /// @dev Simple string equality (keccak256 comparison).
    function _equals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Resolves environment variables in format $VAR_NAME
    function _resolveEnvVar(Vm vm, string memory value) private view returns (string memory) {
        bytes memory valueBytes = bytes(value);
        if (valueBytes.length > 0 && valueBytes[0] == "$") {
            // Remove $ prefix and read env var
            string memory varName = substring(value, 1, valueBytes.length);
            return vm.envOr(varName, string(""));
        }
        return value;
    }

    /// @dev Helper to extract substring
    function substring(string memory str, uint256 startIndex, uint256 endIndex) private pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    /// @dev Check if a string is a placeholder (contains "YOUR_" or "0x0000...")
    function _isPlaceholder(string memory value) private pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        if (valueBytes.length >= 5) {
            if (
                valueBytes[0] == "Y" && valueBytes[1] == "O" && valueBytes[2] == "U" && valueBytes[3] == "R"
                    && valueBytes[4] == "_"
            ) {
                return true;
            }
        }
        if (valueBytes.length == 42) {
            // Check for 0x0000000000000000000000000000000000000000
            bool allZeros = true;
            for (uint256 i = 2; i < valueBytes.length && allZeros; i++) {
                if (valueBytes[i] != "0") {
                    allZeros = false;
                }
            }
            if (allZeros) return true;
        }
        return false;
    }
}
