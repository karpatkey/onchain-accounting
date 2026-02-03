// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {console2} from "forge-std/console2.sol";

/// @title VerifyEtherscan
/// @notice Verifies deployed contracts on Etherscan
/// @dev This script generates verification commands to be run manually
contract VerifyEtherscan is BaseDeployScript {
    function run() public override {
        setUp();

        console2.log("\n=== Etherscan Verification Commands ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("Explorer:", chainConfig.explorer);
        console2.log("");

        // Get deployment addresses
        address create2Deployer = readDeployedAddress("Create2Deployer");
        address navImpl = readDeployedAddress("NAVCalculatorImplementation");
        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        address bridgeImpl = readDeployedAddress("BridgeEscrowImplementation");
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");

        // Verify Create2Deployer
        if (create2Deployer != address(0)) {
            console2.log("# Verify Create2Deployer");
            console2.log("forge verify-contract \\");
            console2.log(string(abi.encodePacked("  --chain-id ", vm.toString(currentChainId), " \\")));
            console2.log("  --compiler-version v0.8.28 \\");
            console2.log(string(abi.encodePacked("  --etherscan-api-key $", _getApiKeyEnvVar(), " \\")));
            console2.log(string(abi.encodePacked("  ", vm.toString(create2Deployer), " \\")));
            console2.log("  src/deployment/Create2Deployer.sol:Create2Deployer");
            console2.log("");
        }

        // Verify NAVCalculator Implementation
        if (navImpl != address(0)) {
            console2.log("# Verify NAVCalculator Implementation");
            console2.log("forge verify-contract \\");
            console2.log(string(abi.encodePacked("  --chain-id ", vm.toString(currentChainId), " \\")));
            console2.log("  --compiler-version v0.8.28 \\");
            console2.log(string(abi.encodePacked("  --etherscan-api-key $", _getApiKeyEnvVar(), " \\")));
            console2.log(string(abi.encodePacked("  ", vm.toString(navImpl), " \\")));
            console2.log("  src/nav/NAVCalculator.sol:NAVCalculator");
            console2.log("");
        }

        // Verify NAVCalculator Proxy
        if (navProxy != address(0) && navImpl != address(0)) {
            console2.log("# Verify NAVCalculator Proxy");
            console2.log("forge verify-contract \\");
            console2.log(string(abi.encodePacked("  --chain-id ", vm.toString(currentChainId), " \\")));
            console2.log("  --compiler-version v0.8.28 \\");
            console2.log(string(abi.encodePacked("  --etherscan-api-key $", _getApiKeyEnvVar(), " \\")));
            console2.log(
                string(
                    abi.encodePacked(
                        "  --constructor-args $(cast abi-encode 'constructor(address,bytes)' ",
                        vm.toString(navImpl),
                        " 0x",
                        vm.toString(_getNavInitData()),
                        ") \\"
                    )
                )
            );
            console2.log(string(abi.encodePacked("  ", vm.toString(navProxy), " \\")));
            console2.log("  @openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");
            console2.log("");
        }

        // Verify BridgeEscrow Implementation
        if (bridgeImpl != address(0)) {
            console2.log("# Verify BridgeEscrow Implementation");
            console2.log("forge verify-contract \\");
            console2.log(string(abi.encodePacked("  --chain-id ", vm.toString(currentChainId), " \\")));
            console2.log("  --compiler-version v0.8.28 \\");
            console2.log(string(abi.encodePacked("  --etherscan-api-key $", _getApiKeyEnvVar(), " \\")));
            console2.log(string(abi.encodePacked("  ", vm.toString(bridgeImpl), " \\")));
            console2.log("  src/bridge/BridgeEscrow.sol:BridgeEscrow");
            console2.log("");
        }

        // Verify BridgeEscrow Proxy
        if (bridgeProxy != address(0) && bridgeImpl != address(0)) {
            console2.log("# Verify BridgeEscrow Proxy");
            console2.log("forge verify-contract \\");
            console2.log(string(abi.encodePacked("  --chain-id ", vm.toString(currentChainId), " \\")));
            console2.log("  --compiler-version v0.8.28 \\");
            console2.log(string(abi.encodePacked("  --etherscan-api-key $", _getApiKeyEnvVar(), " \\")));
            console2.log(
                string(
                    abi.encodePacked(
                        "  --constructor-args $(cast abi-encode 'constructor(address,bytes)' ",
                        vm.toString(bridgeImpl),
                        " 0x",
                        vm.toString(_getBridgeInitData()),
                        ") \\"
                    )
                )
            );
            console2.log(string(abi.encodePacked("  ", vm.toString(bridgeProxy), " \\")));
            console2.log("  @openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");
            console2.log("");
        }

        console2.log("=====================================");
        console2.log("\nNOTE: Copy and run each command above to verify contracts.");
        console2.log("Make sure to set the appropriate API key environment variable.");
    }

    function _getApiKeyEnvVar() internal view returns (string memory) {
        if (currentChainId == 1) return "ETHERSCAN_API_KEY";
        if (currentChainId == 42161) return "ARBISCAN_API_KEY";
        if (currentChainId == 10) return "OPTIMISM_ETHERSCAN_API_KEY";
        if (currentChainId == 8453) return "BASESCAN_API_KEY";
        if (currentChainId == 100) return "GNOSISSCAN_API_KEY";
        return "ETHERSCAN_API_KEY";
    }

    function _getNavInitData() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "initialize(address,address,address,string)",
            chainConfig.admin,
            chainConfig.assetRecoverer,
            chainConfig.chainlinkSequencerFeed,
            chainConfig.nativeTokenSymbol
        );
    }

    function _getBridgeInitData() internal view returns (bytes memory) {
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);

        return abi.encodeWithSignature(
            "initialize(address,uint64,address[],address[])",
            chainConfig.admin,
            // forge-lint: disable-next-line(unsafe-typecast) - chain IDs fit in uint64
            uint64(currentChainId),
            initialAccounts,
            initialAdapters
        );
    }
}
