// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {BridgeEscrow} from "../../src/bridge/BridgeEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title InitializeProxies
/// @notice Generates Safe transactions per chain: upgrade proxies from placeholder to real impl and initialize.
/// @dev Proxies are deployed by 02a with a placeholder impl; this script generates upgradeToAndCall(realImpl, initData)
///      called directly on the proxy. Upgrades are protected by _authorizeUpgrade in the implementation (checks DEFAULT_ADMIN_ROLE).
///      Run per chain for chain-specific impl addresses and init.
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

        // Verify proxies are deployed
        require(navProxy.code.length > 0, "NAVCalculator proxy not deployed - run 02a_DeployProxies.s.sol first");
        require(bridgeProxy.code.length > 0, "BridgeEscrow proxy not deployed - run 02a_DeployProxies.s.sol first");

        // Generate FIRST transaction file: upgrade and initialize proxies
        // This must be executed BEFORE granting roles to ensure proxies are initialized
        // UUPS pattern: call upgradeToAndCall directly on proxy (protected by _authorizeUpgrade in implementation)
        SafeTxBuilder.Transaction[] memory upgradeTxs = new SafeTxBuilder.Transaction[](2);

        // 1. Upgrade NAV proxy to real impl and initialize (direct call to proxy)
        upgradeTxs[0] = SafeTxBuilder.call(
            navProxy, 0, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, navImpl, navInitData)
        );

        // 2. Upgrade Bridge proxy to real impl and initialize (direct call to proxy)
        upgradeTxs[1] = SafeTxBuilder.call(
            bridgeProxy,
            0,
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, bridgeImpl, bridgeInitData)
        );

        string memory upgradeFilename =
            string(abi.encodePacked(vm.toString(currentChainId), "-initialize-proxies.json"));
        SafeTxBuilder.writeSafeTx(
            vm,
            currentChainId,
            upgradeFilename,
            "Initialize NAVCalculator + BridgeEscrow proxies",
            string(
                abi.encodePacked(
                    "Chain ",
                    vm.toString(currentChainId),
                    ": upgrade and initialize NAV + Bridge proxies. ",
                    "Proxies must be deployed first via 02a_DeployProxies.s.sol. ",
                    "NAV proxy: ",
                    vm.toString(navProxy),
                    ", Bridge proxy: ",
                    vm.toString(bridgeProxy),
                    ". ",
                    "Execute this transaction FIRST, then execute the grant-role transaction."
                )
            ),
            chainConfig.safeMultisig,
            upgradeTxs
        );

        console2.log("\n=== Transaction File 1 Generated: Upgrade & Initialize ===");
        console2.log("File: safe-transactions/", upgradeFilename);
        console2.log("This file contains 2 transactions:");
        console2.log("  1. CALL: NAV proxy.upgradeToAndCall(NAV impl, initData)");
        console2.log("  2. CALL: Bridge proxy.upgradeToAndCall(Bridge impl, initData)");
        console2.log("Note: Upgrades are protected by _authorizeUpgrade (requires DEFAULT_ADMIN_ROLE)");

        // Generate SECOND transaction file: grant MANAGER roles (only if manager is configured)
        if (chainConfig.manager != address(0)) {
            SafeTxBuilder.Transaction[] memory grantRoleTxs = new SafeTxBuilder.Transaction[](2);

            // 1. Grant MANAGER role to manager address on NAVCalculator
            grantRoleTxs[0] = SafeTxBuilder.call(
                navProxy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager)
            );

            // 2. Grant MANAGER role to manager address on BridgeEscrow
            grantRoleTxs[1] = SafeTxBuilder.call(
                bridgeProxy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager)
            );

            string memory grantRoleFilename =
                string(abi.encodePacked(vm.toString(currentChainId), "-grant-manager-role.json"));
            SafeTxBuilder.writeSafeTx(
                vm,
                currentChainId,
                grantRoleFilename,
                "Grant MANAGER role to manager address",
                string(
                    abi.encodePacked(
                        "Chain ",
                        vm.toString(currentChainId),
                        ": grant MANAGER role to ",
                        vm.toString(chainConfig.manager),
                        " on NAVCalculator and BridgeEscrow. ",
                        "Execute this transaction AFTER the initialize-proxies transaction has completed. ",
                        "NAV proxy: ",
                        vm.toString(navProxy),
                        ", Bridge proxy: ",
                        vm.toString(bridgeProxy)
                    )
                ),
                chainConfig.safeMultisig,
                grantRoleTxs
            );

            console2.log("\n=== Transaction File 2 Generated: Grant MANAGER Role ===");
            console2.log("File: safe-transactions/", grantRoleFilename);
            console2.log("This file contains 2 transactions:");
            console2.log("  1. CALL: NAVCalculator.grantRole(MANAGER, ", chainConfig.manager, ")");
            console2.log("  2. CALL: BridgeEscrow.grantRole(MANAGER, ", chainConfig.manager, ")");
            console2.log(
                "\n[IMPORTANT] Execute the initialize-proxies transaction FIRST, then execute this grant-role transaction."
            );
        } else {
            console2.log("\n[INFO] No manager address configured, skipping grantRole transaction file.");
        }

        // Note: All operations are CALL (0), no DELEGATECALL needed

        console2.log("\n[NOTE] Proxies must be deployed first via 02a_DeployProxies.s.sol (with placeholder impl).");
        console2.log("\n=== Safe CLI Commands (Execute in Order) ===");
        string memory upgradeCommand = string(
            abi.encodePacked(
                "safe-cli tx-builder ",
                vm.toString(chainConfig.safeMultisig),
                " ",
                chainConfig.rpc,
                " ./safe-transactions/",
                upgradeFilename,
                " --private-key <KEY1> --private-key <KEY2> [--non-interactive]"
            )
        );
        console2.log("1. First, execute upgrade & initialize:");
        console2.log("   ", upgradeCommand);
        if (chainConfig.manager != address(0)) {
            string memory grantRoleCommand = string(
                abi.encodePacked(
                    "safe-cli tx-builder ",
                    vm.toString(chainConfig.safeMultisig),
                    " ",
                    chainConfig.rpc,
                    " ./safe-transactions/",
                    string(abi.encodePacked(vm.toString(currentChainId), "-grant-manager-role.json")),
                    " --private-key <KEY1> --private-key <KEY2> [--non-interactive]"
                )
            );
            console2.log("2. Then, execute grant role:");
            console2.log("   ", grantRoleCommand);
        }
        console2.log("\n[INFO] These transaction files contain multiple individual transactions (not MultiSend).");
        console2.log("  The Safe UI will execute them as a batch. All operations use CALL (no DELEGATECALL required).");
        console2.log("\n  To simulate transactions before submission, run:");
        console2.log("    forge test --match-path script/test/SimulateSafeTransactions.fork.t.sol --fork-url <RPC_URL>");

        console2.log("\nProxy addresses (from deployment config):");
        console2.log("  NAVCalculator proxy:", navProxy);
        console2.log("  BridgeEscrow proxy:", bridgeProxy);
        console2.log(
            "\nRun this script per chain (--chain-id <id>), then execute the transactions on that chain in order."
        );
    }
}
