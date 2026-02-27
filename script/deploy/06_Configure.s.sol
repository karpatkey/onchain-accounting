// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";
import {MANAGER} from "../../src/constants.sol";

/// @title Configure
/// @notice Post-deployment configuration for NAVCalculator and BridgeEscrow
/// @dev Generates Safe transaction batches for initial configuration
contract Configure is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Post-Deployment Configuration ===");

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

        // Build configuration transactions
        SafeTxBuilder.Transaction[] memory transactions = _buildConfigTransactions(navProxy, bridgeProxy);

        if (transactions.length == 0) {
            console2.log("No configuration needed (check chain config for initial setup)");
            return;
        }

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-configure.json"));

        writeSafeTx(
            filename,
            "Initial Configuration",
            "Configures NAVCalculator and BridgeEscrow with initial assets, adapters, and roles",
            transactions
        );

        console2.log("\n=== Configuration Instructions ===");
        console2.log("1. Review the generated Safe transaction:", filename);
        console2.log("2. Go to Safe UI: https://app.safe.global");
        console2.log("3. Select your Safe:", chainConfig.safeMultisig);
        console2.log("4. New Transaction -> Transaction Builder -> Import JSON");
        console2.log("5. Upload file:", filename);
        console2.log("6. Review and execute the transaction");
        console2.log("===================================");
    }

    function _buildConfigTransactions(address navProxy, address bridgeProxy)
        internal
        view
        returns (SafeTxBuilder.Transaction[] memory)
    {
        // Count transactions needed
        uint256 txCount = 0;

        // 1. Grant MANAGER_ROLE to manager address on NAVCalculator
        if (chainConfig.manager != address(0) && navProxy != address(0)) {
            txCount++;
        }

        // 2. Add balance oracles to NAVCalculator (from deployed adapters)
        uint256 balanceOracleCount = _countDeployedBalanceAdapters();
        txCount += balanceOracleCount;

        // 3. Authorize bridge adapters in BridgeEscrow
        uint256 bridgeAdapterCount = _countDeployedBridgeAdapters();
        txCount += bridgeAdapterCount;

        // Allocate transaction array
        SafeTxBuilder.Transaction[] memory transactions = new SafeTxBuilder.Transaction[](txCount);
        uint256 txIndex = 0;

        // Build transactions

        // 1. Grant MANAGER_ROLE
        if (chainConfig.manager != address(0) && navProxy != address(0)) {
            bytes memory grantRoleData =
                abi.encodeWithSignature("grantRole(bytes32,address)", MANAGER, chainConfig.manager);
            transactions[txIndex] = SafeTxBuilder.Transaction({
                to: navProxy,
                value: 0,
                data: grantRoleData,
                operation: 0 // CALL
            });
            txIndex++;
            console2.log("Added transaction: Grant MANAGER_ROLE to", chainConfig.manager);
        }

        // 2. Add balance oracles
        txIndex = _addBalanceOracleTransactions(transactions, txIndex, navProxy);

        // 3. Authorize bridge adapters
        txIndex = _addBridgeAdapterTransactions(transactions, txIndex, bridgeProxy);

        // Resize array to actual count (in case some adapters weren't deployed)
        if (txIndex < transactions.length) {
            SafeTxBuilder.Transaction[] memory resized = new SafeTxBuilder.Transaction[](txIndex);
            for (uint256 i = 0; i < txIndex; i++) {
                resized[i] = transactions[i];
            }
            return resized;
        }

        return transactions;
    }

    function _countDeployedBalanceAdapters() internal view returns (uint256 count) {
        // Count enabled adapters that have been deployed
        string[] memory adapterNames = new string[](9);
        adapterNames[0] = "AaveV3_USDC";
        adapterNames[1] = "AaveV3_WETH";
        adapterNames[2] = "CompoundV3_USDC";
        adapterNames[3] = "CompoundV3_WETH";
        adapterNames[4] = "SparkLend_USDC";
        adapterNames[5] = "MorphoBlue_USDC";
        adapterNames[6] = "GMX_GLP";
        adapterNames[7] = "DaiDsr";
        adapterNames[8] = "SkySavingsUsds";
        // ERC20Default is created in NAVCalculator.initialize() and already registered; address written by 02_DeployProxies

        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) {
                address deployed = _readAdapterDeployed("balanceAdapters", adapterNames[i]);
                if (deployed != address(0)) {
                    count++;
                }
            }
        }
    }

    function _countDeployedBridgeAdapters() internal view returns (uint256 count) {
        // Count enabled bridge adapters that have been deployed
        string[] memory adapterNames = new string[](6);
        adapterNames[0] = "CCIP";
        adapterNames[1] = "Across";
        adapterNames[2] = "Stargate";
        adapterNames[3] = "Gnosis";
        adapterNames[4] = "CCTP";
        adapterNames[5] = "Superchain";

        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", adapterNames[i])) {
                address deployed = _readAdapterDeployed("bridgeAdapters", adapterNames[i]);
                if (deployed != address(0)) {
                    count++;
                }
            }
        }
    }

    function _addBalanceOracleTransactions(
        SafeTxBuilder.Transaction[] memory transactions,
        uint256 startIndex,
        address navProxy
    ) internal view returns (uint256 nextIndex) {
        if (navProxy == address(0)) {
            return startIndex;
        }

        uint256 txIndex = startIndex;
        string[] memory adapterNames = new string[](9);
        adapterNames[0] = "AaveV3_USDC";
        adapterNames[1] = "AaveV3_WETH";
        adapterNames[2] = "CompoundV3_USDC";
        adapterNames[3] = "CompoundV3_WETH";
        adapterNames[4] = "SparkLend_USDC";
        adapterNames[5] = "MorphoBlue_USDC";
        adapterNames[6] = "GMX_GLP";
        adapterNames[7] = "DaiDsr";
        adapterNames[8] = "SkySavingsUsds";
        // ERC20Default is already registered in NAVCalculator.initialize(), not added via Configure

        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) {
                address deployed = _readAdapterDeployed("balanceAdapters", adapterNames[i]);
                if (deployed != address(0)) {
                    bytes memory addOracleData = abi.encodeWithSignature("addBalanceOracle(address)", deployed);
                    transactions[txIndex] = SafeTxBuilder.Transaction({
                        to: navProxy,
                        value: 0,
                        data: addOracleData,
                        operation: 0 // CALL
                    });
                    txIndex++;
                    console2.log("Added transaction: Add balance oracle", adapterNames[i], "at", deployed);
                }
            }
        }

        return txIndex;
    }

    function _addBridgeAdapterTransactions(
        SafeTxBuilder.Transaction[] memory transactions,
        uint256 startIndex,
        address bridgeProxy
    ) internal view returns (uint256 nextIndex) {
        if (bridgeProxy == address(0)) {
            return startIndex;
        }

        uint256 txIndex = startIndex;
        string[] memory adapterNames = new string[](6);
        adapterNames[0] = "CCIP";
        adapterNames[1] = "Across";
        adapterNames[2] = "Stargate";
        adapterNames[3] = "Gnosis";
        adapterNames[4] = "CCTP";
        adapterNames[5] = "Superchain";

        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", adapterNames[i])) {
                address deployed = _readAdapterDeployed("bridgeAdapters", adapterNames[i]);
                if (deployed != address(0)) {
                    (bool hasCallback, bytes4 selector) =
                        ConfigReader.readAdapterCallbackSelector(vm, currentChainId, "bridgeAdapters", adapterNames[i]);
                    bytes memory authorizeData;
                    if (hasCallback && selector != bytes4(0)) {
                        authorizeData =
                            abi.encodeWithSignature("authorizeAdapterWithCallback(address,bytes4)", deployed, selector);
                        console2.log(
                            "Added transaction: Authorize bridge adapter (with callback)",
                            adapterNames[i],
                            "at",
                            deployed
                        );
                    } else {
                        authorizeData = abi.encodeWithSignature("authorizeAdapter(address)", deployed);
                        console2.log("Added transaction: Authorize bridge adapter", adapterNames[i], "at", deployed);
                    }
                    transactions[txIndex] = SafeTxBuilder.Transaction({
                        to: bridgeProxy,
                        value: 0,
                        data: authorizeData,
                        operation: 0 // CALL
                    });
                    txIndex++;
                }
            }
        }

        return txIndex;
    }

    /// @notice Helper to read deployed adapter address
    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        string memory deployed = ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, "deployed");
        if (bytes(deployed).length == 0) {
            return address(0);
        }
        address addr = vm.parseAddress(deployed);
        return addr == address(0) ? address(0) : addr;
    }
}
