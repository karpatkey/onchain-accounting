// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {CcipBridgeAdapter} from "../../src/bridge/adapters/CcipBridgeAdapter.sol";
import {AcrossBridgeAdapter} from "../../src/bridge/adapters/AcrossBridgeAdapter.sol";
import {StargateBridgeAdapter} from "../../src/bridge/adapters/StargateBridgeAdapter.sol";
import {CctpBridgeAdapter} from "../../src/bridge/adapters/CctpBridgeAdapter.sol";
import {GnosisBridgeAdapter} from "../../src/bridge/adapters/GnosisBridgeAdapter.sol";
import {SuperchainBridgeAdapter} from "../../src/bridge/adapters/SuperchainBridgeAdapter.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployBridgeAdapters
/// @notice Deploys the six bridge adapters for BridgeEscrow via the canonical CREATE2 deployer (ADR 0012, D7).
/// @dev CREATE2 same-address (D7): each adapter is deployed deterministically so its address is IDENTICAL on every
///      target chain. Adapters take their args via `initialize(...)` rather than constructor args, so their creation
///      bytecode carries no per-chain data and the pinned salt (from `DeploySalts`) yields the same address
///      everywhere. After each CREATE2 deploy this script ASSERTS the on-chain address equals the predicted address
///      and reverts otherwise. The same-address guarantee is what `trustedRemoteAdapter` (wired in 06), the CCTP
///      `mintRecipient`/`destinationCaller`, and the Superchain `receiver` rely on.
///
///      EOA flow (unchanged): everything is broadcast from the deployer EOA. The CREATE2 deploy goes through the
///      canonical deployer (0x4e59...) with calldata = salt || creationCode (Arachnid format); `initialize(...)` is
///      then a normal EOA call. Idempotent: a re-run skips an adapter that already has code at its deterministic
///      address. Addresses saved to deployments under `bridgeAdapters.<Name>`.
contract DeployBridgeAdapters is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer address (same on all chains): 0x4e59b44847b379578588920cA78FbF26c0B4956C
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public override {
        setUp();

        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        if (bridgeProxy == address(0)) {
            bridgeProxy = readDeployedAddress("BridgeEscrowProxyWithInit");
        }
        require(bridgeProxy != address(0), "BridgeEscrow proxy not in config. Deploy 02_DeployProxies.s.sol first.");
        require(chainConfig.admin != address(0), "Admin not configured.");

        console2.log("\n=== Deploying Bridge Adapters (CREATE2 same-address, ADR 0012 D7) ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("BridgeEscrow:", bridgeProxy);
        console2.log("Admin:", chainConfig.admin);
        console2.log("");

        // Every adapter is enable-gated in config; deploy each enabled one deterministically. The set is identical
        // across chains, so the per-chain branching of the old flow is gone — config `enabled` is the only gate.
        vm.startBroadcast();

        // Each adapter's initialize is pinned to expectedInitializer (= chainConfig.admin, baked into the
        // creationCode by _adapterInitCode). If the broadcasting key is not that exact address, every
        // initialize() would revert NotAuthorized mid-deploy — fail fast here with a clear message. (The
        // baked value must also be byte-identical across chains or the CREATE2 same-address guarantee breaks.)
        (, address broadcaster,) = vm.readCallers();
        require(
            broadcaster == _expectedInitializer(),
            "05: broadcaster must equal chainConfig.admin (the pinned expectedInitializer)"
        );

        _deployCcipIfConfigured(bridgeProxy);
        _deployAcrossIfConfigured(bridgeProxy);
        _deployStargateIfConfigured(bridgeProxy);
        _deployGnosisIfConfigured(bridgeProxy);
        _deployCctpIfConfigured(bridgeProxy);
        _deploySuperchainIfConfigured(bridgeProxy);
        vm.stopBroadcast();

        console2.log("\n=== Next Steps ===");
        console2.log("1. Set bridgeAdapters.<Name>.enabled to true in chain config if needed");
        console2.log("2. Run 06_Configure.s.sol to authorize adapters + wire trustedRemoteAdapter");
        console2.log("====================");
    }

    //
    // CREATE2 deploy helper
    //

    /// @notice Deterministically deploys `creationCode` via the canonical CREATE2 deployer under `salt`, ASSERTS the
    ///         resulting address equals the predicted address, and returns it. Idempotent: if code already exists at
    ///         the predicted address it is returned unchanged (no re-deploy, no re-initialize by the caller).
    /// @return adapter The deterministic adapter address (same on every chain).
    /// @return freshlyDeployed True if this call deployed the contract (so the caller must initialize it).
    function _create2Deploy(string memory name, bytes32 salt, bytes memory creationCode)
        internal
        returns (address adapter, bool freshlyDeployed)
    {
        adapter = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, salt, creationCode);
        if (adapter.code.length > 0) {
            console2.log(string(abi.encodePacked("[SKIP] ", name, " already at:")), adapter);
            return (adapter, false);
        }
        (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode));
        require(ok, string(abi.encodePacked(name, ": CREATE2 deploy failed")));
        // Assert the deployment landed at the predicted deterministic address (ADR 0012 D7 same-address guarantee).
        require(
            adapter.code.length > 0,
            string(abi.encodePacked(name, ": no code at predicted CREATE2 address after deploy"))
        );
        console2.log(string(abi.encodePacked("[OK] ", name, " deployed at:")), adapter);
        freshlyDeployed = true;
    }

    /// @notice The address permitted to call each adapter's initialize, baked into the adapter's creationCode
    ///         so the deploy->initialize window cannot be front-run (see BridgeAdapter.expectedInitializer). It
    ///         MUST equal the EOA that broadcasts initialize (the deployer = chainConfig.admin in the EOA flow)
    ///         AND be byte-identical on every chain, or the CREATE2 same-address guarantee breaks.
    function _expectedInitializer() internal view returns (address) {
        require(chainConfig.admin != address(0), "expectedInitializer (admin) not configured");
        return chainConfig.admin;
    }

    /// @notice Appends the expectedInitializer constructor arg to an adapter's creationCode (mirrors the
    ///         BridgeAdapter constructor). Identical across chains so the deterministic address is preserved.
    function _adapterInitCode(bytes memory creationCode) internal view returns (bytes memory) {
        return abi.encodePacked(creationCode, abi.encode(_expectedInitializer()));
    }

    function _parseAddr(string memory adapterName, string memory paramName, address fallback_)
        internal
        view
        returns (address)
    {
        string memory s = ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", adapterName, paramName);
        if (bytes(s).length == 0) return fallback_;
        return vm.parseAddress(s);
    }

    function _isEnabled(string memory adapterName) internal view returns (bool) {
        return ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", adapterName);
    }

    //
    // Per-adapter deploy + initialize
    //

    function _deployCcipIfConfigured(address bridgeProxy) internal {
        if (!_isEnabled("CCIP")) return;
        string memory routerStr = ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCIP", "router");
        if (bytes(routerStr).length == 0) return;

        (address adapter, bool fresh) = _create2Deploy(
            "CcipBridgeAdapter",
            _salt("CcipBridgeAdapter", DeploySalts.CCIP_ADAPTER),
            _adapterInitCode(type(CcipBridgeAdapter).creationCode)
        );
        if (fresh || CcipBridgeAdapter(payable(adapter)).bridgeEscrow() == address(0)) {
            address router = vm.parseAddress(routerStr);
            string memory feeTokenStr =
                ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCIP", "feeToken");
            address feeToken = bytes(feeTokenStr).length > 0 ? vm.parseAddress(feeTokenStr) : address(0);
            CcipBridgeAdapter(payable(adapter))
                .initialize(chainConfig.admin, bridgeProxy, router, feeToken, _adapterVersion("CCIP"));
        }
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "CCIP", adapter);
    }

    function _deployAcrossIfConfigured(address bridgeProxy) internal {
        if (!_isEnabled("Across")) return;
        string memory spokePoolStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Across", "spokePool");
        if (bytes(spokePoolStr).length == 0) return;

        (address adapter, bool fresh) = _create2Deploy(
            "AcrossBridgeAdapter",
            _salt("AcrossBridgeAdapter", DeploySalts.ACROSS_ADAPTER),
            _adapterInitCode(type(AcrossBridgeAdapter).creationCode)
        );
        if (fresh || AcrossBridgeAdapter(payable(adapter)).bridgeEscrow() == address(0)) {
            address spokePool = vm.parseAddress(spokePoolStr);
            string memory feePctStr =
                ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Across", "defaultRelayerFeePct");
            int64 feePct = bytes(feePctStr).length == 0 ? int64(0) : int64(int256(vm.parseInt(feePctStr)));
            AcrossBridgeAdapter(payable(adapter))
                .initialize(chainConfig.admin, bridgeProxy, spokePool, feePct, _adapterVersion("Across"));
        }
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Across", adapter);
    }

    function _deployStargateIfConfigured(address bridgeProxy) internal {
        if (!_isEnabled("Stargate")) return;
        // Stargate V2 routes via the LayerZero endpoint; the legacy V1 router param is no longer used.
        string memory endpointStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Stargate", "endpoint");
        if (bytes(endpointStr).length == 0) return;

        (address adapter, bool fresh) = _create2Deploy(
            "StargateBridgeAdapter",
            _salt("StargateBridgeAdapter", DeploySalts.STARGATE_ADAPTER),
            _adapterInitCode(type(StargateBridgeAdapter).creationCode)
        );
        if (fresh || StargateBridgeAdapter(payable(adapter)).bridgeEscrow() == address(0)) {
            address endpoint = vm.parseAddress(endpointStr);
            StargateBridgeAdapter(payable(adapter))
                .initialize(chainConfig.admin, bridgeProxy, endpoint, _adapterVersion("Stargate"));
        }
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Stargate", adapter);
    }

    function _deployGnosisIfConfigured(address bridgeProxy) internal {
        if (!_isEnabled("Gnosis")) return;
        string memory omnibridgeStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Gnosis", "omnibridge");
        if (bytes(omnibridgeStr).length == 0) return;

        (address adapter, bool fresh) = _create2Deploy(
            "GnosisBridgeAdapter",
            _salt("GnosisBridgeAdapter", DeploySalts.GNOSIS_ADAPTER),
            _adapterInitCode(type(GnosisBridgeAdapter).creationCode)
        );
        if (fresh || GnosisBridgeAdapter(payable(adapter)).bridgeEscrow() == address(0)) {
            address omnibridge = vm.parseAddress(omnibridgeStr);
            address amb = _parseAddr("Gnosis", "amb", address(0));
            GnosisBridgeAdapter(payable(adapter))
                .initialize(chainConfig.admin, bridgeProxy, omnibridge, amb, _adapterVersion("Gnosis"));
        }
        // Optional: wire the USDC transmuter (Gnosis side only — the config carries it on chain 100, not on
        // Ethereum). Absent/empty → leave unset (address(0)), so the Ethereum-side adapter bridges USDC natively.
        // Idempotent: only set when the deployed value differs from config, so re-runs are no-ops.
        string memory transmuterStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Gnosis", "usdcTransmuter");
        if (bytes(transmuterStr).length != 0) {
            address transmuter = vm.parseAddress(transmuterStr);
            if (address(GnosisBridgeAdapter(payable(adapter)).usdcTransmuter()) != transmuter) {
                GnosisBridgeAdapter(payable(adapter)).setUsdcTransmuter(transmuter);
            }
        }
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Gnosis", adapter);
    }

    function _deployCctpIfConfigured(address bridgeProxy) internal {
        if (!_isEnabled("CCTP")) return;
        string memory tokenMessengerStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCTP", "tokenMessenger");
        if (bytes(tokenMessengerStr).length == 0) return;

        (address adapter, bool fresh) = _create2Deploy(
            "CctpBridgeAdapter",
            _salt("CctpBridgeAdapter", DeploySalts.CCTP_ADAPTER),
            _adapterInitCode(type(CctpBridgeAdapter).creationCode)
        );
        if (fresh || CctpBridgeAdapter(adapter).bridgeEscrow() == address(0)) {
            address tokenMessenger = vm.parseAddress(tokenMessengerStr);
            address messageTransmitter = _parseAddr("CCTP", "messageTransmitter", address(0));
            CctpBridgeAdapter(adapter)
                .initialize(chainConfig.admin, bridgeProxy, tokenMessenger, messageTransmitter, _adapterVersion("CCTP"));
        }
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "CCTP", adapter);
    }

    function _deploySuperchainIfConfigured(address bridgeProxy) internal {
        if (!_isEnabled("Superchain")) return;
        string memory l2BridgeStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Superchain", "l2Bridge");
        // L2 side carries l2Bridge; L1 side carries the per-L2 arrays (l2ChainIds/l1Bridges/optimismPortals).
        uint256[] memory l2ChainIds =
            ConfigReader.readAdapterUintArray(vm, currentChainId, "bridgeAdapters", "Superchain", "l2ChainIds");
        if (bytes(l2BridgeStr).length == 0 && l2ChainIds.length == 0) return;

        (address adapter, bool fresh) = _create2Deploy(
            "SuperchainBridgeAdapter",
            _salt("SuperchainBridgeAdapter", DeploySalts.SUPERCHAIN_ADAPTER),
            _adapterInitCode(type(SuperchainBridgeAdapter).creationCode)
        );
        if (fresh || SuperchainBridgeAdapter(payable(adapter)).bridgeEscrow() == address(0)) {
            // Admin + escrow always come from the deploy context (like every other adapter here), NEVER from the
            // adapter config: the config `admin`/`bridgeEscrow` fields are deploy-populated placeholders and may
            // carry stale values from a prior deploy, which would grant admin to / point the escrow at the wrong
            // address. Only the true protocol addresses (l2Bridge / messengers) are read from config.
            address admin_ = chainConfig.admin;
            address bridgeEscrow_ = bridgeProxy;
            address l2Bridge_ = _parseAddr("Superchain", "l2Bridge", address(0));
            address l1Messenger_ = _parseAddr("Superchain", "l1Messenger", address(0));
            address l2Messenger_ = _parseAddr("Superchain", "l2Messenger", address(0));
            SuperchainBridgeAdapter(payable(adapter))
                .initialize(admin_, bridgeEscrow_, l2Bridge_, l1Messenger_, l2Messenger_, _adapterVersion("Superchain"));

            // On L1, seed the per-L2 standard bridges + portals from parallel config arrays.
            if (currentChainId == 1 && l2ChainIds.length > 0) {
                address[] memory l1Bridges = ConfigReader.readAdapterAddressArray(
                    vm, currentChainId, "bridgeAdapters", "Superchain", "l1Bridges"
                );
                address[] memory portals = ConfigReader.readAdapterAddressArray(
                    vm, currentChainId, "bridgeAdapters", "Superchain", "optimismPortals"
                );
                require(
                    l1Bridges.length == l2ChainIds.length && portals.length == l2ChainIds.length,
                    "Superchain: l2ChainIds/l1Bridges/optimismPortals length mismatch"
                );
                for (uint256 i = 0; i < l2ChainIds.length; i++) {
                    SuperchainBridgeAdapter(payable(adapter)).setL1BridgeForL2(l2ChainIds[i], l1Bridges[i]);
                    SuperchainBridgeAdapter(payable(adapter)).setOptimismPortalForL2(l2ChainIds[i], portals[i]);
                }
            }
        }
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Superchain", adapter);
    }

    /// @dev Derives an adapter's CREATE2 salt from its contract name + pinned DeploySalts version (single source of
    ///      truth, shared semantics with the impl/proxy layer in 01/02).
    function _salt(string memory name, uint256 v) internal pure returns (bytes32) {
        return generateSalt(name, v);
    }

    function _adapterVersion(string memory name) internal view returns (string memory) {
        string memory v = ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", name, "version");
        return bytes(v).length > 0 ? v : "1.0.0";
    }
}
