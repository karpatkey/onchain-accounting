// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ConfigReader} from "./ConfigReader.sol";
import {SafeTxBuilder} from "./SafeTxBuilder.sol";

/// @title BaseDeployScript
/// @notice Base contract for all deployment scripts with common utilities
abstract contract BaseDeployScript is Script {
    using ConfigReader for *;
    using SafeTxBuilder for *;

    /// @notice Chain configuration for the current deployment
    ConfigReader.ChainConfig internal chainConfig;

    /// @notice Current chain ID
    uint256 internal currentChainId;

    /// @notice Whether to broadcast transactions
    bool internal shouldBroadcast;

    /// @notice Setup function called before deployment
    function setUp() public virtual {
        currentChainId = block.chainid;
        chainConfig = ConfigReader.readChainConfig(vm, currentChainId);

        console2.log("=== Deployment Configuration ===");
        console2.log("Chain ID:", currentChainId);
        console2.log("Chain Name:", chainConfig.name);
        console2.log("Safe Multisig:", chainConfig.safeMultisig);
        console2.log("Admin:", chainConfig.admin);
        console2.log("Manager:", chainConfig.manager);
        console2.log("================================");
    }

    /// @notice Main deployment function - override in child contracts
    function run() public virtual;

    /// @notice Computes CREATE2 address for a contract
    /// @param deployer The deployer address (typically Safe multisig)
    /// @param salt The CREATE2 salt
    /// @param creationCode The contract creation code
    /// @return The computed CREATE2 address
    function computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode)))))
        );
    }

    /// @notice Reads a deployed contract address from deployment files
    /// @param contractName The name of the contract
    /// @return The deployed address, or zero address if not found
    function readDeployedAddress(string memory contractName) internal view returns (address) {
        return ConfigReader.readDeployedAddress(vm, currentChainId, contractName);
    }

    /// @notice Saves a deployed contract address to deployment files
    /// @param contractName The name of the contract
    /// @param contractAddress The deployed address
    function saveDeployedAddress(string memory contractName, address contractAddress) internal {
        ConfigReader.writeDeployedAddress(vm, currentChainId, contractName, contractAddress);
        console2.log(string(abi.encodePacked(contractName, " deployed at:")), contractAddress);
    }

    /// @notice Generates a deterministic CREATE2 salt
    /// @param contractName The contract name
    /// @param version The version number
    /// @return The CREATE2 salt
    function generateSalt(string memory contractName, uint256 version) internal pure returns (bytes32) {
        return ConfigReader.computeSalt(contractName, version);
    }

    /// @notice Writes a Safe transaction to file
    /// @param filename The filename (without path)
    /// @param name Transaction name
    /// @param description Transaction description
    /// @param transactions Array of transactions
    function writeSafeTx(
        string memory filename,
        string memory name,
        string memory description,
        SafeTxBuilder.Transaction[] memory transactions
    ) internal {
        SafeTxBuilder.writeSafeTx(vm, currentChainId, filename, name, description, transactions);
    }

    /// @notice Helper to start broadcasting if enabled
    function startBroadcast() internal {
        if (shouldBroadcast) {
            vm.startBroadcast();
        }
    }

    /// @notice Helper to stop broadcasting if enabled
    function stopBroadcast() internal {
        if (shouldBroadcast) {
            vm.stopBroadcast();
        }
    }

    /// @notice Validates that required addresses are set
    function validateAddresses() internal view {
        require(chainConfig.safeMultisig != address(0), "Safe multisig address not configured");
        require(chainConfig.admin != address(0), "Admin address not configured");
        require(chainConfig.manager != address(0), "Manager address not configured");
        require(chainConfig.assetRecoverer != address(0), "Asset recoverer address not configured");
    }

    /// @notice Checks if a contract is already deployed
    /// @param contractName The contract name to check
    /// @return True if deployed, false otherwise
    function isDeployed(string memory contractName) internal view returns (bool) {
        return readDeployedAddress(contractName) != address(0);
    }
}
