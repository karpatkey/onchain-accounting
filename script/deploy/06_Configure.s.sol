// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {IBalances} from "../../src/balances/IBalances.sol";
import {IBridgeEscrow} from "../../src/bridge/IBridgeEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title Configure
/// @notice Post-deployment configuration for NAVCalculator and BridgeEscrow, broadcast directly by the deployer EOA.
/// @dev EOA flow (no Safe): the caller must hold DEFAULT_ADMIN_ROLE + MANAGER on the proxies (granted by the atomic
///      deployer in 02 when chainConfig.admin == chainConfig.manager == the deployer EOA). For each enabled+deployed
///      balance adapter it calls `addBalanceAdapters` (idempotent) and, for meta-adapters (ADR 0010), `addMetaInstances`/`removeMetaInstances`
///      with the configured instance set; for each enabled+deployed bridge adapter it authorizes it on BridgeEscrow.
///      Idempotent: skips adapters already registered and adapters already authorized, so it can be re-run safely.
///      Run with: forge script script/deploy/06_Configure.s.sol --rpc-url $RPC_URL --account $DEPLOYER_NAME --broadcast
contract Configure is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Post-Deployment Configuration (EOA broadcast) ===");

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");

        if (navProxy == address(0)) {
            console2.log("WARNING: NAVCalculator not deployed, skipping NAV configuration");
        }
        if (bridgeProxy == address(0)) {
            console2.log("WARNING: BridgeEscrow not deployed, skipping Bridge configuration");
        }
        if (navProxy == address(0) && bridgeProxy == address(0)) {
            console2.log("ERROR: No contracts deployed to configure!");
            return;
        }
        if (navProxy != address(0)) {
            require(navProxy.code.length > 0, "No code at NAVCalculator proxy. Provide --rpc-url.");
        }
        if (bridgeProxy != address(0)) {
            require(bridgeProxy.code.length > 0, "No code at BridgeEscrow proxy. Provide --rpc-url.");
        }

        vm.startBroadcast();
        if (navProxy != address(0)) {
            _ensureManager(navProxy);
            _configureBalanceAdapters(navProxy);
        }
        if (bridgeProxy != address(0)) {
            _authorizeBridgeAdapters(bridgeProxy);
        }
        vm.stopBroadcast();

        console2.log("\n=== Configuration complete ===");
    }

    /// @notice Idempotently ensures `chainConfig.manager` holds MANAGER (covers the legacy 02 path that doesn't grant
    ///         it; the atomic path already did). Requires the caller to hold DEFAULT_ADMIN_ROLE.
    function _ensureManager(address navProxy) internal {
        address manager = chainConfig.manager;
        if (manager == address(0)) return;
        if (!IAccessControl(navProxy).hasRole(MANAGER, manager)) {
            IAccessControl(navProxy).grantRole(MANAGER, manager);
            console2.log("[OK] Granted MANAGER to:", manager);
        }
    }

    /// @notice Registers balance adapters on NAVCalculator (idempotent), driven by the explicit NAV-config files:
    ///         PLAIN adapters from `nav-config/balance-adapters/<id>.json` (→ addBalanceAdapters) and META adapters
    ///         from `nav-config/meta-balance-adapters/<id>.json` (→ addMetaBalanceAdapter + instance reconcile, ADR
    ///         0010). The split is config-driven; the on-chain contracts still enforce it (addBalanceAdapters reverts
    ///         MetaAdapterNotAllowed for a meta-adapter, addMetaBalanceAdapter reverts NotMetaAdapter for a plain one).
    function _configureBalanceAdapters(address navProxy) internal {
        uint256 added;
        uint256 configured;

        // PLAIN balance adapters → addBalanceAdapters.
        string[] memory plain = ConfigReader.getEnabledAdapters(vm, currentChainId, "navBalanceAdapters");
        for (uint256 i = 0; i < plain.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "navBalanceAdapters", plain[i])) continue;
            address deployed = _readAdapterDeployed("balanceAdapters", plain[i]);
            if (deployed == address(0)) continue;
            if (IBalances(navProxy).isAdapterRegistered(deployed)) {
                console2.log("[SKIP] Already registered:", plain[i], deployed);
                continue;
            }
            address[] memory one = new address[](1);
            one[0] = deployed;
            (bool ok, bytes memory data) = navProxy.call(abi.encodeWithSignature("addBalanceAdapters(address[])", one));
            if (!ok) {
                revert(string(abi.encodePacked("addBalanceAdapters failed for ", plain[i], ": ", _decodeRevert(data))));
            }
            console2.log("[OK] Added balance adapter:", plain[i], deployed);
            added++;
        }

        // META balance adapters → addMetaBalanceAdapter (atomic register + seed), then reconcile the instance set.
        string[] memory meta = ConfigReader.getEnabledAdapters(vm, currentChainId, "navMetaBalanceAdapters");
        for (uint256 i = 0; i < meta.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "navMetaBalanceAdapters", meta[i])) continue;
            address deployed = _readAdapterDeployed("balanceAdapters", meta[i]);
            if (deployed == address(0)) continue;

            bytes32[] memory desired = _readMetaInstances(meta[i]);
            if (!IBalances(navProxy).isAdapterRegistered(deployed)) {
                (bool ok, bytes memory data) = navProxy.call(
                    abi.encodeWithSignature("addMetaBalanceAdapter(address,bytes32[])", deployed, desired)
                );
                if (!ok) {
                    revert(
                        string(
                            abi.encodePacked("addMetaBalanceAdapter failed for ", meta[i], ": ", _decodeRevert(data))
                        )
                    );
                }
                console2.log("[OK] Added meta balance adapter:", meta[i], deployed);
                added++;
            } else {
                console2.log("[SKIP] Already registered:", meta[i], deployed);
            }

            // Reconcile the on-chain set to the configured set. addMetaInstances / removeMetaInstances are incremental
            // and all-or-nothing, so we diff against the current set (rather than blindly add) to stay idempotent
            // across re-runs. For an adapter just registered via addMetaBalanceAdapter the set is already seeded, so
            // the diff below is a no-op.
            bytes32[] memory current = IBalances(navProxy).getMetaInstances(deployed);
            bytes32[] memory toRemove = _metaDiff(current, desired);
            bytes32[] memory toAdd = _metaDiff(desired, current);

            if (toRemove.length > 0) {
                (bool ok, bytes memory data) =
                    navProxy.call(abi.encodeWithSignature("removeMetaInstances(address,bytes32[])", deployed, toRemove));
                if (!ok) {
                    revert(
                        string(abi.encodePacked("removeMetaInstances failed for ", meta[i], ": ", _decodeRevert(data)))
                    );
                }
            }
            if (toAdd.length > 0) {
                (bool ok, bytes memory data) =
                    navProxy.call(abi.encodeWithSignature("addMetaInstances(address,bytes32[])", deployed, toAdd));
                if (!ok) {
                    revert(string(abi.encodePacked("addMetaInstances failed for ", meta[i], ": ", _decodeRevert(data))));
                }
            }
            if (toAdd.length > 0 || toRemove.length > 0) {
                console2.log("[OK] Reconciled meta instances for:", meta[i], desired.length);
                configured++;
            }
        }
        console2.log("--- Balance adapters: added", added, "; meta sets configured", configured);
    }

    /// @notice Returns the coordinates in `a` that are not present in `b` (set difference a \ b).
    function _metaDiff(bytes32[] memory a, bytes32[] memory b) private pure returns (bytes32[] memory diff) {
        bytes32[] memory tmp = new bytes32[](a.length);
        uint256 count;
        for (uint256 i = 0; i < a.length; i++) {
            bool found;
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i] == b[j]) {
                    found = true;
                    break;
                }
            }
            if (!found) tmp[count++] = a[i];
        }
        diff = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            diff[i] = tmp[i];
        }
    }

    /// @notice Authorizes each enabled+deployed bridge adapter on BridgeEscrow (idempotent via isAuthorizedAdapter),
    ///         then wires its `trustedRemoteAdapter` allowlist (ADR 0012, D2 + D7).
    /// @dev The escrow fallback dispatcher was removed (ADR 0012 D1), so there is no `authorizeAdapterWithCallback`
    ///      anymore — plain `authorizeAdapter(address)` is the only authorization call. After authorizing, each
    ///      adapter's per-source-chain trusted sibling is set: with CREATE2 same-address (D7) the sibling adapter on
    ///      every remote chain has the SAME address as this one, so `remote = bytes32(uint256(uint160(adapter)))`.
    function _authorizeBridgeAdapters(address bridgeProxy) internal {
        string[] memory adapterNames = _bridgeAdapterNames();
        uint256 authorized;
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", adapterNames[i])) continue;

            address deployed = _readAdapterDeployed("bridgeAdapters", adapterNames[i]);
            if (deployed == address(0)) continue;

            if (IBridgeEscrow(bridgeProxy).isAuthorizedAdapter(deployed)) {
                console2.log("[SKIP] Bridge adapter already authorized:", adapterNames[i], deployed);
            } else {
                (bool ok, bytes memory data) =
                    bridgeProxy.call(abi.encodeWithSignature("authorizeAdapter(address)", deployed));
                if (!ok) {
                    revert(
                        string(
                            abi.encodePacked(
                                "authorize bridge adapter failed for ", adapterNames[i], ": ", _decodeRevert(data)
                            )
                        )
                    );
                }
                console2.log("[OK] Authorized bridge adapter:", adapterNames[i], deployed);
                authorized++;
            }

            _wireTrustedRemoteAdapters(adapterNames[i], deployed);
        }
        console2.log("--- Bridge adapters authorized:", authorized);
    }

    /// @notice Sets `setTrustedRemoteAdapter(sourceKey, remote)` on `adapter` for each configured remote chain
    ///         (ADR 0012, D2 + D7).
    /// @dev sourceKey: every adapter (CCIP, Across, Stargate, Gnosis, CCTP, Superchain) keys its
    ///      `trustedRemoteAdapter` mapping by the remote chain's STANDARD chain id — the adapters translate
    ///      protocol-specific source identifiers (CCIP selector, LayerZero eid, CCTP domain, AMB/OP xDomain source)
    ///      back to the standard chain id internally before the lookup, so the config-driven key is the plain chain
    ///      id. remote: with CREATE2 same-address (D7) the sibling adapter on every remote chain shares this
    ///      adapter's address, so the trusted remote identity is `bytes32(uint256(uint160(adapter)))`.
    ///      Idempotent: re-runs simply re-set the same value. The remote-chain list is read from the adapter's
    ///      `remoteChains` array in `contracts-deployment-config/bridge-adapters/<chainId>.json`.
    function _wireTrustedRemoteAdapters(string memory adapterName, address adapter) internal {
        uint256[] memory remoteChains =
            ConfigReader.readAdapterUintArray(vm, currentChainId, "bridgeAdapters", adapterName, "remoteChains");
        if (remoteChains.length == 0) {
            console2.log("[WARN] No remoteChains configured for adapter; trustedRemoteAdapter left unset:", adapterName);
            return;
        }

        // CREATE2 same-address: the trusted sibling on every remote chain is this adapter's own address.
        bytes32 remote = bytes32(uint256(uint160(adapter)));

        for (uint256 i = 0; i < remoteChains.length; i++) {
            uint256 remoteChainId = remoteChains[i];
            if (remoteChainId == 0 || remoteChainId == currentChainId) continue; // skip self / invalid
            (bool ok, bytes memory data) = adapter.call(
                abi.encodeWithSignature("setTrustedRemoteAdapter(uint64,bytes32)", uint64(remoteChainId), remote)
            );
            if (!ok) {
                revert(
                    string(
                        abi.encodePacked(
                            "setTrustedRemoteAdapter failed for ",
                            adapterName,
                            " sourceKey ",
                            vm.toString(remoteChainId),
                            ": ",
                            _decodeRevert(data)
                        )
                    )
                );
            }
            console2.log("[OK] trustedRemoteAdapter set:", adapterName, remoteChainId);
        }
    }

    /// @notice Bridge adapter name list — kept in sync with `05_DeployBridgeAdapters.s.sol`.
    function _bridgeAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](6);
        names[0] = "CCIP";
        names[1] = "Across";
        names[2] = "Stargate";
        names[3] = "Gnosis";
        names[4] = "CCTP";
        names[5] = "Superchain";
    }

    /// @notice Reads a meta-adapter's configured instance coordinates from config: `metaInstances` (address list,
    ///         widened to bytes32 — for vault/pool-address adapters) unioned with `metaInstancesRaw` (raw bytes32
    ///         list — for marketId-keyed adapters like MorphoMarketsMeta). An adapter uses one or the other.
    /// @return instances The instance coordinates (empty for non-meta adapters or when unset).
    function _readMetaInstances(string memory adapterName) internal view returns (bytes32[] memory instances) {
        address[] memory addrs = ConfigReader.readAdapterAddressArray(
            vm, currentChainId, "navMetaBalanceAdapters", adapterName, "instances"
        );
        bytes32[] memory raw = ConfigReader.readAdapterBytes32Array(
            vm, currentChainId, "navMetaBalanceAdapters", adapterName, "instancesRaw"
        );

        // The configured coordinates must be unique across `metaInstances` (addresses, widened) ∪ `metaInstancesRaw`
        // (raw bytes32). addMetaInstances is all-or-nothing and reverts DuplicateMetaInstance, so a duplicated
        // config entry surfaces as a clear, per-adapter reconcile failure ("addMetaInstances failed for <name>:
        // DuplicateMetaInstance") that must be corrected in config — it is a config error, not a transient. We do
        // NOT de-duplicate in-script: NAVCalculator runs near the EIP-170 limit and, under via-IR whole-program
        // optimization, adding the dedup loop here measurably grows NAVCalculator's own runtime bytecode past
        // 24,576 (see the EIP-170 note on the NAVCalculator contract).
        instances = new bytes32[](addrs.length + raw.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            instances[i] = bytes32(uint256(uint160(addrs[i])));
        }
        for (uint256 i = 0; i < raw.length; i++) {
            instances[addrs.length + i] = raw[i];
        }
    }

    /// @notice Helper to read a deployed adapter address (from the deployments state file).
    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        return ConfigReader.readDeployedAdapterAddress(vm, currentChainId, adapterType, adapterName);
    }

    /// @notice Decodes a standard Error(string) revert payload for readable failure messages.
    function _decodeRevert(bytes memory data) internal pure returns (string memory) {
        if (data.length >= 68 && data[0] == 0x08 && data[1] == 0xc3 && data[2] == 0x79 && data[3] == 0xa0) {
            uint256 len;
            assembly {
                len := mload(add(add(data, 32), 36))
            }
            if (data.length >= 68 + 32 + len) {
                bytes memory msgBytes = new bytes(len);
                for (uint256 i = 0; i < len; i++) {
                    msgBytes[i] = data[i + 68 + 32];
                }
                return string(msgBytes);
            }
        }
        return data.length > 0 ? "custom error (non-string revert)" : "unknown";
    }
}
