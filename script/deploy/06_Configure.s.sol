// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {IBalances} from "../../src/balances/IBalances.sol";
import {IBridgeEscrow} from "../../src/bridge/IBridgeEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title Configure
/// @notice Post-deployment configuration for NAVCalculator and BridgeEscrow, broadcast directly by the deployer EOA.
/// @dev EOA flow (no Safe): the caller must hold DEFAULT_ADMIN_ROLE + MANAGER on the proxies (granted by the atomic
///      deployer in 02 when chainConfig.admin == chainConfig.manager == the deployer EOA). For each enabled+deployed
///      balance adapter it calls `addBalanceOracle` (idempotent) and, for meta-adapters (ADR 0010), `setMetaInstances`
///      with the configured instance set; for each enabled+deployed bridge adapter it authorizes it on BridgeEscrow.
///      Idempotent: skips oracles already registered and adapters already authorized, so it can be re-run safely.
///      Run with: forge script script/deploy/06_Configure.s.sol --rpc-url $RPC_URL --account $DEPLOYER_NAME --broadcast
contract Configure is BaseDeployScript {
    function run() public override {
        setUp();
        validateAddresses();

        console2.log("\n=== Post-Deployment Configuration (EOA broadcast) ===");

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
        if (navProxy != address(0)) {
            require(navProxy.code.length > 0, "No code at NAVCalculator proxy. Provide --rpc-url.");
        }
        if (bridgeProxy != address(0)) {
            require(bridgeProxy.code.length > 0, "No code at BridgeEscrow proxy. Provide --rpc-url.");
        }

        vm.startBroadcast();
        if (navProxy != address(0)) {
            _ensureManager(navProxy);
            _configureBalanceOracles(navProxy);
        }
        if (bridgeProxy != address(0)) {
            _authorizeBridgeAdapters(bridgeProxy);
        }
        vm.stopBroadcast();

        console2.log("\n=== Configuration complete ===");
    }

    /// @notice Idempotently ensures `chainConfig.manager` holds MANAGER (covers the legacy 02 path that doesn't grant
    ///         it; the atomic path already did). Requires the caller to hold DEFAULT_ADMIN_ROLE.
    function _ensureManager(address navProxy) internal {
        address manager = chainConfig.manager;
        if (manager == address(0)) return;
        if (!IAccessControl(navProxy).hasRole(MANAGER, manager)) {
            IAccessControl(navProxy).grantRole(MANAGER, manager);
            console2.log("[OK] Granted MANAGER to:", manager);
        }
    }

    /// @notice Registers each enabled+deployed balance adapter on NAVCalculator (idempotent) and configures the
    ///         instance set for meta-adapters (ADR 0010).
    function _configureBalanceOracles(address navProxy) internal {
        string[] memory adapterNames = _balanceAdapterNames();
        uint256 added;
        uint256 configured;
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) continue;

            address deployed = _readAdapterDeployed("balanceAdapters", adapterNames[i]);
            if (deployed == address(0)) continue;

            if (!IBalances(navProxy).isOracleRegistered(deployed)) {
                (bool ok, bytes memory data) =
                    navProxy.call(abi.encodeWithSignature("addBalanceOracle(address)", deployed));
                if (!ok) {
                    revert(
                        string(
                            abi.encodePacked("addBalanceOracle failed for ", adapterNames[i], ": ", _decodeRevert(data))
                        )
                    );
                }
                console2.log("[OK] Added balance oracle:", adapterNames[i], deployed);
                added++;
            } else {
                console2.log("[SKIP] Already registered:", adapterNames[i], deployed);
            }

            // Meta-adapters (ADR 0010): (re)configure the instance set. setMetaInstances is a full replace, so it is
            // idempotent and safe to call on every run.
            bytes32[] memory instances = _readMetaInstances(adapterNames[i]);
            if (instances.length > 0) {
                (bool ok, bytes memory data) =
                    navProxy.call(abi.encodeWithSignature("setMetaInstances(address,bytes32[])", deployed, instances));
                if (!ok) {
                    revert(
                        string(
                            abi.encodePacked("setMetaInstances failed for ", adapterNames[i], ": ", _decodeRevert(data))
                        )
                    );
                }
                console2.log("[OK] Set meta instances for:", adapterNames[i], instances.length);
                configured++;
            }
        }
        console2.log("--- Balance oracles: added", added, "; meta sets configured", configured);
    }

    /// @notice Authorizes each enabled+deployed bridge adapter on BridgeEscrow (idempotent via isAuthorizedAdapter).
    function _authorizeBridgeAdapters(address bridgeProxy) internal {
        string[] memory adapterNames = _bridgeAdapterNames();
        uint256 authorized;
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "bridgeAdapters", adapterNames[i])) continue;

            address deployed = _readAdapterDeployed("bridgeAdapters", adapterNames[i]);
            if (deployed == address(0)) continue;
            if (IBridgeEscrow(bridgeProxy).isAuthorizedAdapter(deployed)) {
                console2.log("[SKIP] Bridge adapter already authorized:", adapterNames[i], deployed);
                continue;
            }

            (bool hasCallback, bytes4 selector) =
                ConfigReader.readAdapterCallbackSelector(vm, currentChainId, "bridgeAdapters", adapterNames[i]);
            bytes memory authorizeData = (hasCallback && selector != bytes4(0))
                ? abi.encodeWithSignature("authorizeAdapterWithCallback(address,bytes4)", deployed, selector)
                : abi.encodeWithSignature("authorizeAdapter(address)", deployed);
            (bool ok, bytes memory data) = bridgeProxy.call(authorizeData);
            if (!ok) {
                revert(
                    string(
                        abi.encodePacked(
                            "authorize bridge adapter failed for ", adapterNames[i], ": ", _decodeRevert(data)
                        )
                    )
                );
            }
            console2.log("[OK] Authorized bridge adapter:", adapterNames[i], deployed);
            authorized++;
        }
        console2.log("--- Bridge adapters authorized:", authorized);
    }

    /// @notice Shared adapter name list — kept in sync with `04_DeployBalanceAdapters.s.sol.run()`.
    /// Each chain's config enables the subset that applies; entries not in a chain's config just
    /// return false from isAdapterEnabled and are skipped. ERC20Default is created by
    /// NAVCalculator.initialize() so it's already registered; it is not added here.
    function _balanceAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](44);
        uint256 i = 0;
        // Aave V2 instances meta-adapter (ADR 0010): DataProvider set configured via setMetaInstances
        names[i++] = "AaveV2InstancesMeta";
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
        // Compound V3 meta-adapter (ADR 0010): comet set configured via setMetaInstances
        names[i++] = "CompoundV3CometsMeta";
        // Fluid meta-adapters (ADR 0010): fToken / T1-vault sets configured via setMetaInstances
        names[i++] = "FluidFTokensMeta";
        names[i++] = "FluidVaultsMeta";
        // Morpho Vaults meta-adapter (ADR 0010): instance set configured via setMetaInstances
        names[i++] = "MorphoVaultsMeta";
        // Morpho Markets meta-adapter (ADR 0010): marketId set configured via setMetaInstances (metaInstancesRaw)
        names[i++] = "MorphoMarketsMeta";
        // ERC-4626 wrappers (one thin adapter per wrapper; generic ERC4626WrapBalanceOracle)
        names[i++] = "ERC4626Wrap_waEthLidoGHO";
        names[i++] = "ERC4626Wrap_sGHO";
        // Gearbox meta-adapter (ADR 0010): market set configured via setMetaInstances
        names[i++] = "GearboxMarketsMeta";
        // Balancer V2/V3 meta-adapters (ADR 0010): pool / gauge sets configured via setMetaInstances
        names[i++] = "BalancerV3PoolsMeta";
        names[i++] = "BalancerV3GaugesMeta";
        names[i++] = "BalancerV2PoolsMeta";
        names[i++] = "BalancerV2GaugesMeta";
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
        // StakeWise V3 (Mainnet) — osETH itself is a Custom-priced ERC20 (osToken_PriceOracle), not a balance adapter
        names[i++] = "StakeWiseV3VaultsMeta"; // Meta-adapter (ADR 0010): vault set configured via setMetaInstances
        // Uniswap / PancakeSwap meta-adapters (ADR 0010): pool/pair sets configured via setMetaInstances
        names[i++] = "UniswapV3PoolsMeta"; // Mainnet
        names[i++] = "UniswapV2PoolsMeta";
        names[i++] = "PancakeSwapV3PoolsMeta"; // Base
        names[i++] = "PancakeSwapV2PoolsMeta"; // BSC
    }

    /// @notice Bridge adapter name list — kept in sync with `05_DeployBridgeAdapters.s.sol`.
    function _bridgeAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](6);
        names[0] = "CCIP";
        names[1] = "Across";
        names[2] = "Stargate";
        names[3] = "Gnosis";
        names[4] = "CCTP";
        names[5] = "Superchain";
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

    /// @notice Decodes a standard Error(string) revert payload for readable failure messages.
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
