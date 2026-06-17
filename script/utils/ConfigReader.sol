// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title ConfigReader
/// @notice Utility for reading/parsing the NAV deployment configuration.
/// @dev Config is organized by concern, one JSON file per chain (top-level keys; the file *is* the chain). All
///      paths are under `script/config/`:
///      - `chains/<id>.json`                              — chain meta, roles, and `bridgeAdapters` intent.
///      - `contracts-deployment-config/price-feeds/<id>.json`     — Custom feed adapters to DEPLOY: `.<name>.{enabled,constructor}`.
///      - `contracts-deployment-config/balance-adapters/<id>.json`— balance + meta adapters to DEPLOY: `.<name>.{enabled,constructor}`.
///      - `nav-config/assets-and-price-feeds/<id>.json`   — assets to REGISTER: `.<SYMBOL>.{address,priceFeeds[]}`.
///      - `nav-config/balance-adapters/<id>.json`         — PLAIN adapters to ADD on NAV: `.<name>.{enabled}`.
///      - `nav-config/meta-balance-adapters/<id>.json`    — META adapters to ADD: `.<name>.{enabled,instances|instancesRaw}`.
///      - `deployments/<id>.json`                         — deployed addresses (state). Top-level for proxies/impls;
///                                                          nested `.balanceAdapters/.customPriceFeeds/.bridgeAdapters.<name>`.
///      The `adapterType` token passed to the adapter readers selects the file: `deployBalanceAdapters`,
///      `deployPriceFeeds` (alias `priceFeeds`/`customPriceFeeds`), `navBalanceAdapters`, `navMetaBalanceAdapters`,
///      `bridgeAdapters`. Deployments-file accessors still take the section token (`balanceAdapters`/`customPriceFeeds`/
///      `bridgeAdapters`).
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
        address securityCouncil;
        address admin;
        address manager;
    }

    // -------------------------------------------------------------------------
    // File paths
    // -------------------------------------------------------------------------

    function _chainPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(abi.encodePacked(vm.projectRoot(), "/script/config/chains/", vm.toString(chainId), ".json"));
    }

    function _navAssetsPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(), "/script/config/nav-config/assets-and-price-feeds/", vm.toString(chainId), ".json"
            )
        );
    }

    function _navBalanceAdaptersPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(), "/script/config/nav-config/balance-adapters/", vm.toString(chainId), ".json"
            )
        );
    }

    function _navMetaBalanceAdaptersPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(), "/script/config/nav-config/meta-balance-adapters/", vm.toString(chainId), ".json"
            )
        );
    }

    function _deployPriceFeedsPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/contracts-deployment-config/price-feeds/",
                vm.toString(chainId),
                ".json"
            )
        );
    }

    function _deployBalanceAdaptersPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/contracts-deployment-config/balance-adapters/",
                vm.toString(chainId),
                ".json"
            )
        );
    }

    function _deploymentsPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(abi.encodePacked(vm.projectRoot(), "/script/config/deployments/", vm.toString(chainId), ".json"));
    }

    /// @dev Reads a file, returning "{}" if it does not exist (deployments files are created lazily).
    function _readOrEmpty(Vm vm, string memory path) private view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.readFile(path) returns (string memory s) {
            return bytes(s).length == 0 ? "{}" : s;
        } catch {
            return "{}";
        }
    }

    /// @dev Maps an adapterType to its deployments-file section key (price feeds live under customPriceFeeds).
    function _deploymentsSection(string memory adapterType) private pure returns (string memory) {
        if (_equals(adapterType, "priceFeeds") || _equals(adapterType, "customPriceFeeds")) return "customPriceFeeds";
        return adapterType; // "balanceAdapters" | "bridgeAdapters"
    }

    // -------------------------------------------------------------------------
    // Chain meta
    // -------------------------------------------------------------------------

    /// @notice Reads chain meta + role addresses from `chains/<id>.json`.
    function readChainConfig(Vm vm, uint256 chainId) internal view returns (ChainConfig memory config) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(_chainPath(vm, chainId));

        config.chainId = chainId;
        config.name = json.readString(".name");
        config.rpc = _resolveRpcUrl(vm, json.readString(".rpc"), chainId);
        config.explorer = json.readString(".explorer");
        config.explorerApiKey = _resolveEnvVar(vm, json.readString(".explorerApiKey"));
        config.chainlinkSequencerFeed = json.readAddress(".chainlinkSequencerFeed");
        config.nativeTokenSymbol = json.readString(".nativeTokenSymbol");
        config.securityCouncil = json.readAddress(".addresses.securityCouncil");
        config.admin = json.readAddress(".addresses.admin");
        config.manager = json.readAddress(".addresses.manager");
    }

    // -------------------------------------------------------------------------
    // Deployed addresses (deployments/<id>.json — state)
    // -------------------------------------------------------------------------

    /// @notice Reads a top-level deployed contract address (e.g. NAVCalculatorProxy). Zero if absent.
    function readDeployedAddress(Vm vm, uint256 chainId, string memory contractName) internal view returns (address) {
        string memory json = _readOrEmpty(vm, _deploymentsPath(vm, chainId));
        string memory jsonPath = string(abi.encodePacked(".", contractName));
        return _readAddrOrZero(vm, json, jsonPath);
    }

    /// @notice Writes a top-level deployed contract address to the deployments file.
    function writeDeployedAddress(Vm vm, uint256 chainId, string memory contractName, address contractAddress)
        internal
    {
        vm.writeJson(
            vm.toString(contractAddress), _deploymentsPath(vm, chainId), string(abi.encodePacked(".", contractName))
        );
    }

    /// @notice Reads a deployed adapter/feed address from the deployments file. Zero if absent.
    /// @param adapterType "balanceAdapters" | "priceFeeds"/"customPriceFeeds" | "bridgeAdapters"
    function readDeployedAdapterAddress(Vm vm, uint256 chainId, string memory adapterType, string memory name)
        internal
        view
        returns (address)
    {
        string memory json = _readOrEmpty(vm, _deploymentsPath(vm, chainId));
        string memory jsonPath = string(abi.encodePacked(".", _deploymentsSection(adapterType), ".", name));
        return _readAddrOrZero(vm, json, jsonPath);
    }

    /// @notice Writes a deployed adapter/feed address to the deployments file.
    function writeAdapterAddress(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        address deployedAddress
    ) internal {
        string memory jsonPath = string(abi.encodePacked(".", _deploymentsSection(adapterType), ".", adapterName));
        vm.writeJson(vm.toString(deployedAddress), _deploymentsPath(vm, chainId), jsonPath);
    }

    function _readAddrOrZero(Vm vm, string memory json, string memory jsonPath) private view returns (address) {
        if (!vm.keyExists(json, jsonPath)) return address(0);
        string memory addrStr = json.readString(jsonPath);
        if (bytes(addrStr).length == 0 || _isPlaceholder(addrStr)) return address(0);
        return vm.parseAddress(addrStr);
    }

    // -------------------------------------------------------------------------
    // Balance adapters (balance-adapters.json) + bridge adapters (chains/<id>.json)
    // -------------------------------------------------------------------------

    /// @dev Returns the file + jsonPath prefix for an adapter section. Each concern is a per-chain file with top-level
    ///      keys (empty prefix); bridgeAdapters stay nested in the chain config. The token selects the file:
    ///      `deployBalanceAdapters`/`navBalanceAdapters`/`navMetaBalanceAdapters`/`deployPriceFeeds`
    ///      (aliases `priceFeeds`/`customPriceFeeds`) → their per-chain files; anything else → chain config.
    function _adapterFileAndPrefix(Vm vm, uint256 chainId, string memory adapterType)
        private
        view
        returns (string memory json, string memory prefix)
    {
        if (_equals(adapterType, "deployBalanceAdapters") || _equals(adapterType, "balanceAdapters")) {
            // "balanceAdapters" is the legacy alias for the deploy-config file (deploy scripts read enabled/constructor
            // from here). The NAV-registration side uses the explicit navBalanceAdapters/navMetaBalanceAdapters tokens.
            json = _readOrEmpty(vm, _deployBalanceAdaptersPath(vm, chainId));
            prefix = "";
        } else if (_equals(adapterType, "navBalanceAdapters")) {
            json = _readOrEmpty(vm, _navBalanceAdaptersPath(vm, chainId));
            prefix = "";
        } else if (_equals(adapterType, "navMetaBalanceAdapters")) {
            json = _readOrEmpty(vm, _navMetaBalanceAdaptersPath(vm, chainId));
            prefix = "";
        } else if (
            _equals(adapterType, "deployPriceFeeds") || _equals(adapterType, "priceFeeds")
                || _equals(adapterType, "customPriceFeeds")
        ) {
            json = _readOrEmpty(vm, _deployPriceFeedsPath(vm, chainId));
            prefix = "";
        } else {
            // bridgeAdapters (and any other) — chain config, nested under the type key.
            json = _readOrEmpty(vm, _chainPath(vm, chainId));
            prefix = string(abi.encodePacked(".", adapterType));
        }
    }

    /// @dev The parseJsonKeys path for an adapter container: root ("$") for top-level per-chain files, else the prefix.
    function _containerPath(string memory prefix) private pure returns (string memory) {
        return bytes(prefix).length == 0 ? "$" : prefix;
    }

    /// @notice Returns every adapter name under a section (excludes `$`-prefixed metadata keys). Does NOT filter by
    ///         `enabled` — call `isAdapterEnabled` per key for that.
    function getEnabledAdapters(Vm vm, uint256 chainId, string memory adapterType)
        internal
        view
        returns (string[] memory names)
    {
        (string memory json, string memory prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);
        string memory jsonPath = _containerPath(prefix);
        if (!vm.keyExists(json, jsonPath)) return new string[](0);

        string[] memory allKeys = vm.parseJsonKeys(json, jsonPath);
        uint256 count;
        for (uint256 i; i < allKeys.length; ++i) {
            if (bytes(allKeys[i]).length > 0 && bytes(allKeys[i])[0] != "$") ++count;
        }
        names = new string[](count);
        uint256 j;
        for (uint256 i; i < allKeys.length; ++i) {
            if (bytes(allKeys[i]).length > 0 && bytes(allKeys[i])[0] != "$") names[j++] = allKeys[i];
        }
    }

    /// @notice Whether an adapter is enabled in its config file (selected by `adapterType` — see `_adapterFileAndPrefix`).
    function isAdapterEnabled(Vm vm, uint256 chainId, string memory adapterType, string memory adapterName)
        internal
        view
        returns (bool)
    {
        (string memory json, string memory prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);
        string memory jsonPath = string(abi.encodePacked(prefix, ".", adapterName, ".enabled"));
        if (vm.keyExists(json, jsonPath)) return json.readBool(jsonPath);
        return false;
    }

    /// @notice Reads an adapter constructor/initialize/bare param. balanceAdapters → balance-adapters.json;
    ///         bridgeAdapters → chain config.
    function readAdapterParam(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        string memory paramName
    ) internal view returns (string memory) {
        (string memory json, string memory prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);

        string memory base = string(abi.encodePacked(prefix, ".", adapterName));
        string memory p = string(abi.encodePacked(base, ".", paramName));
        if (vm.keyExists(json, p)) return json.readString(p);
        p = string(abi.encodePacked(base, ".constructor.", paramName));
        if (vm.keyExists(json, p)) return json.readString(p);
        p = string(abi.encodePacked(base, ".initialize.", paramName));
        if (vm.keyExists(json, p)) return json.readString(p);
        return "";
    }

    /// @notice Reads an address-array adapter param (e.g. a meta-adapter's `instances`). Empty if absent.
    function readAdapterAddressArray(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        string memory paramName
    ) internal view returns (address[] memory) {
        (string memory json, string memory prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);
        string memory base = string(abi.encodePacked(prefix, ".", adapterName));
        string memory p = string(abi.encodePacked(base, ".", paramName));
        if (vm.keyExists(json, p)) return vm.parseJsonAddressArray(json, p);
        p = string(abi.encodePacked(base, ".constructor.", paramName));
        if (vm.keyExists(json, p)) return vm.parseJsonAddressArray(json, p);
        return new address[](0);
    }

    /// @notice Reads a bytes32-array adapter param (e.g. a meta-adapter's `instancesRaw`). Empty if absent.
    function readAdapterBytes32Array(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        string memory paramName
    ) internal view returns (bytes32[] memory) {
        (string memory json, string memory prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);
        string memory base = string(abi.encodePacked(prefix, ".", adapterName));
        string memory p = string(abi.encodePacked(base, ".", paramName));
        if (vm.keyExists(json, p)) return vm.parseJsonBytes32Array(json, p);
        p = string(abi.encodePacked(base, ".constructor.", paramName));
        if (vm.keyExists(json, p)) return vm.parseJsonBytes32Array(json, p);
        return new bytes32[](0);
    }

    /// @notice Reads an optional bridge-adapter callback selector (e.g. "0x85572ffb").
    function readAdapterCallbackSelector(Vm vm, uint256 chainId, string memory adapterType, string memory adapterName)
        internal
        view
        returns (bool hasSelector, bytes4 selector)
    {
        string memory s = readAdapterParam(vm, chainId, adapterType, adapterName, "callbackSelector");
        if (bytes(s).length == 0 || _isPlaceholder(s)) return (false, bytes4(0));
        selector = _parseSelectorHex4(vm, s);
        return (selector != bytes4(0), selector);
    }

    // -------------------------------------------------------------------------
    // Custom price feeds (contracts-deployment-config/price-feeds/<id>.json → .<name>)
    // -------------------------------------------------------------------------

    /// @notice Reads a Custom price-feed adapter's constructor param from its deploy-config file. "" if absent.
    function readPriceFeedParam(Vm vm, uint256 chainId, string memory adapterName, string memory paramName)
        internal
        view
        returns (string memory)
    {
        return readAdapterParam(vm, chainId, "deployPriceFeeds", adapterName, paramName);
    }

    /// @notice Whether a Custom price-feed adapter is enabled for deployment.
    function isPriceFeedEnabled(Vm vm, uint256 chainId, string memory adapterName) internal view returns (bool) {
        return isAdapterEnabled(vm, chainId, "deployPriceFeeds", adapterName);
    }

    // -------------------------------------------------------------------------
    // Assets + per-asset price-feed list (nav-config/assets-and-price-feeds/<id>.json → .<SYMBOL>)
    // -------------------------------------------------------------------------

    /// @notice Returns every asset symbol configured for a chain.
    function getAssetSymbols(Vm vm, uint256 chainId) internal view returns (string[] memory) {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        if (!vm.keyExists(json, "$")) return new string[](0);
        return vm.parseJsonKeys(json, "$");
    }

    /// @notice Reads an asset's token address ("" if absent).
    function readAssetAddress(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory jsonPath = string(abi.encodePacked(".", symbol, ".address"));
        if (vm.keyExists(json, jsonPath)) return json.readString(jsonPath);
        return "";
    }

    /// @notice Number of price feeds configured for an asset (length of its `priceFeeds[]`).
    function assetFeedCount(Vm vm, uint256 chainId, string memory symbol) internal view returns (uint256 n) {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        // Probe indices until `.priceFeeds[i].type` is absent.
        while (vm.keyExists(json, _feedPath(vm, symbol, n, "type"))) {
            ++n;
        }
    }

    /// @notice Reads feed `i`'s type ("Chainlink" | "Custom" | "Redstone" | "API3").
    function readAssetFeedType(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _feedPath(vm, symbol, i, "type");
        return vm.keyExists(json, p) ? json.readString(p) : "";
    }

    /// @notice Reads feed `i`'s heartbeat (seconds, as string). Defaults to "3600" if absent.
    function readAssetFeedHeartbeat(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _feedPath(vm, symbol, i, "heartbeat");
        if (vm.keyExists(json, p)) return vm.toString(json.readUint(p));
        return "3600";
    }

    /// @notice Resolves feed `i`'s on-chain address. For `address`-bearing feeds returns it directly; for `Custom`
    ///         feeds resolves the deployed adapter from `deployments/<id>.json .customPriceFeeds.<feed>`. "" if
    ///         unresolved (e.g. Custom feed not yet deployed).
    function readAssetFeedAddress(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory addrPath = _feedPath(vm, symbol, i, "address");
        if (vm.keyExists(json, addrPath)) return json.readString(addrPath);
        // Custom feed: resolve the deployed adapter address by name.
        string memory feedPath = _feedPath(vm, symbol, i, "feed");
        if (vm.keyExists(json, feedPath)) {
            address dep = readDeployedAdapterAddress(vm, chainId, "customPriceFeeds", json.readString(feedPath));
            if (dep != address(0)) return vm.toString(dep);
        }
        return "";
    }

    /// @notice Reads feed `i`'s Custom-feed name (the `feed` field, naming a `customPriceFeeds` entry). "" if absent
    ///         (i.e. the feed carries a static `address` instead).
    function readAssetFeedName(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _feedPath(vm, symbol, i, "feed");
        return vm.keyExists(json, p) ? json.readString(p) : "";
    }

    function _feedPath(Vm vm, string memory symbol, uint256 i, string memory field)
        private
        view
        returns (string memory)
    {
        return string(abi.encodePacked(".", symbol, ".priceFeeds[", vm.toString(i), "].", field));
    }

    // -------------------------------------------------------------------------
    // Misc helpers (unchanged)
    // -------------------------------------------------------------------------

    function computeSalt(string memory contractName, uint256 version) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(contractName, version));
    }

    function _parseSelectorHex4(Vm vm, string memory s) private view returns (bytes4) {
        bytes memory b = bytes(s);
        if (b.length != 10 || b[0] != "0" || (b[1] != "x" && b[1] != "X")) return bytes4(0);
        string memory padded =
            string.concat("0x", "00000000000000000000000000000000000000000000000000000000", _substring(s, 2, 10));
        bytes32 full = vm.parseBytes32(padded);
        return bytes4(uint32(uint256(full) & 0xffffffff));
    }

    function _substring(string memory str, uint256 start, uint256 end) private pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end && i < strBytes.length; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }

    function _resolveRpcUrl(Vm vm, string memory value, uint256 chainId) private view returns (string memory) {
        if (_equals(value, "$ALCHEMY")) {
            string memory network = _alchemyNetworkForChainId(chainId);
            if (bytes(network).length == 0) return "";
            string memory apiKey = vm.envOr("ALCHEMY_API_KEY", string(""));
            if (bytes(apiKey).length == 0) return "";
            return string.concat("https://", network, ".g.alchemy.com/v2/", apiKey);
        }
        return _resolveEnvVar(vm, value);
    }

    function _alchemyNetworkForChainId(uint256 chainId) private pure returns (string memory) {
        if (chainId == 1) return "eth-mainnet";
        if (chainId == 10) return "opt-mainnet";
        if (chainId == 56) return "bnb-mainnet";
        if (chainId == 100) return "gnosis-mainnet";
        if (chainId == 42161) return "arb-mainnet";
        if (chainId == 8453) return "base-mainnet";
        return "";
    }

    function _equals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _resolveEnvVar(Vm vm, string memory value) private view returns (string memory) {
        bytes memory valueBytes = bytes(value);
        if (valueBytes.length > 0 && valueBytes[0] == "$") {
            string memory varName = substring(value, 1, valueBytes.length);
            return vm.envOr(varName, string(""));
        }
        return value;
    }

    function substring(string memory str, uint256 startIndex, uint256 endIndex) private pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

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
            bool allZeros = true;
            for (uint256 i = 2; i < valueBytes.length && allZeros; i++) {
                if (valueBytes[i] != "0") allZeros = false;
            }
            if (allZeros) return true;
        }
        return false;
    }
}
