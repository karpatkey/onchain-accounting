// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {Create2Deployer} from "../../src/deployment/Create2Deployer.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployCreate2Deployer
/// @notice Deploys the Create2Deployer library contract (one-time per chain)
/// @dev This contract can be deployed by any account - it's stateless and has no owner
contract DeployCreate2Deployer is BaseDeployScript {
    function run() public override {
        setUp();

        // Check if already deployed
        address existingDeployer = readDeployedAddress("Create2Deployer");
        if (existingDeployer != address(0) && existingDeployer.code.length > 0) {
            console2.log("Create2Deployer already deployed at:", existingDeployer);
            return;
        }

        console2.log("\n=== Deploying Create2Deployer ===");

        // Deploy Create2Deployer library
        vm.startBroadcast();
        Create2Deployer deployer = new Create2Deployer();
        vm.stopBroadcast();

        console2.log("Create2Deployer deployed at:", address(deployer));

        // Save to deployment records (automatically updates chain config)
        saveDeployedAddress("Create2Deployer", address(deployer));
        console2.log(
            "Address saved to:", string(abi.encodePacked("script/config/chains/", vm.toString(currentChainId), ".json"))
        );

        // Verify on Etherscan
        console2.log("\n=== Verifying on Etherscan ===");
        _verifyContract(address(deployer));

        console2.log("\n=== Deployment Complete ===");
        console2.log("Next steps:");
        console2.log("1. Verify deployment in chain config file");
        console2.log("2. Proceed with core contract deployments (NAVCalculator, BridgeEscrow)");
    }

    /// @notice Verifies the Create2Deployer contract on Etherscan
    function _verifyContract(address deployedAddress) internal view {
        // Check if we have an explorer API key
        if (bytes(chainConfig.explorerApiKey).length == 0) {
            console2.log("No explorer API key configured, skipping verification");
            return;
        }

        console2.log("Verifying contract on Etherscan...");
        console2.log("To verify manually, run:");
        console2.log(
            string(
                abi.encodePacked(
                    "forge verify-contract ",
                    vm.toString(deployedAddress),
                    " src/deployment/Create2Deployer.sol:Create2Deployer --chain-id ",
                    vm.toString(currentChainId),
                    " --watch"
                )
            )
        );

        // Note: In practice, you'd run this command manually or use the verify script
        // FFI verification can be unreliable, so we just log the command here
    }
}
