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

        // 2. Add balance oracles to NAVCalculator (from deployed adapters), plus one setMetaInstances TX per
        //    deployed meta-adapter that has a configured instance set (ADR 0010).
        uint256 balanceOracleCount = _countDeployedBalanceAdapters();
        txCount += balanceOracleCount;
        txCount += _countMetaInstanceTransactions();

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
        string[] memory adapterNames = _balanceAdapterNames();
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) {
                address deployed = _readAdapterDeployed("balanceAdapters", adapterNames[i]);
                if (deployed != address(0)) {
                    count++;
                }
            }
        }
    }

    /// @notice Counts the extra setMetaInstances transactions needed (one per deployed meta-adapter with instances).
    function _countMetaInstanceTransactions() internal view returns (uint256 count) {
        string[] memory adapterNames = _balanceAdapterNames();
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) {
                address deployed = _readAdapterDeployed("balanceAdapters", adapterNames[i]);
                if (deployed != address(0) && _readMetaInstances(adapterNames[i]).length > 0) {
                    count++;
                }
            }
        }
    }

    /// @notice Shared adapter name list — kept in sync with `04_DeployBalanceAdapters.s.sol.run()`.
    /// Each chain's config enables the subset that applies; entries not in a chain's config just
    /// return false from isAdapterEnabled and are skipped. ERC20Default is created by
    /// NAVCalculator.initialize() so it's already registered; it is not added here.
    function _balanceAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](60);
        uint256 i = 0;
        // Aave V3 instances meta-adapter (ADR 0010): DataProvider set configured via setMetaInstances
        names[i++] = "AaveV3InstancesMeta";
        // Aave V3 (one per market)
        names[i++] = "AaveV3_Core";
        names[i++] = "AaveV3_Prime";
        names[i++] = "AaveV3_Arbitrum";
        names[i++] = "AaveV3_Base";
        names[i++] = "AaveV3_Optimism";
        names[i++] = "AaveV3_Gnosis";
        // Spark, stkGHO, Cap (Mainnet)
        names[i++] = "SparkLend";
        names[i++] = "AaveV3SafetyModule";
        names[i++] = "Cap";
        // Morpho Vaults
        names[i++] = "MorphoVault_kpkETHPrime_V1";
        names[i++] = "MorphoVault_kpkETHPrime_V2";
        names[i++] = "MorphoVault_kpkUSDCPrime_V1";
        names[i++] = "MorphoVault_kpkUSDCPrime_V2";
        names[i++] = "MorphoVault_kpkUSDCYieldV1";
        // Morpho Vaults meta-adapter (ADR 0010): instance set configured via setMetaInstances
        names[i++] = "MorphoVaultsMeta";
        // Morpho Markets meta-adapter (ADR 0010): marketId set configured via setMetaInstances (metaInstancesRaw)
        names[i++] = "MorphoMarketsMeta";
        // Morpho Markets
        names[i++] = "MorphoMarket_wstETH_USDC";
        names[i++] = "MorphoMarket_cbBTC_USDC";
        names[i++] = "MorphoMarket_wstUSR_USDC";
        names[i++] = "MorphoMarket_ETHPlus_USDC";
        names[i++] = "MorphoMarket_WBTC_USDC";
        names[i++] = "MorphoMarket_RLP_USDC";
        names[i++] = "MorphoMarket_syrupUSDC_USDC";
        names[i++] = "MorphoMarket_sUSDS_USDT";
        names[i++] = "MorphoMarket_sUSDS_USDC";
        names[i++] = "MorphoMarket_ETHPlus_WETH";
        names[i++] = "MorphoMarket_wstETH_WETH";
        names[i++] = "MorphoMarket_weETH_WETH";
        names[i++] = "MorphoMarket_rsETH_WETH";
        names[i++] = "MorphoMarket_cbETH_USDC";
        // Gearbox
        names[i++] = "GearboxMarket_kpkWETH";
        names[i++] = "GearboxMarket_kpkwstETH";
        // Balancer V3 meta-adapters (ADR 0010): pool / gauge sets configured via setMetaInstances
        names[i++] = "BalancerV3PoolsMeta";
        names[i++] = "BalancerV3GaugesMeta";
        // Balancer V3 (per-pool — superseded by the meta-adapters above)
        names[i++] = "BalancerV3_rETH_WETH";
        names[i++] = "BalancerV3_GHO_USDT_USDC"; // Mainnet — USD Alpha
        names[i++] = "BalancerV3_GHO_USDC_USDT"; // Arbitrum — USD Alpha
        names[i++] = "BalancerV3_GHO_USDC"; // Base — USD Alpha
        // Aura
        names[i++] = "Aura_rETH_WETH";
        names[i++] = "Aura_GHO_USDT_USDC";
        names[i++] = "Aura_GHO_USDC_USDT";
        names[i++] = "Aura_GHO_USDC";
        // Curve
        names[i++] = "Curve_weETH_WETH";
        names[i++] = "Curve_crvUSD_USDC";
        names[i++] = "Curve_crvUSD_USDT";
        names[i++] = "Curve_RLUSD_USDC";
        // Convex
        names[i++] = "Convex_weETH_WETH";
        names[i++] = "Convex_crvUSD_USDC";
        names[i++] = "Convex_crvUSD_USDT";
        names[i++] = "Convex_RLUSD_USDC";
        // Stader (Mainnet)
        names[i++] = "StaderWithdrawalQueue";
        // Kelp DAO (Mainnet)
        names[i++] = "KelpWithdrawalQueue";
        // Lido (Mainnet)
        names[i++] = "LidoWithdrawalQueue";
        // StakeWise V3 (Mainnet)
        names[i++] = "StakeWiseV3OsToken_ETH";
        names[i++] = "StakeWiseV3Vault_Genesis";
        // Uniswap / PancakeSwap meta-adapters (ADR 0010): pool/pair sets configured via setMetaInstances
        names[i++] = "UniswapV3PoolsMeta"; // Mainnet
        names[i++] = "UniswapV2PoolsMeta";
        names[i++] = "PancakeSwapV3PoolsMeta"; // Base
        names[i++] = "PancakeSwapV2PoolsMeta"; // BSC
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
        string[] memory adapterNames = _balanceAdapterNames();

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

                    // Meta-adapters (ADR 0010): configure their instance set on NAVCalculator in the same bundle.
                    bytes32[] memory instances = _readMetaInstances(adapterNames[i]);
                    if (instances.length > 0) {
                        bytes memory setData =
                            abi.encodeWithSignature("setMetaInstances(address,bytes32[])", deployed, instances);
                        transactions[txIndex] = SafeTxBuilder.Transaction({
                            to: navProxy,
                            value: 0,
                            data: setData,
                            operation: 0 // CALL
                        });
                        txIndex++;
                        console2.log("Added transaction: Set meta instances for", adapterNames[i]);
                    }
                }
            }
        }

        return txIndex;
    }

    /// @notice Reads a meta-adapter's configured instance coordinates from config: `metaInstances` (address list,
    ///         widened to bytes32 — for vault/pool-address adapters) unioned with `metaInstancesRaw` (raw bytes32
    ///         list — for marketId-keyed adapters like MorphoMarketsMeta). An adapter uses one or the other.
    /// @return instances The instance coordinates (empty for non-meta adapters or when unset).
    function _readMetaInstances(string memory adapterName) internal view returns (bytes32[] memory instances) {
        address[] memory addrs =
            ConfigReader.readAdapterAddressArray(vm, currentChainId, "balanceAdapters", adapterName, "metaInstances");
        bytes32[] memory raw = ConfigReader.readAdapterBytes32Array(
            vm, currentChainId, "balanceAdapters", adapterName, "metaInstancesRaw"
        );

        instances = new bytes32[](addrs.length + raw.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            instances[i] = bytes32(uint256(uint160(addrs[i])));
        }
        for (uint256 i = 0; i < raw.length; i++) {
            instances[addrs.length + i] = raw[i];
        }
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
