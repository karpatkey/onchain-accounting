// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IPrices} from "../../src/prices/IPrices.sol";

/// @title ConfigReader
/// @notice Utility for reading/parsing the NAV deployment configuration.
/// @dev Config is organized by concern, one JSON file per chain (top-level keys; the file *is* the chain). All
///      paths are under `script/config/`:
///      - `chains/<id>.json`                                          — chain meta + roles only (no adapter config).
///      - `contracts-deployment-config/custom-price-feeds/<id>.json`  — Custom feed adapters to DEPLOY: `.<name>.{enabled,constructor}`.
///      - `contracts-deployment-config/balance-adapters/<id>.json`    — PLAIN adapters to DEPLOY: `.<name>.{enabled,constructor}`.
///      - `contracts-deployment-config/meta-balance-adapters/<id>.json` — META adapters to DEPLOY: `.<name>.{enabled,constructor}`.
///      - `contracts-deployment-config/bridge-adapters/<id>.json`     — bridge adapters: `.<name>.{enabled,initialize,remoteChains}`.
///      - `contracts-deployment-config/bridge-escrow/<id>.json`       — BridgeEscrow post-deploy config: `.accounts[]` (authorizeAccount) + `.assets.<symbol>` (registerAsset).
///      - `nav-config/assets-and-price-feeds/<id>.json`               — assets to REGISTER: `.<SYMBOL>.{address,priceFeeds[]}`.
///      - `nav-config/balance-adapters/<id>.json`                     — PLAIN adapters to ADD on NAV: `.<name>.{enabled}`.
///      - `nav-config/meta-balance-adapters/<id>.json`                — META adapters to ADD: `.<name>.{enabled,instances|instancesRaw}`.
///      - `deployments/<id>.json`                                     — deployed addresses (state). Top-level for proxies/impls;
///                                                                      nested `.balanceAdapters/.customPriceFeeds/.bridgeAdapters.<name>`.
///      The `adapterType` token passed to the adapter readers selects the file: `deployBalanceAdapters` (alias
///      `balanceAdapters`, spans the plain + meta deploy folders), `deployMetaBalanceAdapters`, `deployPriceFeeds`
///      (alias `priceFeeds`/`customPriceFeeds`), `navBalanceAdapters`, `navMetaBalanceAdapters`, `bridgeAdapters`.
///      Deployments-file accessors still take the section token (`balanceAdapters`/`customPriceFeeds`/`bridgeAdapters`);
///      all deployed balance-adapter addresses (plain + meta) live under `.balanceAdapters`.
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
                "/script/config/contracts-deployment-config/custom-price-feeds/",
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

    function _deployMetaBalanceAdaptersPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/contracts-deployment-config/meta-balance-adapters/",
                vm.toString(chainId),
                ".json"
            )
        );
    }

    function _deployBridgeAdaptersPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/contracts-deployment-config/bridge-adapters/",
                vm.toString(chainId),
                ".json"
            )
        );
    }

    function _deployBridgeEscrowPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/contracts-deployment-config/bridge-escrow/",
                vm.toString(chainId),
                ".json"
            )
        );
    }

    function _deploymentsPath(Vm vm, uint256 chainId) private view returns (string memory) {
        return string(abi.encodePacked(vm.projectRoot(), "/script/config/deployments/", vm.toString(chainId), ".json"));
    }

    /// @dev Reads a file, returning "{}" if it is missing or empty (deployments files are created lazily).
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
        // The deploy-phase `admin`/`manager` (the deployer EOA; the security council becomes end-state admin via 07)
        // may be overridden at runtime via DEPLOY_ADMIN / DEPLOY_MANAGER. This lets a deploy be broadcast from a
        // different EOA (e.g. a fresh key for a clean bridge redeploy) WITHOUT rewriting the committed chain config —
        // and keeps the adapter `expectedInitializer` (== chainConfig.admin) aligned with the broadcasting key. When
        // the env vars are unset, the committed JSON values are used unchanged (no behavior change for normal runs).
        config.admin = _resolveRoleOverride(vm, "DEPLOY_ADMIN", json.readAddress(".addresses.admin"));
        config.manager = _resolveRoleOverride(vm, "DEPLOY_MANAGER", json.readAddress(".addresses.manager"));
    }

    /// @dev Returns the address in env var `envName` if set to a valid address, otherwise `fallbackAddr`.
    function _resolveRoleOverride(Vm vm, string memory envName, address fallbackAddr) private view returns (address) {
        return vm.envOr(envName, fallbackAddr);
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
    // Generic adapter readers (per-concern deploy/nav files; bridge adapters in
    // contracts-deployment-config/bridge-adapters/<id>.json)
    // -------------------------------------------------------------------------

    /// @dev Returns the file + jsonPath prefix for an adapter section. Each concern is its own per-chain file with
    ///      top-level keys (empty prefix). The token selects the file: `deployBalanceAdapters` (alias
    ///      `balanceAdapters`) and `deployMetaBalanceAdapters` (the deploy config, split plain vs meta the same way
    ///      nav-config is); `navBalanceAdapters`, `navMetaBalanceAdapters`, `deployPriceFeeds`
    ///      (aliases `priceFeeds`/`customPriceFeeds`), `bridgeAdapters`. An unrecognized token reverts.
    ///      NOTE: the `deployBalanceAdapters`/`balanceAdapters` token resolves across BOTH deploy folders (plain +
    ///      meta) via `_resolveAdapterFile`/`getEnabledAdapters`, so deploy scripts keep using one token; this helper
    ///      returns only the plain file (the union/fallback is layered on top).
    function _adapterFileAndPrefix(Vm vm, uint256 chainId, string memory adapterType)
        private
        view
        returns (string memory json, string memory prefix)
    {
        if (_equals(adapterType, "deployBalanceAdapters") || _equals(adapterType, "balanceAdapters")) {
            // "balanceAdapters" is the legacy alias for the deploy-config (plain) file. The NAV-registration side uses
            // the explicit navBalanceAdapters/navMetaBalanceAdapters tokens.
            json = _readOrEmpty(vm, _deployBalanceAdaptersPath(vm, chainId));
            prefix = "";
        } else if (_equals(adapterType, "deployMetaBalanceAdapters")) {
            json = _readOrEmpty(vm, _deployMetaBalanceAdaptersPath(vm, chainId));
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
        } else if (_equals(adapterType, "bridgeAdapters")) {
            // Bridge adapters (deploy/initialize args + enabled + remoteChains) live in their own per-chain file.
            json = _readOrEmpty(vm, _deployBridgeAdaptersPath(vm, chainId));
            prefix = "";
        } else {
            // Every adapter concern now has its own per-chain file; there is no chain-config fallback. Fail fast on an
            // unrecognized token rather than silently reading an empty/wrong file (which would resolve to absent/false).
            revert(string(abi.encodePacked("ConfigReader: unknown adapterType '", adapterType, "'")));
        }
    }

    /// @dev The parseJsonKeys path for an adapter container: root ("$") for top-level per-chain files, else the prefix.
    function _containerPath(string memory prefix) private pure returns (string memory) {
        return bytes(prefix).length == 0 ? "$" : prefix;
    }

    /// @dev The deploy-balance token spans BOTH deploy-config folders (plain + meta). Deploy scripts read enabled +
    ///      constructor args via this one token regardless of whether an adapter is plain or meta.
    function _isDeployBalanceToken(string memory adapterType) private pure returns (bool) {
        return _equals(adapterType, "deployBalanceAdapters") || _equals(adapterType, "balanceAdapters");
    }

    /// @dev Resolves the deploy-config file holding `adapterName`: the plain file, or — for the deploy-balance token,
    ///      when the name is absent from the plain file — the meta deploy file (the two are disjoint). Other tokens
    ///      resolve to their single file unchanged.
    function _resolveAdapterFile(Vm vm, uint256 chainId, string memory adapterType, string memory adapterName)
        private
        view
        returns (string memory json, string memory prefix)
    {
        (json, prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);
        if (_isDeployBalanceToken(adapterType) && !vm.keyExists(json, string(abi.encodePacked(".", adapterName)))) {
            string memory metaJson = _readOrEmpty(vm, _deployMetaBalanceAdaptersPath(vm, chainId));
            if (vm.keyExists(metaJson, string(abi.encodePacked(".", adapterName)))) json = metaJson;
        }
    }

    /// @dev Collects the non-`$` keys of an adapter container into `names`.
    function _namesIn(Vm vm, string memory json) private view returns (string[] memory names) {
        if (!vm.keyExists(json, "$")) return new string[](0);
        string[] memory allKeys = vm.parseJsonKeys(json, "$");
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

    /// @notice Returns every adapter name under a section (excludes `$`-prefixed metadata keys). Does NOT filter by
    ///         `enabled` — call `isAdapterEnabled` per key for that. The deploy-balance token returns the union of the
    ///         plain + meta deploy-config folders.
    function getEnabledAdapters(Vm vm, uint256 chainId, string memory adapterType)
        internal
        view
        returns (string[] memory names)
    {
        (string memory json, string memory prefix) = _adapterFileAndPrefix(vm, chainId, adapterType);
        // Nested-prefix sections (none today — every concern is a top-level per-chain file, incl. bridge): use
        // parseJsonKeys on the prefix path.
        if (bytes(prefix).length != 0) {
            string memory jsonPath = _containerPath(prefix);
            if (!vm.keyExists(json, jsonPath)) return new string[](0);
            return _filterDollar(vm.parseJsonKeys(json, jsonPath));
        }
        names = _namesIn(vm, json);
        if (_isDeployBalanceToken(adapterType)) {
            // Union with the meta deploy folder (disjoint keys, so a plain concat is dedup-free).
            string[] memory metaNames = _namesIn(vm, _readOrEmpty(vm, _deployMetaBalanceAdaptersPath(vm, chainId)));
            string[] memory merged = new string[](names.length + metaNames.length);
            uint256 k;
            for (uint256 i; i < names.length; ++i) {
                merged[k++] = names[i];
            }
            for (uint256 i; i < metaNames.length; ++i) {
                merged[k++] = metaNames[i];
            }
            names = merged;
        }
    }

    /// @dev Filters `$`-prefixed metadata keys from a key list.
    function _filterDollar(string[] memory keys) private pure returns (string[] memory out) {
        uint256 count;
        for (uint256 i; i < keys.length; ++i) {
            if (bytes(keys[i]).length > 0 && bytes(keys[i])[0] != "$") ++count;
        }
        out = new string[](count);
        uint256 j;
        for (uint256 i; i < keys.length; ++i) {
            if (bytes(keys[i]).length > 0 && bytes(keys[i])[0] != "$") out[j++] = keys[i];
        }
    }

    /// @notice Whether an adapter is enabled in its config file (selected by `adapterType`). For the deploy-balance
    ///         token this resolves across both the plain and meta deploy-config folders.
    function isAdapterEnabled(Vm vm, uint256 chainId, string memory adapterType, string memory adapterName)
        internal
        view
        returns (bool)
    {
        (string memory json, string memory prefix) = _resolveAdapterFile(vm, chainId, adapterType, adapterName);
        string memory jsonPath = string(abi.encodePacked(prefix, ".", adapterName, ".enabled"));
        if (vm.keyExists(json, jsonPath)) return json.readBool(jsonPath);
        return false;
    }

    /// @notice Reads an adapter constructor/initialize/bare param from the file selected by `adapterType`
    ///         (see `_adapterFileAndPrefix`; deploy-balance spans both plain + meta folders). "" if absent.
    function readAdapterParam(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        string memory paramName
    ) internal view returns (string memory) {
        (string memory json, string memory prefix) = _resolveAdapterFile(vm, chainId, adapterType, adapterName);

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

    /// @notice Reads a uint-array adapter param (e.g. a bridge adapter's `remoteChains`). Empty if absent.
    /// @dev Accepts the array authored either as JSON numbers (`[1, 10]`) or quoted numeric strings (`["1","10"]`).
    function readAdapterUintArray(
        Vm vm,
        uint256 chainId,
        string memory adapterType,
        string memory adapterName,
        string memory paramName
    ) internal view returns (uint256[] memory) {
        (string memory json, string memory prefix) = _resolveAdapterFile(vm, chainId, adapterType, adapterName);
        string memory base = string(abi.encodePacked(prefix, ".", adapterName));
        string memory p = string(abi.encodePacked(base, ".", paramName));
        if (vm.keyExists(json, p)) return _parseUintArray(vm, json, p);
        p = string(abi.encodePacked(base, ".initialize.", paramName));
        if (vm.keyExists(json, p)) return _parseUintArray(vm, json, p);
        p = string(abi.encodePacked(base, ".constructor.", paramName));
        if (vm.keyExists(json, p)) return _parseUintArray(vm, json, p);
        return new uint256[](0);
    }

    /// @dev Parses a JSON uint array at `p`, tolerating both numeric (`[1,10]`) and quoted (`["1","10"]`) forms.
    function _parseUintArray(Vm vm, string memory json, string memory p) private view returns (uint256[] memory) {
        try vm.parseJsonUintArray(json, p) returns (uint256[] memory nums) {
            return nums;
        } catch {
            string[] memory strs = vm.parseJsonStringArray(json, p);
            uint256[] memory out = new uint256[](strs.length);
            for (uint256 i = 0; i < strs.length; i++) {
                out[i] = vm.parseUint(strs[i]);
            }
            return out;
        }
    }

    // -------------------------------------------------------------------------
    // Custom price feeds (contracts-deployment-config/custom-price-feeds/<id>.json → .<name>)
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
    function getAssetSymbols(Vm vm, uint256 chainId) internal view returns (string[] memory symbols) {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        if (!vm.keyExists(json, "$")) return new string[](0);
        string[] memory all = vm.parseJsonKeys(json, "$");
        // Skip `$`-prefixed metadata keys (e.g. `$comment`/`$schema`), matching getEnabledAdapters — they are not assets.
        uint256 count;
        for (uint256 i; i < all.length; ++i) {
            if (bytes(all[i]).length > 0 && bytes(all[i])[0] != "$") ++count;
        }
        symbols = new string[](count);
        uint256 j;
        for (uint256 i; i < all.length; ++i) {
            if (bytes(all[i]).length > 0 && bytes(all[i])[0] != "$") symbols[j++] = all[i];
        }
    }

    /// @notice Maps feed `i`'s config `type` string to the on-chain PriceType enum. `valid` is false for an empty or
    ///         unrecognized type. Single source of truth shared by RegisterAssets (production) and the fork harness so
    ///         the two cannot disagree on which type strings are recognized.
    function readAssetFeedPriceType(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (IPrices.PriceType pt, bool valid)
    {
        return _priceTypeFromString(readAssetFeedType(vm, chainId, symbol, i));
    }

    /// @notice Shared `type` string → PriceType mapping. `valid` is false for an empty/unrecognized type.
    function _priceTypeFromString(string memory t) private pure returns (IPrices.PriceType pt, bool valid) {
        if (_equals(t, "Chainlink")) return (IPrices.PriceType.Chainlink, true);
        if (_equals(t, "Custom")) return (IPrices.PriceType.Custom, true);
        if (_equals(t, "Redstone")) return (IPrices.PriceType.Redstone, true);
        if (_equals(t, "API3")) return (IPrices.PriceType.API3, true);
        return (IPrices.PriceType.Chainlink, false);
    }

    /// @notice Reads an asset's token address ("" if absent).
    function readAssetAddress(Vm vm, uint256 chainId, string memory symbol) internal view returns (string memory) {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory jsonPath = string(abi.encodePacked(".", symbol, ".address"));
        if (vm.keyExists(json, jsonPath)) return json.readString(jsonPath);
        return "";
    }

    // -------------------------------------------------------------------------
    // BridgeEscrow post-deploy config (contracts-deployment-config/bridge-escrow/<id>.json)
    // `.accounts` = addresses to authorize (authorizeAccount); `.assets` = logical bridge symbol -> local
    // token address (registerAsset). Both empty/absent → the reader returns an empty result (no-op step).
    // -------------------------------------------------------------------------

    /// @notice Addresses to authorize on BridgeEscrow (`.accounts`). Empty if the file or key is absent.
    function readBridgeEscrowAccounts(Vm vm, uint256 chainId) internal view returns (address[] memory) {
        string memory json = _readOrEmpty(vm, _deployBridgeEscrowPath(vm, chainId));
        if (vm.keyExists(json, ".accounts")) return vm.parseJsonAddressArray(json, ".accounts");
        return new address[](0);
    }

    /// @notice Logical bridge-asset symbols to register (the keys of `.assets`, excluding `$`-metadata). Empty if absent.
    function readBridgeEscrowAssetSymbols(Vm vm, uint256 chainId) internal view returns (string[] memory) {
        string memory json = _readOrEmpty(vm, _deployBridgeEscrowPath(vm, chainId));
        if (!vm.keyExists(json, ".assets")) return new string[](0);
        return _filterDollar(vm.parseJsonKeys(json, ".assets"));
    }

    /// @notice Local token address for a logical bridge symbol (`.assets.<symbol>`). Zero if absent/placeholder.
    function readBridgeEscrowAssetAddress(Vm vm, uint256 chainId, string memory symbol)
        internal
        view
        returns (address)
    {
        string memory json = _readOrEmpty(vm, _deployBridgeEscrowPath(vm, chainId));
        return _readAddrOrZero(vm, json, string(abi.encodePacked(".assets.", symbol)));
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

    /// @notice Reads feed `i`'s heartbeat (seconds, as string). Defaults to "3600" if absent. Accepts the heartbeat
    ///         written either as a JSON number (`3600`) or a quoted string (`"3600"`) — other deploy-config files use
    ///         quoted numeric strings, so tolerating both avoids a whole-run revert on a string-typed heartbeat.
    function readAssetFeedHeartbeat(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _feedPath(vm, symbol, i, "heartbeat");
        if (!vm.keyExists(json, p)) return "3600";
        // Numeric form first; fall back to reading it as a string if the value was authored quoted.
        try vm.parseJsonUint(json, p) returns (uint256 v) {
            return vm.toString(v);
        } catch {
            return json.readString(p);
        }
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
    // Monitor feeds + divergence/peg tolerances (assets-and-price-feeds)
    // -------------------------------------------------------------------------

    /// @notice Number of monitor (divergence-only) feeds configured for an asset (length of its `monitorFeeds[]`).
    function assetMonitorFeedCount(Vm vm, uint256 chainId, string memory symbol) internal view returns (uint256 n) {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        while (vm.keyExists(json, _monitorPath(vm, symbol, n, "type"))) {
            ++n;
        }
    }

    /// @notice Reads monitor feed `i`'s type string ("" if absent).
    function readAssetMonitorFeedType(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _monitorPath(vm, symbol, i, "type");
        return vm.keyExists(json, p) ? json.readString(p) : "";
    }

    /// @notice Maps monitor feed `i`'s type to the on-chain PriceType enum (shares the priceFeeds mapping table).
    function readAssetMonitorFeedPriceType(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (IPrices.PriceType pt, bool valid)
    {
        return _priceTypeFromString(readAssetMonitorFeedType(vm, chainId, symbol, i));
    }

    /// @notice Reads monitor feed `i`'s heartbeat (seconds, as string; default "3600"). Accepts number or quoted.
    function readAssetMonitorFeedHeartbeat(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _monitorPath(vm, symbol, i, "heartbeat");
        if (!vm.keyExists(json, p)) return "3600";
        try vm.parseJsonUint(json, p) returns (uint256 v) {
            return vm.toString(v);
        } catch {
            return json.readString(p);
        }
    }

    /// @notice Resolves monitor feed `i`'s on-chain address (static `address`, or a `Custom` feed resolved from
    ///         `deployments/<id>.json .customPriceFeeds.<feed>`). "" if unresolved.
    function readAssetMonitorFeedAddress(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory addrPath = _monitorPath(vm, symbol, i, "address");
        if (vm.keyExists(json, addrPath)) return json.readString(addrPath);
        string memory feedPath = _monitorPath(vm, symbol, i, "feed");
        if (vm.keyExists(json, feedPath)) {
            address dep = readDeployedAdapterAddress(vm, chainId, "customPriceFeeds", json.readString(feedPath));
            if (dep != address(0)) return vm.toString(dep);
        }
        return "";
    }

    /// @notice Reads monitor feed `i`'s Custom-feed name (the `feed` field). "" if absent (static `address` form).
    function readAssetMonitorFeedName(Vm vm, uint256 chainId, string memory symbol, uint256 i)
        internal
        view
        returns (string memory)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = _monitorPath(vm, symbol, i, "feed");
        return vm.keyExists(json, p) ? json.readString(p) : "";
    }

    /// @notice Reads an asset's `divergenceToleranceBps` (0 if absent).
    function readAssetDivergenceToleranceBps(Vm vm, uint256 chainId, string memory symbol)
        internal
        view
        returns (uint256)
    {
        return _readUintOrZero(vm, chainId, symbol, "divergenceToleranceBps");
    }

    /// @notice Reads an asset's `pegToleranceBps` (0 if absent → peg guard disabled).
    function readAssetPegToleranceBps(Vm vm, uint256 chainId, string memory symbol) internal view returns (uint256) {
        return _readUintOrZero(vm, chainId, symbol, "pegToleranceBps");
    }

    function _readUintOrZero(Vm vm, uint256 chainId, string memory symbol, string memory field)
        private
        view
        returns (uint256)
    {
        string memory json = _readOrEmpty(vm, _navAssetsPath(vm, chainId));
        string memory p = string(abi.encodePacked(".", symbol, ".", field));
        if (!vm.keyExists(json, p)) return 0;
        try vm.parseJsonUint(json, p) returns (uint256 v) {
            return v;
        } catch {
            return vm.parseUint(json.readString(p));
        }
    }

    function _monitorPath(Vm vm, string memory symbol, uint256 i, string memory field)
        private
        view
        returns (string memory)
    {
        return string(abi.encodePacked(".", symbol, ".monitorFeeds[", vm.toString(i), "].", field));
    }

    // -------------------------------------------------------------------------
    // Misc helpers (unchanged)
    // -------------------------------------------------------------------------

    function computeSalt(string memory contractName, uint256 version) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(contractName, version));
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
        if (chainId == 137) return "polygon-mainnet";
        if (chainId == 1101) return "polygonzkevm-mainnet";
        if (chainId == 80094) return "berachain-mainnet";
        if (chainId == 999) return "hyperliquid-mainnet";
        if (chainId == 57073) return "ink-mainnet";
        if (chainId == 59144) return "linea-mainnet";
        if (chainId == 204) return "opbnb-mainnet";
        if (chainId == 146) return "sonic-mainnet";
        if (chainId == 130) return "unichain-mainnet";
        if (chainId == 534352) return "scroll-mainnet";
        if (chainId == 196) return "xlayer-mainnet";
        if (chainId == 42220) return "celo-mainnet";
        if (chainId == 43114) return "avax-mainnet";
        if (chainId == 5000) return "mantle-mainnet";
        if (chainId == 480) return "worldchain-mainnet";
        if (chainId == 143) return "monad-mainnet";
        if (chainId == 9745) return "plasma-mainnet";
        // Hemi (43111) and 0G (16661) are not on Alchemy; their chain configs set
        // rpc to "$QUICKNODE_HEMI" / "$QUICKNODE_0G", resolved directly via _resolveEnvVar.
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
