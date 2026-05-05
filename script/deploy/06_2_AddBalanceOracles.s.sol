// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {IBalances} from "../../src/balances/IBalances.sol";
import {console2} from "forge-std/console2.sol";

/// @title AddBalanceOracles
/// @notice EOA-compatible script that calls addBalanceOracle() on NAVCalculator for each deployed balance adapter.
/// @dev
///   - Caller must hold MANAGER role on the NAVCalculator proxy (set chainConfig.manager = EOA before running).
///   - Reads deployed adapter addresses from the chain config (same adapter list as 06_Configure.s.sol).
///   - Idempotent: checks isOracleRegistered() before calling addBalanceOracle() and skips already-registered adapters.
///   - ERC20Default is created by NAVCalculator.initialize() and is not re-added here.
///   - Prerequisite: run 04_DeployBalanceAdapters.s.sol first to populate adapter "deployed" addresses in config.
///   - Run with: forge script script/deploy/06_2_AddBalanceOracles.s.sol --rpc-url $RPC_URL --account $DEPLOYER_NAME --broadcast
contract AddBalanceOracles is BaseDeployScript {
    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        require(navProxy != address(0), "NAVCalculator not deployed. Run 02_2_DeployNAVProxy.s.sol first.");
        require(navProxy.code.length > 0, "No code at NAVCalculator proxy. Provide --rpc-url.");

        console2.log("\n=== Add Balance Oracles (EOA broadcast) ===");
        console2.log("NAVCalculator proxy:", navProxy);

        string[] memory adapterNames = _balanceAdapterNames();
        uint256 toAdd;
        uint256 alreadyRegistered;
        uint256 notDeployed;

        // Dry-run pass: report status of each adapter
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) continue;

            address deployed = _readAdapterDeployed(adapterNames[i]);
            if (deployed == address(0)) {
                console2.log("  SKIP (not deployed):", adapterNames[i]);
                notDeployed++;
                continue;
            }

            if (IBalances(navProxy).isOracleRegistered(deployed)) {
                console2.log("  ALREADY REGISTERED:", adapterNames[i], deployed);
                alreadyRegistered++;
            } else {
                console2.log("  TO ADD:", adapterNames[i], deployed);
                toAdd++;
            }
        }

        console2.log("");
        console2.log("--- Summary ---");
        console2.log("  Already registered:", alreadyRegistered);
        console2.log("  Not deployed (skipped):", notDeployed);
        console2.log("  To add:", toAdd);

        if (toAdd == 0) {
            console2.log("Nothing to add. Exiting.");
            return;
        }

        // Broadcast pass: add each adapter not yet registered
        vm.startBroadcast();
        uint256 added;
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) continue;

            address deployed = _readAdapterDeployed(adapterNames[i]);
            if (deployed == address(0)) continue;
            if (IBalances(navProxy).isOracleRegistered(deployed)) continue;

            (bool ok, bytes memory data) = navProxy.call(abi.encodeWithSignature("addBalanceOracle(address)", deployed));
            if (!ok) {
                string memory errMsg = _decodeRevert(data);
                revert(string(abi.encodePacked("addBalanceOracle failed for ", adapterNames[i], ": ", errMsg)));
            }
            console2.log("[OK] Added balance oracle:", adapterNames[i], deployed);
            added++;
        }
        vm.stopBroadcast();

        console2.log("");
        console2.log("[OK] Added", added, "balance oracle(s).");
    }

    /// @notice Adapter name list — kept in sync with 06_Configure.s.sol._balanceAdapterNames().
    ///         ERC20Default is excluded (created by NAVCalculator.initialize(), always registered).
    function _balanceAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](49);
        uint256 i = 0;
        names[i++] = "AaveV3_Core";
        names[i++] = "AaveV3_Prime";
        names[i++] = "AaveV3_Arbitrum";
        names[i++] = "AaveV3_Base";
        names[i++] = "AaveV3_Optimism";
        names[i++] = "AaveV3_Gnosis";
        names[i++] = "SparkLend";
        names[i++] = "AaveV3SafetyModule";
        names[i++] = "Cap";
        names[i++] = "MorphoVault_kpkETHPrime_V1";
        names[i++] = "MorphoVault_kpkETHPrime_V2";
        names[i++] = "MorphoVault_kpkUSDCPrime_V1";
        names[i++] = "MorphoVault_kpkUSDCPrime_V2";
        names[i++] = "MorphoVault_kpkUSDCYieldV1";
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
        names[i++] = "GearboxMarket_kpkWETH";
        names[i++] = "GearboxMarket_kpkwstETH";
        names[i++] = "BalancerV3_rETH_WETH";
        names[i++] = "BalancerV3_GHO_USDT_USDC"; // Mainnet — USD Alpha
        names[i++] = "BalancerV3_GHO_USDC_USDT"; // Arbitrum — USD Alpha
        names[i++] = "BalancerV3_GHO_USDC"; // Base — USD Alpha
        names[i++] = "Aura_rETH_WETH";
        names[i++] = "Aura_GHO_USDT_USDC";
        names[i++] = "Aura_GHO_USDC_USDT";
        names[i++] = "Aura_GHO_USDC";
        names[i++] = "Curve_weETH_WETH";
        names[i++] = "Curve_crvUSD_USDC";
        names[i++] = "Curve_crvUSD_USDT";
        names[i++] = "Curve_RLUSD_USDC";
        names[i++] = "Convex_weETH_WETH";
        names[i++] = "Convex_crvUSD_USDC";
        names[i++] = "Convex_crvUSD_USDT";
        names[i++] = "Convex_RLUSD_USDC";
        names[i++] = "StaderWithdrawalQueue";
        names[i++] = "StakeWiseV3OsToken_ETH";
        names[i++] = "StakeWiseV3Vault_Genesis";
    }

    function _readAdapterDeployed(string memory adapterName) internal view returns (address) {
        string memory deployed =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "deployed");
        if (bytes(deployed).length == 0) return address(0);
        address addr = vm.parseAddress(deployed);
        return addr == address(0) ? address(0) : addr;
    }

    function _decodeRevert(bytes memory data) internal pure returns (string memory) {
        if (data.length >= 68 && data[0] == 0x08 && data[1] == 0xc3 && data[2] == 0x79 && data[3] == 0xa0) {
            uint256 len;
            assembly {
                len := mload(add(add(data, 32), 36))
            }
            if (data.length >= 68 + 32 + len) {
                bytes memory msgBytes = new bytes(len);
                for (uint256 i = 0; i < len; i++) {
                    msgBytes[i] = data[i + 68 + 32];
                }
                return string(msgBytes);
            }
        }
        return data.length > 0 ? "custom error (non-string revert)" : "unknown";
    }
}
