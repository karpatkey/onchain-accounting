// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console2} from "forge-std/console2.sol";

/// @title InitializeProxies
/// @notice Generates Safe transactions per chain: upgrade proxies from placeholder to real impl and initialize.
/// @dev Proxies are deployed by 02a with a placeholder impl; this script generates upgradeAndCall(proxy, realImpl, initData)
///      via each proxy's ProxyAdmin (at vm.computeCreateAddress(proxy, 0)). Run per chain for chain-specific impl addresses and init.
contract InitializeProxies is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        address bridgeProxy = readDeployedAddress("BridgeEscrowProxy");
        address navImpl = readDeployedAddress("NAVCalculatorImplementation");
        address bridgeImpl = readDeployedAddress("BridgeEscrowImplementation");

        require(navProxy != address(0), "NAVCalculator proxy address not found. Run 02a_DeployProxies.s.sol first.");
        require(bridgeProxy != address(0), "BridgeEscrow proxy address not found. Run 02a_DeployProxies.s.sol first.");
        require(navImpl != address(0), "NAVCalculator implementation address not configured.");
        require(bridgeImpl != address(0), "BridgeEscrow implementation address not configured.");

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
                // forge-lint: disable-next-line(unsafe-typecast)
                currentChainId > type(uint64).max ? uint64(0) : uint64(currentChainId),
                initialAccounts,
                initialAdapters
            )
        );

        // ProxyAdmin is deployed by the proxy in its constructor; address = computeCreateAddress(proxy, 0).
        address navProxyAdmin = vm.computeCreateAddress(navProxy, 0);
        address bridgeProxyAdmin = vm.computeCreateAddress(bridgeProxy, 0);

        SafeTxBuilder.Transaction[] memory allTxs = new SafeTxBuilder.Transaction[](2);

        // 1. Upgrade NAV proxy to real impl and initialize (via ProxyAdmin)
        allTxs[0] = SafeTxBuilder.call(
            navProxyAdmin,
            0,
            abi.encodeWithSelector(
                ProxyAdmin.upgradeAndCall.selector,
                ITransparentUpgradeableProxy(payable(navProxy)),
                navImpl,
                navInitData
            )
        );

        // 2. Upgrade Bridge proxy to real impl and initialize (via ProxyAdmin)
        allTxs[1] = SafeTxBuilder.call(
            bridgeProxyAdmin,
            0,
            abi.encodeWithSelector(
                ProxyAdmin.upgradeAndCall.selector,
                ITransparentUpgradeableProxy(payable(bridgeProxy)),
                bridgeImpl,
                bridgeInitData
            )
        );

        // Generate transaction file with initialization transactions only
        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-initialize-proxies.json"));
        SafeTxBuilder.writeSafeTx(
            vm,
            currentChainId,
            filename,
            "Initialize NAVCalculator + BridgeEscrow proxies",
            string(
                abi.encodePacked(
                    "Chain ",
                    vm.toString(currentChainId),
                    ": initialize NAV + Bridge proxies. ",
                    "Proxies must be deployed first via 02a_DeployProxies.s.sol. ",
                    "NAV proxy: ",
                    vm.toString(navProxy),
                    ", Bridge proxy: ",
                    vm.toString(bridgeProxy)
                )
            ),
            chainConfig.safeMultisig,
            allTxs
        );

        // Note: All operations are CALL (0), no DELEGATECALL needed

        console2.log("\n=== Transaction File Generated ===");
        console2.log("File: safe-transactions/", filename);
        console2.log("\nThis transaction file contains 2 individual transactions:");
        console2.log("  1. CALL: ProxyAdmin.upgradeAndCall(NAV proxy, NAV impl, initData)");
        console2.log("  2. CALL: ProxyAdmin.upgradeAndCall(Bridge proxy, Bridge impl, initData)");
        console2.log("\n[NOTE] Proxies must be deployed first via 02a_DeployProxies.s.sol (with placeholder impl).");
        console2.log("\n=== Safe CLI Command (Ready to Execute) ===");
        console2.log("Using tx-builder command:");
        string memory txBuilderCommand = string(
            abi.encodePacked(
                "safe-cli tx-builder ",
                vm.toString(chainConfig.safeMultisig),
                " ",
                chainConfig.rpc,
                " ./safe-transactions/",
                filename,
                " --private-key <KEY1> --private-key <KEY2> [--non-interactive]"
            )
        );
        console2.log(txBuilderCommand);
        console2.log("\n[INFO] This transaction file contains multiple individual transactions (not MultiSend).");
        console2.log("  The Safe UI will execute them as a batch. All operations use CALL (no DELEGATECALL required).");
        console2.log("\n  To simulate transactions before submission, run:");
        console2.log("    forge test --match-path script/test/SimulateSafeTransactions.fork.t.sol --fork-url <RPC_URL>");

        console2.log("\nProxy addresses (from deployment config):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);
        console2.log("\nRun this script per chain (--chain-id <id>), then execute the transaction on that chain.");
    }
}
