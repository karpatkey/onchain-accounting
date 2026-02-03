// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {console2} from "forge-std/console2.sol";

// Import bridge adapters - add these imports as you create the adapters
// import {CCIPBridgeAdapter} from "../../src/bridge/adapters/CCIPBridgeAdapter.sol";
// import {AcrossBridgeAdapter} from "../../src/bridge/adapters/AcrossBridgeAdapter.sol";

/// @title DeployBridgeAdapters
/// @notice Deploys bridge adapters for BridgeEscrow
/// @dev Bridge adapters are NOT upgradeable - they can be authorized/revoked via BridgeEscrow admin functions
contract DeployBridgeAdapters is BaseDeployScript {
    function run() public override {
        setUp();

        console2.log("\n=== Deploying Bridge Adapters ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("");

        console2.log("=== Bridge Adapter Deployment Instructions ===");
        console2.log("Bridge adapters need chain-specific router/pool addresses.");
        console2.log("Available adapter types in src/bridge/adapters/:");
        console2.log("- CCIP (Chainlink Cross-Chain Interoperability Protocol)");
        console2.log("- Across Protocol");
        console2.log("- Stargate");
        console2.log("- Native L2 bridges (Optimism, Arbitrum, Base)");
        console2.log("");
        console2.log("After deployment:");
        console2.log("1. Save adapter addresses using saveDeployedAddress()");
        console2.log("2. Generate Safe transaction to authorize adapters");
        console2.log("3. Execute via Safe UI");
        console2.log("===============================================\n");

        // Deploy adapters based on chain
        if (currentChainId == 1) {
            // Mainnet
            _deployMainnetBridgeAdapters();
        } else if (currentChainId == 42161) {
            // Arbitrum
            _deployArbitrumBridgeAdapters();
        } else if (currentChainId == 10) {
            // Optimism
            _deployOptimismBridgeAdapters();
        } else if (currentChainId == 8453) {
            // Base
            _deployBaseBridgeAdapters();
        } else if (currentChainId == 100) {
            // Gnosis
            _deployGnosisBridgeAdapters();
        } else {
            console2.log("No bridge adapters configured for chain:", currentChainId);
        }

        console2.log("\n=== Next Steps ===");
        console2.log("1. Verify deployed adapters on Etherscan");
        console2.log("2. Generate Safe transaction to authorize adapters:");
        console2.log("   forge script script/manage/ManageAdapters.s.sol --sig 'authorizeBridgeAdapter(address)'");
        console2.log("3. Execute via Safe UI");
        console2.log("====================");
    }

    // Mainnet bridge adapter deployments
    function _deployMainnetBridgeAdapters() internal {
        console2.log("Deploying Mainnet bridge adapters...\n");

        vm.startBroadcast();

        // Example: CCIP Adapter
        // address ccipRouter = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D; // Mainnet CCIP Router
        // CCIPBridgeAdapter ccipAdapter = new CCIPBridgeAdapter(ccipRouter);
        // saveDeployedAddress("CCIPBridgeAdapter", address(ccipAdapter));
        // console2.log("CCIP Bridge Adapter:", address(ccipAdapter));

        // Example: Across Adapter
        // address spokePool = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5; // Mainnet Across SpokePool
        // AcrossBridgeAdapter acrossAdapter = new AcrossBridgeAdapter(spokePool);
        // saveDeployedAddress("AcrossBridgeAdapter", address(acrossAdapter));
        // console2.log("Across Bridge Adapter:", address(acrossAdapter));

        vm.stopBroadcast();

        console2.log("Mainnet bridge adapters deployment ready (uncomment adapters to deploy)");
    }

    // Arbitrum bridge adapter deployments
    function _deployArbitrumBridgeAdapters() internal {
        console2.log("Deploying Arbitrum bridge adapters...\n");

        vm.startBroadcast();

        // Example: CCIP Adapter
        // address ccipRouter = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8; // Arbitrum CCIP Router
        // CCIPBridgeAdapter ccipAdapter = new CCIPBridgeAdapter(ccipRouter);
        // saveDeployedAddress("CCIPBridgeAdapter", address(ccipAdapter));

        // Example: Across Adapter
        // address spokePool = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A; // Arbitrum Across SpokePool
        // AcrossBridgeAdapter acrossAdapter = new AcrossBridgeAdapter(spokePool);
        // saveDeployedAddress("AcrossBridgeAdapter", address(acrossAdapter));

        // Example: Arbitrum Native Bridge Adapter
        // address arbBridge = 0x8315177aB297bA92A06054cE80a67Ed4DBd7ed3a; // Arbitrum Bridge
        // ArbitrumBridgeAdapter arbAdapter = new ArbitrumBridgeAdapter(arbBridge);
        // saveDeployedAddress("ArbitrumBridgeAdapter", address(arbAdapter));

        vm.stopBroadcast();

        console2.log("Arbitrum bridge adapters deployment ready (uncomment adapters to deploy)");
    }

    // Optimism bridge adapter deployments
    function _deployOptimismBridgeAdapters() internal {
        console2.log("Deploying Optimism bridge adapters...\n");

        vm.startBroadcast();

        // Example: CCIP Adapter
        // address ccipRouter = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f; // Optimism CCIP Router
        // CCIPBridgeAdapter ccipAdapter = new CCIPBridgeAdapter(ccipRouter);
        // saveDeployedAddress("CCIPBridgeAdapter", address(ccipAdapter));

        // Example: Across Adapter
        // address spokePool = 0x6f26Bf09B1C792e3228e5467807a900A503c0281; // Optimism Across SpokePool
        // AcrossBridgeAdapter acrossAdapter = new AcrossBridgeAdapter(spokePool);
        // saveDeployedAddress("AcrossBridgeAdapter", address(acrossAdapter));

        // Example: Optimism Native Bridge Adapter
        // address opBridge = 0x4200000000000000000000000000000000000010; // Optimism L2StandardBridge
        // OptimismBridgeAdapter opAdapter = new OptimismBridgeAdapter(opBridge);
        // saveDeployedAddress("OptimismBridgeAdapter", address(opAdapter));

        vm.stopBroadcast();

        console2.log("Optimism bridge adapters deployment ready (uncomment adapters to deploy)");
    }

    // Base bridge adapter deployments
    function _deployBaseBridgeAdapters() internal {
        console2.log("Deploying Base bridge adapters...\n");

        vm.startBroadcast();

        // Example: CCIP Adapter
        // address ccipRouter = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD; // Base CCIP Router
        // CCIPBridgeAdapter ccipAdapter = new CCIPBridgeAdapter(ccipRouter);
        // saveDeployedAddress("CCIPBridgeAdapter", address(ccipAdapter));

        // Example: Across Adapter
        // address spokePool = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64; // Base Across SpokePool
        // AcrossBridgeAdapter acrossAdapter = new AcrossBridgeAdapter(spokePool);
        // saveDeployedAddress("AcrossBridgeAdapter", address(acrossAdapter));

        // Example: Base Native Bridge Adapter (same as OP Stack)
        // address baseBridge = 0x4200000000000000000000000000000000000010; // Base L2StandardBridge
        // BaseBridgeAdapter baseAdapter = new BaseBridgeAdapter(baseBridge);
        // saveDeployedAddress("BaseBridgeAdapter", address(baseAdapter));

        vm.stopBroadcast();

        console2.log("Base bridge adapters deployment ready (uncomment adapters to deploy)");
    }

    // Gnosis bridge adapter deployments
    function _deployGnosisBridgeAdapters() internal {
        console2.log("Deploying Gnosis bridge adapters...\n");

        vm.startBroadcast();

        // Example: Gnosis-specific bridge adapters
        // Add adapters for Gnosis Chain bridges

        vm.stopBroadcast();

        console2.log("Gnosis bridge adapters deployment ready (uncomment adapters to deploy)");
    }
}
