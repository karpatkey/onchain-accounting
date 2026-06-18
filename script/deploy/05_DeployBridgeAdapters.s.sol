// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {CcipBridgeAdapter} from "../../src/bridge/adapters/CcipBridgeAdapter.sol";
import {AcrossBridgeAdapter} from "../../src/bridge/adapters/AcrossBridgeAdapter.sol";
import {StargateBridgeAdapter} from "../../src/bridge/adapters/StargateBridgeAdapter.sol";
import {CctpBridgeAdapter} from "../../src/bridge/adapters/CctpBridgeAdapter.sol";
import {SuperchainBridgeAdapter} from "../../src/bridge/adapters/SuperchainBridgeAdapter.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployBridgeAdapters
/// @notice Deploys bridge adapters for BridgeEscrow from chain config
/// @dev Bridge adapters use initialize(admin, bridgeEscrow, ...). Addresses saved to bridgeAdapters.<Name>.deployed.
contract DeployBridgeAdapters is BaseDeployScript {
    function run() public override {
        setUp();

        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        if (bridgeProxy == address(0)) {
            bridgeProxy = readDeployedAddress("BridgeEscrowProxyWithInit");
        }
        require(bridgeProxy != address(0), "BridgeEscrow proxy not in config. Deploy 02_DeployProxies.s.sol first.");
        require(chainConfig.admin != address(0), "Admin not configured.");

        console2.log("\n=== Deploying Bridge Adapters ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("BridgeEscrow:", bridgeProxy);
        console2.log("Admin:", chainConfig.admin);
        console2.log("");

        if (currentChainId == 1) {
            _deployMainnetBridgeAdapters(bridgeProxy);
        } else if (currentChainId == 42161) {
            _deployArbitrumBridgeAdapters(bridgeProxy);
        } else if (currentChainId == 10) {
            _deployOptimismBridgeAdapters(bridgeProxy);
        } else if (currentChainId == 8453) {
            _deployBaseBridgeAdapters(bridgeProxy);
        } else if (currentChainId == 100) {
            _deployGnosisBridgeAdapters(bridgeProxy);
        } else {
            console2.log("No bridge adapters configured for chain:", currentChainId);
        }

        console2.log("\n=== Next Steps ===");
        console2.log("1. Set bridgeAdapters.<Name>.enabled to true in chain config if needed");
        console2.log("2. Run 06_Configure.s.sol to generate Safe tx to authorize adapters");
        console2.log("3. Execute via Safe UI");
        console2.log("====================");
    }

    function _deployMainnetBridgeAdapters(address) internal {
        console2.log("Deploying Mainnet bridge adapters...\n");
        vm.startBroadcast();
        // Add Mainnet-specific adapters when config is present
        vm.stopBroadcast();
        console2.log("Mainnet: no bridge adapters with config to deploy.");
    }

    function _deployArbitrumBridgeAdapters(address bridgeProxy) internal {
        console2.log("Deploying Arbitrum bridge adapters...\n");
        vm.startBroadcast();

        _deployCcipIfConfigured(bridgeProxy);
        _deployAcrossIfConfigured(bridgeProxy);
        _deployStargateIfConfigured(bridgeProxy);
        _deployCctpIfConfigured(bridgeProxy);

        vm.stopBroadcast();
    }

    function _deployBaseBridgeAdapters(address bridgeProxy) internal {
        console2.log("Deploying Base bridge adapters (Superchain + CCTP, Across, Stargate)...\n");
        vm.startBroadcast();
        _deploySuperchainL2IfNeeded(bridgeProxy);
        _deployCcipIfConfigured(bridgeProxy);
        _deployAcrossIfConfigured(bridgeProxy);
        _deployStargateIfConfigured(bridgeProxy);
        _deployCctpIfConfigured(bridgeProxy);
        vm.stopBroadcast();
    }

    function _deployOptimismBridgeAdapters(address bridgeProxy) internal {
        console2.log("Deploying Optimism bridge adapters (Superchain L2 + CCTP)...\n");
        vm.startBroadcast();
        _deploySuperchainL2IfNeeded(bridgeProxy);
        _deployCctpIfConfigured(bridgeProxy);
        vm.stopBroadcast();
    }

    function _deployGnosisBridgeAdapters(address) internal {
        console2.log("Deploying Gnosis bridge adapters...\n");
        vm.startBroadcast();
        vm.stopBroadcast();
        console2.log("Gnosis: no bridge adapters configured.");
    }

    function _deploySuperchainL2IfNeeded(address bridgeProxy) internal {
        string memory l2BridgeStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Superchain", "l2Bridge");
        if (bytes(l2BridgeStr).length == 0) return;
        if (_isAdapterDeployedOnChain("bridgeAdapters", "Superchain")) {
            console2.log("Superchain adapter already deployed");
            return;
        }
        address admin_ = _parseAddr("Superchain", "admin", chainConfig.admin);
        address bridgeEscrow_ = _parseAddr("Superchain", "bridgeEscrow", bridgeProxy);
        address l1Bridge_ = _parseAddr("Superchain", "l1Bridge", address(0));
        address l2Bridge_ = vm.parseAddress(l2BridgeStr);
        address l1Messenger_ = _parseAddr("Superchain", "l1Messenger", address(0));
        address l2Messenger_ = _parseAddr("Superchain", "l2Messenger", address(0));
        address optimismPortal_ = _parseAddr("Superchain", "optimismPortal", address(0));
        string memory version_ = _adapterVersion("Superchain");

        SuperchainBridgeAdapter adapter = new SuperchainBridgeAdapter();
        adapter.initialize(
            admin_, bridgeEscrow_, l1Bridge_, l2Bridge_, l1Messenger_, l2Messenger_, optimismPortal_, version_
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Superchain", address(adapter));
        console2.log("SuperchainBridgeAdapter deployed at:", address(adapter));
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

    function _deployCcipIfConfigured(address bridgeProxy) internal {
        string memory routerStr = ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCIP", "router");
        if (bytes(routerStr).length == 0) return;
        if (_isAdapterDeployedOnChain("bridgeAdapters", "CCIP")) {
            console2.log("CCIP already deployed");
            return;
        }
        address router = vm.parseAddress(routerStr);
        string memory feeTokenStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCIP", "feeToken");
        address feeToken = bytes(feeTokenStr).length > 0 ? vm.parseAddress(feeTokenStr) : address(0);
        string memory version = _adapterVersion("CCIP");

        CcipBridgeAdapter adapter = new CcipBridgeAdapter();
        adapter.initialize(chainConfig.admin, bridgeProxy, router, feeToken, version);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "CCIP", address(adapter));
        console2.log("CcipBridgeAdapter deployed at:", address(adapter));
    }

    function _deployAcrossIfConfigured(address bridgeProxy) internal {
        string memory spokePoolStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Across", "spokePool");
        if (bytes(spokePoolStr).length == 0) return;
        if (_isAdapterDeployedOnChain("bridgeAdapters", "Across")) {
            console2.log("Across already deployed");
            return;
        }
        address spokePool = vm.parseAddress(spokePoolStr);
        string memory feePctStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Across", "defaultRelayerFeePct");
        int64 feePct = bytes(feePctStr).length == 0 ? int64(0) : int64(int256(vm.parseInt(feePctStr)));
        string memory version = _adapterVersion("Across");

        AcrossBridgeAdapter adapter = new AcrossBridgeAdapter();
        adapter.initialize(chainConfig.admin, bridgeProxy, spokePool, feePct, version);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Across", address(adapter));
        console2.log("AcrossBridgeAdapter deployed at:", address(adapter));
    }

    function _deployStargateIfConfigured(address bridgeProxy) internal {
        string memory routerStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Stargate", "router");
        if (bytes(routerStr).length == 0) return;
        if (_isAdapterDeployedOnChain("bridgeAdapters", "Stargate")) {
            console2.log("Stargate already deployed");
            return;
        }
        address router = vm.parseAddress(routerStr);
        string memory endpointStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "Stargate", "endpoint");
        address endpoint = vm.parseAddress(endpointStr);
        string memory version = _adapterVersion("Stargate");

        StargateBridgeAdapter adapter = new StargateBridgeAdapter();
        adapter.initialize(chainConfig.admin, bridgeProxy, router, endpoint, version);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "Stargate", address(adapter));
        console2.log("StargateBridgeAdapter deployed at:", address(adapter));
    }

    function _deployCctpIfConfigured(address bridgeProxy) internal {
        string memory tokenMessengerStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCTP", "tokenMessenger");
        if (bytes(tokenMessengerStr).length == 0) return;
        if (_isAdapterDeployedOnChain("bridgeAdapters", "CCTP")) {
            console2.log("CCTP already deployed");
            return;
        }
        address tokenMessenger = vm.parseAddress(tokenMessengerStr);
        string memory messageTransmitterStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", "CCTP", "messageTransmitter");
        address messageTransmitter = vm.parseAddress(messageTransmitterStr);
        string memory version = _adapterVersion("CCTP");

        CctpBridgeAdapter adapter = new CctpBridgeAdapter();
        adapter.initialize(chainConfig.admin, bridgeProxy, tokenMessenger, messageTransmitter, version);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "bridgeAdapters", "CCTP", address(adapter));
        console2.log("CctpBridgeAdapter deployed at:", address(adapter));
    }

    function _adapterVersion(string memory name) internal view returns (string memory) {
        string memory v = ConfigReader.readAdapterParam(vm, currentChainId, "bridgeAdapters", name, "version");
        return bytes(v).length > 0 ? v : "1.0.0";
    }

    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        return ConfigReader.readDeployedAdapterAddress(vm, currentChainId, adapterType, adapterName);
    }

    /// @notice Returns true only if the config has a deployed address and that address has bytecode on the current chain.
    /// @dev Used to avoid skipping deployment when config has a stale or wrong address with no contract on chain.
    function _isAdapterDeployedOnChain(string memory adapterType, string memory adapterName)
        internal
        view
        returns (bool)
    {
        address a = _readAdapterDeployed(adapterType, adapterName);
        if (a == address(0)) return false;
        return a.code.length > 0;
    }
}
