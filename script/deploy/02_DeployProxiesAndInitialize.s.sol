// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {ERC1967ProxyUninitialized} from "../../src/proxy/ERC1967ProxyUninitialized.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployProxiesAndInitialize
/// @notice Generates one Safe multicall per chain: deploy NAV + Bridge proxies (CREATE2) then initialize both.
/// @dev Run after 01_DeployImplementations has been executed. Run this script per chain (--chain-id) for chain-specific init.
contract DeployProxiesAndInitialize is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        address create2Deployer = readDeployedAddress("Create2Deployer");
        if (create2Deployer == address(0)) {
            console2.log("ERROR: Create2Deployer not deployed. Run 00_DeployCreate2Deployer first.");
            revert("Create2Deployer not deployed");
        }

        // Implementation addresses (must match 01; same salts)
        bytes32 saltNavImpl = generateSalt("NAVCalculatorImplementation", 1);
        address navImpl = computeCreate2Address(chainConfig.safeMultisig, saltNavImpl, type(NAVCalculator).creationCode);
        bytes32 saltBridgeImpl = generateSalt("BridgeEscrowImplementation", 1);
        address bridgeImpl =
            computeCreate2Address(chainConfig.safeMultisig, saltBridgeImpl, type(BridgeEscrow).creationCode);

        bytes32 saltNavProxy = generateSalt("NAVCalculatorProxy", 1);
        bytes memory navProxyBytecode = abi.encodePacked(
            type(ERC1967ProxyUninitialized).creationCode,
            abi.encode(navImpl, "")
        );
        address navProxy = computeCreate2Address(chainConfig.safeMultisig, saltNavProxy, navProxyBytecode);

        bytes32 saltBridgeProxy = generateSalt("BridgeEscrowProxy", 1);
        bytes memory bridgeProxyBytecode = abi.encodePacked(
            type(ERC1967ProxyUninitialized).creationCode,
            abi.encode(bridgeImpl, "")
        );
        address bridgeProxy = computeCreate2Address(chainConfig.safeMultisig, saltBridgeProxy, bridgeProxyBytecode);

        bytes memory navInitData = abi.encodeCall(
            NAVCalculator.initialize,
            (chainConfig.admin, chainConfig.chainlinkSequencerFeed, chainConfig.nativeTokenSymbol)
        );
        address[] memory initialAccounts = new address[](0);
        address[] memory initialAdapters = new address[](0);
        bytes memory bridgeInitData = abi.encodeCall(
            BridgeEscrow.initialize,
            (
                chainConfig.admin,
                currentChainId > type(uint64).max ? uint64(0) : uint64(currentChainId),
                initialAccounts,
                initialAdapters
            )
        );

        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](4);
        transactions[0] = SafeTxBuilder.delegateCall(
            create2Deployer, abi.encodeWithSignature("deploy(bytes32,bytes)", saltNavProxy, navProxyBytecode)
        );
        transactions[1] = SafeTxBuilder.delegateCall(
            create2Deployer, abi.encodeWithSignature("deploy(bytes32,bytes)", saltBridgeProxy, bridgeProxyBytecode)
        );
        transactions[2] = SafeTxBuilder.call(navProxy, 0, navInitData);
        transactions[3] = SafeTxBuilder.call(bridgeProxy, 0, bridgeInitData);

        string memory filename =
            string(abi.encodePacked(vm.toString(currentChainId), "-deploy-proxies-and-initialize.json"));
        writeSafeTx(
            filename,
            "Deploy proxies and initialize NAVCalculator + BridgeEscrow",
            string(
                abi.encodePacked(
                    "Chain ",
                    vm.toString(currentChainId),
                    ": deploy NAV + Bridge proxies (CREATE2), then initialize both. Same proxy addresses on all chains."
                )
            ),
            transactions
        );

        saveDeployedAddress("NAVCalculatorProxy", navProxy);
        saveDeployedAddress("BridgeEscrowProxy", bridgeProxy);

        console2.log("\nGenerated:", filename);
        console2.log("  Tx 1-2: Deploy NAVCalculator proxy, BridgeEscrow proxy");
        console2.log("  Tx 3-4: Initialize NAVCalculator, BridgeEscrow (chain-specific)");
        console2.log("NAV proxy (same on all chains):", navProxy);
        console2.log("Bridge proxy (same on all chains):", bridgeProxy);
        console2.log("Run this script per chain (--chain-id <id>), then execute each JSON on that chain.");
    }
}
