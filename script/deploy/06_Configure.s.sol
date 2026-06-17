// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {IBalances} from "../../src/balances/IBalances.sol";
import {IMetaBalanceAdapter} from "../../src/balances/IMetaBalanceAdapter.sol";
import {IBridgeEscrow} from "../../src/bridge/IBridgeEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {MANAGER} from "../../src/constants.sol";
import {console2} from "forge-std/console2.sol";

/// @title Configure
/// @notice Post-deployment configuration for NAVCalculator and BridgeEscrow, broadcast directly by the deployer EOA.
/// @dev EOA flow (no Safe): the caller must hold DEFAULT_ADMIN_ROLE + MANAGER on the proxies (granted by the atomic
///      deployer in 02 when chainConfig.admin == chainConfig.manager == the deployer EOA). For each enabled+deployed
///      balance adapter it calls `addBalanceAdapters` (idempotent) and, for meta-adapters (ADR 0010), `addMetaInstances`/`removeMetaInstances`
///      with the configured instance set; for each enabled+deployed bridge adapter it authorizes it on BridgeEscrow.
///      Idempotent: skips adapters already registered and adapters already authorized, so it can be re-run safely.
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
            _configureBalanceAdapters(navProxy);
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
    function _configureBalanceAdapters(address navProxy) internal {
        string[] memory adapterNames = _balanceAdapterNames();
        uint256 added;
        uint256 configured;
        for (uint256 i = 0; i < adapterNames.length; i++) {
            if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterNames[i])) continue;

            address deployed = _readAdapterDeployed("balanceAdapters", adapterNames[i]);
            if (deployed == address(0)) continue;

            // Meta-adapters (those implementing IMetaBalanceAdapter) register via addMetaBalanceAdapter (atomic
            // register + seed), since addBalanceAdapters rejects them; plain adapters use addBalanceAdapters. The
            // adapter type is decided by the interface (ERC165), not by whether instances are configured, so a
            // meta-adapter with an empty configured set still registers correctly (seeded later via the reconcile).
            bytes32[] memory desired = _readMetaInstances(adapterNames[i]);
            bool isMeta = ERC165Checker.supportsInterface(deployed, type(IMetaBalanceAdapter).interfaceId);

            if (!IBalances(navProxy).isAdapterRegistered(deployed)) {
                bytes memory regData;
                if (isMeta) {
                    regData = abi.encodeWithSignature("addMetaBalanceAdapter(address,bytes32[])", deployed, desired);
                } else {
                    address[] memory one = new address[](1);
                    one[0] = deployed;
                    regData = abi.encodeWithSignature("addBalanceAdapters(address[])", one);
                }
                (bool ok, bytes memory data) = navProxy.call(regData);
                if (!ok) {
                    revert(string(abi.encodePacked("register failed for ", adapterNames[i], ": ", _decodeRevert(data))));
                }
                console2.log("[OK] Added balance adapter:", adapterNames[i], deployed);
                added++;
            } else {
                console2.log("[SKIP] Already registered:", adapterNames[i], deployed);
            }

            // Meta-adapters (ADR 0010): reconcile the on-chain set to the configured set. addMetaInstances /
            // removeMetaInstances are incremental and all-or-nothing, so we diff against the current set (rather
            // than blindly add) to stay idempotent across re-runs: remove coordinates no longer in config, then
            // add the ones not yet present. For a meta-adapter just registered via addMetaBalanceAdapter the set is
            // already seeded, so the diff below is a no-op.
            bytes32[] memory current = IBalances(navProxy).getMetaInstances(deployed);
            bytes32[] memory toRemove = _metaDiff(current, desired);
            bytes32[] memory toAdd = _metaDiff(desired, current);

            if (toRemove.length > 0) {
                (bool ok, bytes memory data) =
                    navProxy.call(abi.encodeWithSignature("removeMetaInstances(address,bytes32[])", deployed, toRemove));
                if (!ok) {
                    revert(
                        string(
                            abi.encodePacked(
                                "removeMetaInstances failed for ", adapterNames[i], ": ", _decodeRevert(data)
                            )
                        )
                    );
                }
            }
            if (toAdd.length > 0) {
                (bool ok, bytes memory data) =
                    navProxy.call(abi.encodeWithSignature("addMetaInstances(address,bytes32[])", deployed, toAdd));
                if (!ok) {
                    revert(
                        string(
                            abi.encodePacked("addMetaInstances failed for ", adapterNames[i], ": ", _decodeRevert(data))
                        )
                    );
                }
            }
            if (toAdd.length > 0 || toRemove.length > 0) {
                console2.log("[OK] Reconciled meta instances for:", adapterNames[i], desired.length);
                configured++;
            }
        }
        console2.log("--- Balance adapters: added", added, "; meta sets configured", configured);
    }

    /// @notice Returns the coordinates in `a` that are not present in `b` (set difference a \ b).
    function _metaDiff(bytes32[] memory a, bytes32[] memory b) private pure returns (bytes32[] memory diff) {
        bytes32[] memory tmp = new bytes32[](a.length);
        uint256 count;
        for (uint256 i = 0; i < a.length; i++) {
            bool found;
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i] == b[j]) {
                    found = true;
                    break;
                }
            }
            if (!found) tmp[count++] = a[i];
        }
        diff = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            diff[i] = tmp[i];
        }
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

    /// @notice Shared adapter name list — every name `04_DeployBalanceAdapters.s.sol.run()` deploys must
    /// appear here, or the adapter deploys but never registers on NAVCalculator. Each chain's config enables
    /// the subset that applies; entries not in a chain's config just return false from isAdapterEnabled and
    /// are skipped. ERC20Default is created by NAVCalculator.initialize() so it's already registered; it is
    /// not added here. A few entries are intentionally **list-only** — their adapter contract + 04 dispatch
    /// branch exist but `04.run()` has no `_deployIfEnabled` for them yet (currently `UniswapV2PoolsMeta`).
    /// They sit here registration-ready; when you wire the first such instance, add the `_deployIfEnabled`
    /// call to `04.run()` so deploy and registration land together.
    function _balanceAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](31);
        uint256 i = 0;
        // Aave V2 instances meta-adapter (ADR 0010): DataProvider set configured via addMetaInstances/removeMetaInstances
        names[i++] = "AaveV2InstancesMeta";
        // Aave V3 instances meta-adapter (ADR 0010): DataProvider set configured via addMetaInstances/removeMetaInstances.
        // The legacy per-market AaveV3_Core/_Prime/_Arbitrum/_Base/_Optimism/_Gnosis are superseded by
        // this meta (disabled in chain config, no deploy path in 04) — full-meta, do not re-add.
        names[i++] = "AaveV3InstancesMeta";
        // Spark, stkGHO, Umbrella, Cap (Mainnet)
        names[i++] = "SparkLend";
        names[i++] = "AaveV3SafetyModule";
        names[i++] = "AaveUmbrella";
        names[i++] = "Cap";
        // Compound V3 meta-adapter (ADR 0010): comet set configured via addMetaInstances/removeMetaInstances
        names[i++] = "CompoundV3CometsMeta";
        // Fluid meta-adapters (ADR 0010): fToken / T1-vault sets configured via addMetaInstances/removeMetaInstances
        names[i++] = "FluidFTokensMeta";
        names[i++] = "FluidVaultsMeta";
        // Morpho Vaults meta-adapter (ADR 0010): instance set configured via addMetaInstances/removeMetaInstances
        names[i++] = "MorphoVaultsMeta";
        // Morpho Markets meta-adapter (ADR 0010): marketId set configured via addMetaInstances/removeMetaInstances (metaInstancesRaw)
        names[i++] = "MorphoMarketsMeta";
        // ERC-4626 wrappers (one thin adapter per wrapper; generic ERC4626WrapBalanceAdapter)
        names[i++] = "ERC4626Wrap_waEthLidoGHO";
        names[i++] = "ERC4626Wrap_sGHO";
        // Gearbox meta-adapter (ADR 0010): market set configured via addMetaInstances/removeMetaInstances
        names[i++] = "GearboxMarketsMeta";
        // Balancer V2/V3 meta-adapters (ADR 0010): pool / gauge sets configured via addMetaInstances/removeMetaInstances
        names[i++] = "BalancerV3PoolsMeta";
        names[i++] = "BalancerV3GaugesMeta";
        names[i++] = "BalancerV2PoolsMeta";
        names[i++] = "BalancerV2GaugesMeta";
        // Aura / Curve / Convex meta-adapters (ADR 0010): pool / gauge / rewarder sets configured via addMetaInstances/removeMetaInstances
        names[i++] = "AuraRewardsMeta";
        names[i++] = "CurvePoolsMeta";
        names[i++] = "CurveGaugesMeta";
        names[i++] = "ConvexRewardsMeta";
        // Merkl rewards (ADR 0007: trust-minimized proof-verified per-(user,token) cache)
        names[i++] = "MerklRewards";
        // Stader (Mainnet)
        names[i++] = "StaderWithdrawalQueue";
        // Kelp DAO (Mainnet)
        names[i++] = "KelpWithdrawalQueue";
        // Lido (Mainnet)
        names[i++] = "LidoWithdrawalQueue";
        // StakeWise V3 (Mainnet) — osETH itself is a Custom-priced ERC20 (osToken_PriceOracle), not a balance adapter
        names[i++] = "StakeWiseV3VaultsMeta"; // Meta-adapter (ADR 0010): vault set configured via addMetaInstances/removeMetaInstances
        // Uniswap / PancakeSwap meta-adapters (ADR 0010): pool/pair sets configured via addMetaInstances/removeMetaInstances
        names[i++] = "UniswapV3PoolsMeta"; // Mainnet
        names[i++] = "UniswapV2PoolsMeta"; // list-only: contract + 04 dispatch exist, but no _deployIfEnabled in 04.run() yet (see docstring)
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

        // The configured coordinates must be unique across `metaInstances` (addresses, widened) ∪ `metaInstancesRaw`
        // (raw bytes32). addMetaInstances is all-or-nothing and reverts DuplicateMetaInstance, so a duplicated
        // config entry surfaces as a clear, per-adapter reconcile failure ("addMetaInstances failed for <name>:
        // DuplicateMetaInstance") that must be corrected in config — it is a config error, not a transient. We do
        // NOT de-duplicate in-script: NAVCalculator runs near the EIP-170 limit and, under via-IR whole-program
        // optimization, adding the dedup loop here measurably grows NAVCalculator's own runtime bytecode past
        // 24,576 (see the EIP-170 note on the NAVCalculator contract).
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
