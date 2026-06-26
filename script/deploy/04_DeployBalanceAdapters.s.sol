// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import balance adapters
import {AaveV3InstancesMetaBalanceAdapter} from "../../src/balances/protocols/AaveV3InstancesMetaBalanceAdapter.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "../../src/balances/protocols/CompoundV3CometsMetaBalanceAdapter.sol";
import {SparkLendBalanceAdapter} from "../../src/balances/protocols/SparkLendBalanceAdapter.sol";
import {MorphoVaultsMetaBalanceAdapter} from "../../src/balances/protocols/MorphoVaultsMetaBalanceAdapter.sol";
import {MorphoMarketsMetaBalanceAdapter} from "../../src/balances/protocols/MorphoMarketsMetaBalanceAdapter.sol";
import {ERC4626WrapBalanceAdapter} from "../../src/balances/protocols/ERC4626WrapBalanceAdapter.sol";
import {GearboxMarketsMetaBalanceAdapter} from "../../src/balances/protocols/GearboxMarketsMetaBalanceAdapter.sol";
import {EulerVaultsMetaBalanceAdapter} from "../../src/balances/protocols/EulerVaultsMetaBalanceAdapter.sol";
import {CapBalanceAdapter} from "../../src/balances/protocols/CapBalanceAdapter.sol";
import {CurvePoolsMetaBalanceAdapter} from "../../src/balances/protocols/curve/CurvePoolsMetaBalanceAdapter.sol";
import {CurveGaugesMetaBalanceAdapter} from "../../src/balances/protocols/curve/CurveGaugesMetaBalanceAdapter.sol";
import {ConvexRewardsMetaBalanceAdapter} from "../../src/balances/protocols/ConvexRewardsMetaBalanceAdapter.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "../../src/balances/protocols/AaveV3SafetyModuleBalanceAdapter.sol";
import {AaveUmbrellaBalanceAdapter} from "../../src/balances/protocols/AaveUmbrellaBalanceAdapter.sol";
import {
    BalancerV3PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/balancer/BalancerV3PoolsMetaBalanceAdapter.sol";
import {
    BalancerV3GaugesMetaBalanceAdapter
} from "../../src/balances/protocols/balancer/BalancerV3GaugesMetaBalanceAdapter.sol";
import {
    BalancerV2PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/balancer/BalancerV2PoolsMetaBalanceAdapter.sol";
import {
    BalancerV2GaugesMetaBalanceAdapter
} from "../../src/balances/protocols/balancer/BalancerV2GaugesMetaBalanceAdapter.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "../../src/balances/protocols/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {FluidFTokensMetaBalanceAdapter} from "../../src/balances/protocols/FluidFTokensMetaBalanceAdapter.sol";
import {FluidVaultsMetaBalanceAdapter} from "../../src/balances/protocols/FluidVaultsMetaBalanceAdapter.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "../../src/balances/protocols/StaderWithdrawalQueueBalanceAdapter.sol";
import {KelpWithdrawalQueueBalanceAdapter} from "../../src/balances/protocols/KelpWithdrawalQueueBalanceAdapter.sol";
import {LidoWithdrawalQueueBalanceAdapter} from "../../src/balances/protocols/LidoWithdrawalQueueBalanceAdapter.sol";
import {EthenaCooldownBalanceAdapter} from "../../src/balances/protocols/EthenaCooldownBalanceAdapter.sol";
import {MerklRewardsBalanceAdapter} from "../../src/balances/protocols/MerklRewardsBalanceAdapter.sol";
import {
    EtherFiWithdrawalQueueBalanceAdapter
} from "../../src/balances/protocols/EtherFiWithdrawalQueueBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsBalanceAdapter
} from "../../src/balances/protocols/NexusMutualStakingPoolsBalanceAdapter.sol";
import {StakeWiseExitQueueBalanceAdapter} from "../../src/balances/protocols/StakeWiseExitQueueBalanceAdapter.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {
    UniswapV2PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV2PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/pancakeswap/PancakeSwapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol";

/// @title DeployBalanceAdapters
/// @notice Deploys balance adapter adapters based on per-chain configuration
/// @dev Reads enabled adapters from script/config/chains/{chainId}.json and deploys them
contract DeployBalanceAdapters is BaseDeployScript {
    function run() public override {
        setUp();

        console2.log("\n=== Deploying Balance Adapters ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("Reading config from: script/config/chains/", vm.toString(currentChainId), ".json\n");

        vm.startBroadcast();

        // Names below are the union of balance-adapter instances used by the ETH Alpha Fund
        // and USD Alpha Fund across all 5 chains. Each _deployIfEnabled call only fires when the
        // current chain's config has `balanceAdapters.{name}.enabled = true`, so the list can
        // include cross-chain entries safely.

        // --- Aave V3 (meta-adapter: all instances on every chain; ADR 0010) ---
        // The legacy per-market adapters (AaveV3_Core/_Prime/_Arbitrum/_Base/_Optimism/_Gnosis) are
        // superseded by AaveV3InstancesMeta and disabled in chain config — they have no deploy path here.
        _deployIfEnabled("AaveV3InstancesMeta"); // DataProvider set configured on NAV via addMetaInstances/removeMetaInstances

        // --- Compound V3 (one instance per Comet) ---
        _deployIfEnabled("CompoundV3CometsMeta"); // Meta-adapter: all Compound V3 comets; comet set on NAV (ADR 0010)

        // --- Spark Lend (Mainnet only) ---
        _deployIfEnabled("SparkLend");

        // --- Aave V3 Safety Module (Mainnet only; single multi-token adapter, see ADR 0002) ---
        _deployIfEnabled("AaveV3SafetyModule");

        // --- Aave Umbrella (Mainnet only; multi-token adapter mirroring the SM design, see ADR 0007) ---
        _deployIfEnabled("AaveUmbrella");

        // --- Cap Finance (Mainnet only) ---
        _deployIfEnabled("Cap");

        // --- Morpho Vaults meta-adapter (one adapter for all vaults; instance set on NAV, ADR 0010) ---
        _deployIfEnabled("MorphoVaultsMeta"); // Meta-adapter: all Morpho vaults; instance set configured on NAV (ADR 0010)
        _deployIfEnabled("MorphoMarketsMeta"); // Meta-adapter: all Morpho markets; marketId set configured on NAV (ADR 0010)
        _deployIfEnabled("EulerVaultsMeta"); // Meta-adapter: all Euler V2 vaults (EulerEarn + core eVaults); supply/collateral + borrow legs; instance set on NAV (ADR 0010)

        // --- ERC-4626 wrappers (one thin adapter per wrapper; generic ERC4626WrapBalanceAdapter) ---
        _deployIfEnabled("ERC4626Wrap_RWIV"); // Mainnet — Nexus Mutual RWI Vault (USDC underlying)

        // --- Gearbox Markets (Mainnet — ETH Alpha) ---
        _deployIfEnabled("GearboxMarketsMeta"); // Meta-adapter: all Gearbox markets; market set on NAV (ADR 0010)

        // --- Balancer V3 (meta-adapters: pools = unstaked LP, gauges = staked LP + rewards; sets on NAV, ADR 0010) ---
        _deployIfEnabled("BalancerV3PoolsMeta"); // Meta-adapter: all Balancer V3 pools (wallet LP); pool set on NAV
        _deployIfEnabled("BalancerV3GaugesMeta"); // Meta-adapter: all Balancer V3 gauges (staked LP + rewards); gauge set on NAV
        _deployIfEnabled("BalancerV2PoolsMeta"); // Meta-adapter: all Balancer V2 pools (wallet LP); poolId set on NAV
        _deployIfEnabled("BalancerV2GaugesMeta"); // Meta-adapter: all Balancer V2 gauges (staked LP + rewards); gauge set on NAV

        // --- Curve meta-adapters (ADR 0010: pools = wallet LP, gauges = staked LP + CRV + rewards) ---
        _deployIfEnabled("CurvePoolsMeta"); // Meta-adapter: all Curve pools (wallet LP); pool set on NAV
        _deployIfEnabled("CurveGaugesMeta"); // Meta-adapter: all Curve gauges (staked LP + CRV + rewards); gauge set on NAV

        // --- Convex meta-adapter (ADR 0010: all Convex pools; rewarder set on NAV) ---
        _deployIfEnabled("ConvexRewardsMeta"); // Meta-adapter: all Convex rewarders; instance set on NAV

        // --- Fluid Lending (meta-adapter: all fTokens; fToken set on NAV, ADR 0010) ---
        _deployIfEnabled("FluidFTokensMeta");

        // --- Fluid Vaults (meta-adapter: all T1 vaults; vault set on NAV, ADR 0010) ---
        _deployIfEnabled("FluidVaultsMeta");

        // --- Stader (Mainnet only) — withdrawal-queue balance adapter ---
        _deployIfEnabled("StaderWithdrawalQueue");

        // --- Kelp DAO (Mainnet only) — rsETH exit-queue balance adapter ---
        _deployIfEnabled("KelpWithdrawalQueue");

        // --- Lido (Mainnet only) — stETH withdrawal-queue balance adapter ---
        _deployIfEnabled("LidoWithdrawalQueue");

        // --- Ethena (Mainnet only) — sUSDe unstaking-cooldown balance adapter ---
        _deployIfEnabled("EthenaCooldown");

        // --- StakeWise V3 (Mainnet) — Genesis Vault deposit (osETH itself is now a Custom-priced ERC20, not a balance adapter) ---
        _deployIfEnabled("StakeWiseV3VaultsMeta"); // Meta-adapter: all StakeWise V3 vaults; vault set on NAV (ADR 0010)

        // --- Merkl Rewards (single instance per chain; Distributor address is identical on every EVM chain) ---
        _deployIfEnabled("MerklRewards");

        // --- ether.fi withdrawal-queue cache adapter (agent-fed; ADR 0014) ---
        _deployIfEnabled("EtherFiWithdrawalQueue");

        // --- Nexus Mutual staked NXM (brute-force view adapter: scans StakingNFT, values via StakingViewer) ---
        _deployIfEnabled("NexusMutualStakingPools");

        // --- StakeWise V3 exit-queue cache adapter (agent-fed; ADR 0014) ---
        _deployIfEnabled("StakeWiseExitQueue");

        // --- Uniswap V3 (meta-adapter: all pools; pool set on NAV, ADR 0010) ---
        _deployIfEnabled("UniswapV3PoolsMeta"); // Meta-adapter: all Uniswap V3 pools (Supply + Fees legs)

        // --- PancakeSwap V2 (meta-adapter) ---
        _deployIfEnabled("PancakeSwapV2PoolsMeta"); // BSC — meta-adapter: all PancakeSwap V2 pairs

        // --- PancakeSwap V3 (meta-adapter) ---
        _deployIfEnabled("PancakeSwapV3PoolsMeta"); // Base — meta-adapter: all PancakeSwap V3 pools

        // ERC20Default is deployed in NAVCalculator.initialize() when the NAV proxy is set up (02_DeployProxies); it is not deployed here.
        // StakeWiseV3* adapters are wired above so accounts holding osETH or Genesis-Vault
        // deposits get full coverage in the integration report.

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
        console2.log("Deployed adapters have been saved to chain config.");
        console2.log("\nNext Steps:");
        console2.log("1. Verify deployed adapters on Etherscan");
        console2.log("2. Use ManageAdapters script to add them to NAVCalculator");
        console2.log("==========================");
    }

    function _deployIfEnabled(string memory adapterName) internal {
        if (!ConfigReader.isAdapterEnabled(vm, currentChainId, "balanceAdapters", adapterName)) {
            return;
        }

        console2.log("Deploying:", adapterName);

        // Check if already deployed
        address deployed = _readAdapterDeployed("balanceAdapters", adapterName);
        if (deployed != address(0)) {
            console2.log("  Already deployed at:", deployed);
            return;
        }

        // Deploy based on adapter name
        address adapter = _deployAdapter(adapterName);

        if (adapter != address(0)) {
            // Save to config
            ConfigReader.writeAdapterAddress(vm, currentChainId, "balanceAdapters", adapterName, adapter);
            console2.log("  Deployed at:", adapter);
        }
    }

    function _deployAdapter(string memory adapterName) internal returns (address) {
        // Get NAVCalculator address (required for most adapters)
        // Try reading from config first, fallback to deployed address
        string memory navCalculatorStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "navCalculator");
        address navCalculator;
        if (bytes(navCalculatorStr).length > 0 && vm.parseAddress(navCalculatorStr) != address(0)) {
            navCalculator = vm.parseAddress(navCalculatorStr);
        } else {
            navCalculator = readDeployedAddress("NAVCalculatorProxy");
        }

        if (navCalculator == address(0)) {
            console2.log("ERROR: NAVCalculator not configured or deployed, cannot deploy adapter");
            return address(0);
        }

        // AaveV3 adapters
        // Aave V3 instances meta-adapter (one adapter for all instances; DataProvider set lives on NAV — ADR 0010)
        if (_equals(adapterName, "AaveV3InstancesMeta")) {
            return _deployAaveV3InstancesMeta(adapterName, navCalculator);
        }

        // CompoundV3 meta-adapter (per-instance adapters removed — superseded by CompoundV3CometsMeta)
        if (_equals(adapterName, "CompoundV3CometsMeta")) {
            return _deployCompoundV3CometsMeta(adapterName, navCalculator);
        }

        // SparkLend adapters (bare name for single-instance, prefix for future multi-market)
        if (_equals(adapterName, "SparkLend") || _startsWith(adapterName, "SparkLend_")) {
            return _deploySparkLend(adapterName, navCalculator);
        }

        // Morpho Markets meta-adapter (per-instance adapters removed — superseded by MorphoMarketsMeta)
        if (_equals(adapterName, "MorphoMarketsMeta")) {
            return _deployMorphoMarketsMeta(adapterName, navCalculator);
        }

        // Morpho Vaults meta-adapter (per-instance adapters removed — superseded by MorphoVaultsMeta)
        if (_equals(adapterName, "MorphoVaultsMeta")) {
            return _deployMorphoVaultsMeta(adapterName, navCalculator);
        }

        // Euler Vaults meta-adapter (one adapter for all Euler V2 eVaults; instance set on NAV, ADR 0010)
        if (_equals(adapterName, "EulerVaultsMeta")) {
            return _deployEulerVaultsMeta(adapterName, navCalculator);
        }

        // ERC-4626 wrap adapters (generic contract; one instance per wrapper, prefix-dispatched)
        if (_startsWith(adapterName, "ERC4626Wrap_")) {
            return _deployERC4626Wrap(adapterName, navCalculator);
        }

        // Gearbox Market meta-adapter (per-instance adapters removed — superseded by GearboxMarketsMeta)
        if (_equals(adapterName, "GearboxMarketsMeta")) {
            return _deployGearboxMarketsMeta(adapterName, navCalculator);
        }

        // Cap Finance adapter
        if (_equals(adapterName, "Cap")) {
            return _deployCap(navCalculator);
        }

        // Curve meta-adapters (ADR 0010)
        if (_equals(adapterName, "CurvePoolsMeta")) {
            return _deployCurvePoolsMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "CurveGaugesMeta")) {
            return _deployCurveGaugesMeta(adapterName, navCalculator);
        }

        // Convex adapters
        if (_equals(adapterName, "ConvexRewardsMeta")) {
            return _deployConvexRewardsMeta(adapterName, navCalculator);
        }

        // AaveV3 Safety Module: a single multi-token adapter per chain (ADR 0002).
        if (_equals(adapterName, "AaveV3SafetyModule")) {
            return _deployAaveV3SafetyModule(adapterName, navCalculator);
        }

        // Aave Umbrella: a single multi-token adapter per chain (ADR 0007).
        if (_equals(adapterName, "AaveUmbrella")) {
            return _deployAaveUmbrella(adapterName, navCalculator);
        }

        // Balancer V3 meta-adapters (one adapter for all pools / all gauges; instance set lives on NAV — ADR 0010)
        if (_equals(adapterName, "BalancerV3PoolsMeta")) {
            return _deployBalancerV3PoolsMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "BalancerV3GaugesMeta")) {
            return _deployBalancerV3GaugesMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "BalancerV2PoolsMeta")) {
            return _deployBalancerV2PoolsMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "BalancerV2GaugesMeta")) {
            return _deployBalancerV2GaugesMeta(adapterName, navCalculator);
        }

        // StakeWise V3 meta-adapter (per-instance adapters removed — superseded by StakeWiseV3VaultsMeta)
        if (_equals(adapterName, "StakeWiseV3VaultsMeta")) {
            return _deployStakeWiseV3VaultsMeta(adapterName, navCalculator);
        }

        // Fluid meta-adapters (one adapter for all fTokens / all T1 vaults; instance set on NAV — ADR 0010)
        if (_equals(adapterName, "FluidFTokensMeta")) {
            return _deployFluidFTokensMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "FluidVaultsMeta")) {
            return _deployFluidVaultsMeta(adapterName, navCalculator);
        }

        // Stader withdrawal queue
        if (_equals(adapterName, "StaderWithdrawalQueue")) {
            return _deployStaderWithdrawalQueue(adapterName, navCalculator);
        }

        // Ethena sUSDe cooldown
        if (_equals(adapterName, "EthenaCooldown")) {
            return _deployEthenaCooldown(adapterName, navCalculator);
        }

        // Kelp DAO rsETH exit queue
        if (_equals(adapterName, "KelpWithdrawalQueue")) {
            return _deployKelpWithdrawalQueue(adapterName, navCalculator);
        }

        // Lido stETH withdrawal queue
        if (_equals(adapterName, "LidoWithdrawalQueue")) {
            return _deployLidoWithdrawalQueue(adapterName, navCalculator);
        }

        // Merkl Rewards: proof-cached unclaimed-reward adapter (ADR 0007).
        if (_equals(adapterName, "MerklRewards")) {
            return _deployMerklRewards(adapterName, navCalculator);
        }

        // ether.fi withdrawals: id-cached withdrawal-queue adapter (ADR 0014).
        if (_equals(adapterName, "EtherFiWithdrawalQueue")) {
            return _deployEtherFiWithdrawalQueue(adapterName, navCalculator);
        }

        // Nexus Mutual staked NXM (simple immutable view adapter; no agent).
        if (_equals(adapterName, "NexusMutualStakingPools")) {
            return _deployNexusMutualStakingPools(adapterName, navCalculator);
        }

        // StakeWise V3 exit queue: ticket-cached exit-queue adapter (ADR 0014).
        if (_equals(adapterName, "StakeWiseExitQueue")) {
            return _deployStakeWiseExitQueue(adapterName, navCalculator);
        }

        // Uniswap/PancakeSwap meta-adapters (per-instance adapters removed — superseded by meta-adapters)
        if (_equals(adapterName, "UniswapV3PoolsMeta")) {
            return _deployUniswapV3PoolsMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "PancakeSwapV3PoolsMeta")) {
            return _deployPancakeSwapV3PoolsMeta(adapterName, navCalculator);
        }
        if (_equals(adapterName, "UniswapV2PoolsMeta") || _equals(adapterName, "PancakeSwapV2PoolsMeta")) {
            return _deployUniswapV2PoolsMeta(adapterName, navCalculator);
        }

        // Unknown adapter type
        console2.log("Unknown adapter type:", adapterName);
        return address(0);
    }

    /// @notice Deploys the Aave V3 instances meta-adapter. Constructor takes (protocol, navCalculator); the set of
    ///         instance DataProviders to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployAaveV3InstancesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        AaveV3InstancesMetaBalanceAdapter adapter = new AaveV3InstancesMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Compound V3 comets meta-adapter. Constructor takes (compoundRewards, rewardToken,
    ///         protocol, navCalculator) — chain-level constants; the comet set is configured on NAVCalculator
    ///         via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployCompoundV3CometsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address compoundRewards = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "compoundRewards")
        );
        address rewardToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        CompoundV3CometsMetaBalanceAdapter adapter =
            new CompoundV3CometsMetaBalanceAdapter(compoundRewards, rewardToken, protocol, navCalculator);
        return address(adapter);
    }

    function _deploySparkLend(string memory adapterName, address navCalculator) internal returns (address) {
        address dataProvider = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "dataProvider")
        );

        SparkLendBalanceAdapter adapter = new SparkLendBalanceAdapter(dataProvider, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Morpho Markets meta-adapter. Constructor takes (morpho, protocol, navCalculator); the
    ///         set of markets to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployMorphoMarketsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address morpho = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "morpho")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        MorphoMarketsMetaBalanceAdapter adapter = new MorphoMarketsMetaBalanceAdapter(morpho, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Morpho Vaults meta-adapter. Constructor takes only (protocol, navCalculator); the set of
    ///         vaults to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployMorphoVaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        MorphoVaultsMetaBalanceAdapter adapter = new MorphoVaultsMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    function _deployEulerVaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        EulerVaultsMetaBalanceAdapter adapter = new EulerVaultsMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Gearbox markets meta-adapter. Constructor takes (protocol, navCalculator); the market
    ///         set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployGearboxMarketsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        GearboxMarketsMetaBalanceAdapter adapter = new GearboxMarketsMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    function _deployCap(address navCalculator) internal returns (address) {
        address cUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "cUsd"));
        address stcUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "stcUsd"));
        address usdc =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "usdc"));

        CapBalanceAdapter adapter = new CapBalanceAdapter(cUsd, stcUsd, usdc, navCalculator);
        return address(adapter);
    }

    function _deployCurvePoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        return address(new CurvePoolsMetaBalanceAdapter(protocol, navCalculator));
    }

    function _deployCurveGaugesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address minter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "minter")
        );
        address crvToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "crvToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        return address(new CurveGaugesMetaBalanceAdapter(minter, crvToken, protocol, navCalculator));
    }

    function _deployConvexRewardsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address booster = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "booster")
        );
        address cvxToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "cvxToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        return address(new ConvexRewardsMetaBalanceAdapter(booster, cvxToken, protocol, navCalculator));
    }

    function _deployAaveV3SafetyModule(string memory adapterName, address navCalculator) internal returns (address) {
        // The set of stake tokens is hardcoded in the adapter (AaveV3SafetyModuleBalanceAdapter).
        AaveV3SafetyModuleBalanceAdapter adapter = new AaveV3SafetyModuleBalanceAdapter(navCalculator);
        return address(adapter);
    }

    function _deployAaveUmbrella(string memory adapterName, address navCalculator) internal returns (address) {
        // Schema (chains/<id>.json):
        //   "AaveUmbrella": {
        //     "enabled": true,
        //     "constructor": {
        //       "rewardsController": "0x4655Ce3D625a63d30bA704087E52B4C31E38188B",
        //       "protocol": "Aave Umbrella",
        //       "positionDetail": "{\"protocol\":\"Aave V3\",\"product\":\"Umbrella\"",
        //       "positionId": "0x..."
        //     }
        //   }
        // The Umbrella stake-token set is discovered at runtime from the RewardsController address
        // above via `getAllAssets()`. See ADR 0007 for the dynamic-discovery rationale.
        address rewardsController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardsController")
        );
        AaveUmbrellaBalanceAdapter adapter = new AaveUmbrellaBalanceAdapter(rewardsController, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer pools meta-adapter. Constructor takes (protocol, navCalculator); the set of
    ///         pools to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployBalancerV3PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        BalancerV3PoolsMetaBalanceAdapter adapter = new BalancerV3PoolsMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer gauges meta-adapter. Constructor takes (balancerMinter, protocol, navCalculator);
    ///         the set of gauges to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployBalancerV3GaugesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address balancerMinter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "balancerMinter")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        BalancerV3GaugesMetaBalanceAdapter adapter =
            new BalancerV3GaugesMetaBalanceAdapter(balancerMinter, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer V2 pools meta-adapter. Constructor takes (vault, protocol, navCalculator); the
    ///         poolId set is configured on NAVCalculator via addMetaInstances/removeMetaInstances (metaInstancesRaw) in 06 (ADR 0010).
    function _deployBalancerV2PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address vault =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vault"));
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        BalancerV2PoolsMetaBalanceAdapter adapter =
            new BalancerV2PoolsMetaBalanceAdapter(vault, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer V2 gauges meta-adapter. Constructor takes (vault, balancerMinter, protocol,
    ///         navCalculator); the gauge set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployBalancerV2GaugesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address vault =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vault"));
        address balancerMinter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "balancerMinter")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        BalancerV2GaugesMetaBalanceAdapter adapter =
            new BalancerV2GaugesMetaBalanceAdapter(vault, balancerMinter, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the StakeWise V3 vaults meta-adapter. Constructor takes (underlyingToken,
    ///         osTokenVaultController, protocol, navCalculator); the vault set is configured on NAVCalculator via
    ///         addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployStakeWiseV3VaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        address osTokenVaultController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "osTokenVaultController")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        StakeWiseV3VaultsMetaBalanceAdapter adapter =
            new StakeWiseV3VaultsMetaBalanceAdapter(underlyingToken, osTokenVaultController, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Fluid fTokens meta-adapter. Constructor takes (protocol, navCalculator); the fToken
    ///         set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployFluidFTokensMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        FluidFTokensMetaBalanceAdapter adapter = new FluidFTokensMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Fluid vaults meta-adapter. Constructor takes (vaultResolver, protocol, navCalculator);
    ///         the vault set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployFluidVaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address vaultResolver = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vaultResolver")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        FluidVaultsMetaBalanceAdapter adapter =
            new FluidVaultsMetaBalanceAdapter(vaultResolver, protocol, navCalculator);
        return address(adapter);
    }

    function _deployERC4626Wrap(string memory adapterName, address navCalculator) internal returns (address) {
        address wrapper = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "wrapper")
        );
        ERC4626WrapBalanceAdapter adapter = new ERC4626WrapBalanceAdapter(wrapper, navCalculator);
        return address(adapter);
    }

    function _deployStaderWithdrawalQueue(string memory adapterName, address navCalculator) internal returns (address) {
        address userWithdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "userWithdrawalManager")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        StaderWithdrawalQueueBalanceAdapter adapter =
            new StaderWithdrawalQueueBalanceAdapter(userWithdrawalManager, underlyingToken, navCalculator);
        return address(adapter);
    }

    function _deployEthenaCooldown(string memory adapterName, address navCalculator) internal returns (address) {
        address stakedUSDe = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "stakedUSDe")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        EthenaCooldownBalanceAdapter adapter =
            new EthenaCooldownBalanceAdapter(stakedUSDe, underlyingToken, navCalculator);
        return address(adapter);
    }

    function _deployKelpWithdrawalQueue(string memory adapterName, address navCalculator) internal returns (address) {
        // The set of payout assets (stETH, ETHx, native ETH) is discovered at runtime from
        // `withdrawalManager.lrtConfig().getSupportedAssetList()`, so only the manager + identity
        // strings are read from config.
        address withdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "withdrawalManager")
        );
        KelpWithdrawalQueueBalanceAdapter adapter =
            new KelpWithdrawalQueueBalanceAdapter(withdrawalManager, navCalculator);
        return address(adapter);
    }

    function _deployLidoWithdrawalQueue(string memory adapterName, address navCalculator) internal returns (address) {
        address withdrawalQueue = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "withdrawalQueue")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        LidoWithdrawalQueueBalanceAdapter adapter =
            new LidoWithdrawalQueueBalanceAdapter(withdrawalQueue, underlyingToken, navCalculator);
        return address(adapter);
    }

    function _deployMerklRewards(string memory adapterName, address navCalculator) internal returns (address) {
        // Schema (chains/<id>.json):
        //   "MerklRewards": {
        //     "enabled": true,
        //     "constructor": {
        //       "distributor": "0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae",  // same on every supported EVM chain
        //       "protocol": "Merkl",
        //       "positionDetail": "{\"protocol\":\"Merkl\",\"product\":\"Rewards\"",
        //       "positionId": "0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae"
        //     }
        //   }
        // Owner is set to chainConfig.admin (the OIV Safe). The Safe will be the only address that can call
        // submitProof / clearAllocation. Proof verification on-chain prevents the owner from fabricating amounts;
        // see docs/decisions/0007-merkl-trust-minimized-cache.md.
        address distributor = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "distributor")
        );
        require(chainConfig.admin != address(0), "MerklRewards: chainConfig.admin (initialOwner) not configured");

        MerklRewardsBalanceAdapter adapter =
            new MerklRewardsBalanceAdapter(distributor, navCalculator, chainConfig.admin);
        return address(adapter);
    }

    function _deployEtherFiWithdrawalQueue(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        // Owner = chainConfig.admin (OIV Safe / agent role): the only caller of submitTokenIds / clearTokenId. The
        // adapter values from live on-chain reads and re-verifies ownership every read, so the owner cannot
        // fabricate amounts (under-report only). See docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md.
        address withdrawRequestNft = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "withdrawRequestNft")
        );
        address liquidityPool = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "liquidityPool")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        require(
            chainConfig.admin != address(0), "EtherFiWithdrawalQueue: chainConfig.admin (initialOwner) not configured"
        );

        EtherFiWithdrawalQueueBalanceAdapter adapter = new EtherFiWithdrawalQueueBalanceAdapter(
            withdrawRequestNft, liquidityPool, underlyingToken, navCalculator, chainConfig.admin
        );
        return address(adapter);
    }

    function _deployNexusMutualStakingPools(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        // Immutable view adapter (no agent): discovers an account's StakingNFT positions by scanning
        // tokenInfo(1..totalSupply) and values each via StakingViewer.getTokens (per-NFT legs). underlyingToken = NXM.
        address stakingNft = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "stakingNft")
        );
        address stakingViewer = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "stakingViewer")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );

        NexusMutualStakingPoolsBalanceAdapter adapter =
            new NexusMutualStakingPoolsBalanceAdapter(stakingNft, stakingViewer, underlyingToken, navCalculator);
        return address(adapter);
    }

    function _deployStakeWiseExitQueue(string memory adapterName, address navCalculator) internal returns (address) {
        // Owner = chainConfig.admin (OIV Safe / agent role): the only caller of submitPositions / clearPosition. The
        // adapter values from live on-chain reads and verifies each tuple belongs to the account via
        // calculateExitedAssets(receiver=account), so the owner cannot fabricate amounts (under-report only). See
        // docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md.
        address vaultsRegistry = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vaultsRegistry")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        require(chainConfig.admin != address(0), "StakeWiseExitQueue: chainConfig.admin (initialOwner) not configured");

        StakeWiseExitQueueBalanceAdapter adapter =
            new StakeWiseExitQueueBalanceAdapter(vaultsRegistry, underlyingToken, navCalculator, chainConfig.admin);
        return address(adapter);
    }

    /// @notice Deploys the Uniswap V3 pools meta-adapter. Constructor takes (positionManager, protocol,
    ///         navCalculator); the pool set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployUniswapV3PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address positionManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionManager")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        UniswapV3PoolsMetaBalanceAdapter adapter =
            new UniswapV3PoolsMetaBalanceAdapter(positionManager, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the PancakeSwap V3 pools meta-adapter (subclass of the Uniswap V3 meta with the uint32
    ///         feeProtocol slot0 override). Same constructor shape as the Uniswap V3 pools meta.
    function _deployPancakeSwapV3PoolsMeta(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        address positionManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionManager")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        PancakeSwapV3PoolsMetaBalanceAdapter adapter =
            new PancakeSwapV3PoolsMetaBalanceAdapter(positionManager, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Uniswap V2 pools meta-adapter. Serves PancakeSwap V2 too (same contract via the
    ///         PancakeSwapV2PoolsMeta thin subclass when keyed "PancakeSwapV2PoolsMeta"). Constructor takes
    ///         (protocol, navCalculator); the pair set is configured on NAVCalculator (ADR 0010).
    function _deployUniswapV2PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        if (_equals(adapterName, "PancakeSwapV2PoolsMeta")) {
            return address(new PancakeSwapV2PoolsMetaBalanceAdapter(protocol, navCalculator));
        }
        return address(new UniswapV2PoolsMetaBalanceAdapter(protocol, navCalculator));
    }

    /// @notice Helper to read deployed adapter address
    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        return ConfigReader.readDeployedAdapterAddress(vm, currentChainId, adapterType, adapterName);
    }

    // Helper functions
    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        if (prefixBytes.length > strBytes.length) return false;
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
