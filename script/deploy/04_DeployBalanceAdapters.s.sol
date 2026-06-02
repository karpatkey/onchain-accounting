// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import balance adapters
import {AaveV2InstancesMetaBalanceAdapter} from "../../src/balances/protocols/AaveV2InstancesMeta.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "../../src/balances/protocols/AaveV3InstancesMeta.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "../../src/balances/protocols/CompoundV3CometsMeta.sol";
import {SparkLendBalanceOracle} from "../../src/balances/protocols/SparkLend.sol";
import {DaiDsrBalanceOracle} from "../../src/balances/protocols/DaiDsr.sol";
import {SkySavingsUsdsBalanceOracle} from "../../src/balances/protocols/SkySavingsUsds.sol";
import {MorphoVaultsMetaBalanceAdapter} from "../../src/balances/protocols/MorphoVaultsMeta.sol";
import {MorphoMarketsMetaBalanceAdapter} from "../../src/balances/protocols/MorphoMarketsMeta.sol";
import {GearboxMarketsMetaBalanceAdapter} from "../../src/balances/protocols/GearboxMarketsMeta.sol";
import {CapBalanceOracle} from "../../src/balances/protocols/Cap.sol";
import {CurvePoolsMetaBalanceAdapter} from "../../src/balances/protocols/curve/CurvePoolsMeta.sol";
import {CurveGaugesMetaBalanceAdapter} from "../../src/balances/protocols/curve/CurveGaugesMeta.sol";
import {ConvexRewardsMetaBalanceAdapter} from "../../src/balances/protocols/ConvexRewardsMeta.sol";
import {AaveV3SafetyModuleBalanceOracle} from "../../src/balances/protocols/AaveV3SafetyModule.sol";
import {AaveUmbrellaBalanceOracle} from "../../src/balances/protocols/AaveUmbrella.sol";
import {BalancerV3PoolsMetaBalanceAdapter} from "../../src/balances/protocols/balancer/BalancerV3PoolsMeta.sol";
import {BalancerV3GaugesMetaBalanceAdapter} from "../../src/balances/protocols/balancer/BalancerV3GaugesMeta.sol";
import {BalancerV2PoolsMetaBalanceAdapter} from "../../src/balances/protocols/balancer/BalancerV2PoolsMeta.sol";
import {BalancerV2GaugesMetaBalanceAdapter} from "../../src/balances/protocols/balancer/BalancerV2GaugesMeta.sol";
import {AuraRewardsMetaBalanceAdapter} from "../../src/balances/protocols/AuraRewardsMeta.sol";
import {StakeWiseV3VaultsMetaBalanceAdapter} from "../../src/balances/protocols/StakeWiseV3VaultsMeta.sol";
import {FluidFTokensMetaBalanceAdapter} from "../../src/balances/protocols/FluidFTokensMeta.sol";
import {FluidVaultsMetaBalanceAdapter} from "../../src/balances/protocols/FluidVaultsMeta.sol";
import {StaderWithdrawalQueueBalanceOracle} from "../../src/balances/protocols/StaderWithdrawalQueue.sol";
import {KelpWithdrawalQueueBalanceOracle} from "../../src/balances/protocols/KelpWithdrawalQueue.sol";
import {LidoWithdrawalQueueBalanceOracle} from "../../src/balances/protocols/LidoWithdrawalQueue.sol";
import {MerklRewardsBalanceOracle} from "../../src/balances/protocols/MerklRewards.sol";
import {UniswapV3PoolsMetaBalanceAdapter} from "../../src/balances/protocols/uniswap/UniswapV3PoolsMeta.sol";
import {UniswapV2PoolsMetaBalanceAdapter} from "../../src/balances/protocols/uniswap/UniswapV2PoolsMeta.sol";
import {
    PancakeSwapV2PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/pancakeswap/PancakeSwapV2PoolsMeta.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "../../src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMeta.sol";

/// @title DeployBalanceAdapters
/// @notice Deploys balance oracle adapters based on per-chain configuration
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

        // --- Aave V3 (one instance per Aave market) ---
        _deployIfEnabled("AaveV3InstancesMeta"); // Meta-adapter: all Aave V3 instances; DataProvider set on NAV (ADR 0010)
        _deployIfEnabled("AaveV3_Core"); // Mainnet Aave V3 core market
        _deployIfEnabled("AaveV3_Prime"); // Mainnet Aave V3 Prime market
        _deployIfEnabled("AaveV3_Arbitrum");
        _deployIfEnabled("AaveV3_Base");
        _deployIfEnabled("AaveV3_Optimism");
        _deployIfEnabled("AaveV3_Gnosis");

        // --- Aave V2 (Mainnet only — V2 is governance-deprecated everywhere else this repo deploys) ---
        _deployIfEnabled("AaveV2InstancesMeta"); // Meta-adapter: all Aave V2 instances; DataProvider set on NAV (ADR 0010)

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

        // --- Gearbox Markets (Mainnet — ETH Alpha) ---
        _deployIfEnabled("GearboxMarketsMeta"); // Meta-adapter: all Gearbox markets; market set on NAV (ADR 0010)

        // --- Balancer V3 (meta-adapters: pools = unstaked LP, gauges = staked LP + rewards; sets on NAV, ADR 0010) ---
        _deployIfEnabled("BalancerV3PoolsMeta"); // Meta-adapter: all Balancer V3 pools (wallet LP); pool set on NAV
        _deployIfEnabled("BalancerV3GaugesMeta"); // Meta-adapter: all Balancer V3 gauges (staked LP + rewards); gauge set on NAV
        _deployIfEnabled("BalancerV2PoolsMeta"); // Meta-adapter: all Balancer V2 pools (wallet LP); poolId set on NAV
        _deployIfEnabled("BalancerV2GaugesMeta"); // Meta-adapter: all Balancer V2 gauges (staked LP + rewards); gauge set on NAV

        // --- Aura meta-adapter (ADR 0010: AURA_REWARDS address; pool + AURA token resolved on-chain) ---
        _deployIfEnabled("AuraRewardsMeta"); // Meta-adapter: all Aura pools; rewarder set on NAV

        // --- Curve meta-adapters (ADR 0010: pools = wallet LP, gauges = staked LP + CRV + rewards) ---
        _deployIfEnabled("CurvePoolsMeta"); // Meta-adapter: all Curve pools (wallet LP); pool set on NAV
        _deployIfEnabled("CurveGaugesMeta"); // Meta-adapter: all Curve gauges (staked LP + CRV + rewards); gauge set on NAV

        // --- Convex meta-adapter (ADR 0010: all Convex pools; rewarder set on NAV) ---
        _deployIfEnabled("ConvexRewardsMeta"); // Meta-adapter: all Convex rewarders; instance set on NAV

        // --- Fluid Lending (meta-adapter: all fTokens; fToken set on NAV, ADR 0010) ---
        _deployIfEnabled("FluidFTokensMeta");

        // --- Fluid Vaults (meta-adapter: all T1 vaults; vault set on NAV, ADR 0010) ---
        _deployIfEnabled("FluidVaultsMeta");

        // --- Stader (Mainnet only) — withdrawal-queue balance oracle ---
        _deployIfEnabled("StaderWithdrawalQueue");

        // --- Kelp DAO (Mainnet only) — rsETH exit-queue balance oracle ---
        _deployIfEnabled("KelpWithdrawalQueue");

        // --- Lido (Mainnet only) — stETH withdrawal-queue balance oracle ---
        _deployIfEnabled("LidoWithdrawalQueue");

        // --- StakeWise V3 (Mainnet) — Genesis Vault deposit (osETH itself is now a Custom-priced ERC20, not a balance adapter) ---
        _deployIfEnabled("StakeWiseV3VaultsMeta"); // Meta-adapter: all StakeWise V3 vaults; vault set on NAV (ADR 0010)

        // --- Merkl Rewards (single instance per chain; Distributor address is identical on every EVM chain) ---
        _deployIfEnabled("MerklRewards");

        // --- Uniswap V3 (meta-adapter: all pools; pool set on NAV, ADR 0010) ---
        _deployIfEnabled("UniswapV3PoolsMeta"); // Meta-adapter: all Uniswap V3 pools (Supply + Fees legs)

        // --- PancakeSwap V2 (meta-adapter) ---
        _deployIfEnabled("PancakeSwapV2PoolsMeta"); // BSC — meta-adapter: all PancakeSwap V2 pairs

        // --- PancakeSwap V3 (meta-adapter) ---
        _deployIfEnabled("PancakeSwapV3PoolsMeta"); // Base — meta-adapter: all PancakeSwap V3 pools

        // ERC20Default is deployed in NAVCalculator.initialize() when the NAV proxy is set up (02_DeployProxies); it is not deployed here.
        // DaiDsr and SkySavingsUsds adapters exist in this repo but are NOT used by either Alpha
        // fund, so they are not wired here. StakeWiseV3* adapters are wired above so accounts
        // holding osETH or Genesis-Vault deposits get full coverage in the integration report.

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

        // AaveV2 meta-adapter (per-instance adapters removed — superseded by AaveV2InstancesMeta)
        if (_equals(adapterName, "AaveV2InstancesMeta")) {
            return _deployAaveV2InstancesMeta(adapterName, navCalculator);
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

        // DAI DSR
        if (_equals(adapterName, "DaiDsr")) {
            return _deployDaiDsr(navCalculator);
        }

        // Sky Savings USDS
        if (_equals(adapterName, "SkySavingsUsds")) {
            return _deploySkySavingsUsds(navCalculator);
        }

        // Morpho Vaults meta-adapter (per-instance adapters removed — superseded by MorphoVaultsMeta)
        if (_equals(adapterName, "MorphoVaultsMeta")) {
            return _deployMorphoVaultsMeta(adapterName, navCalculator);
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

        if (_equals(adapterName, "AuraRewardsMeta")) {
            return _deployAuraRewardsMeta(adapterName, navCalculator);
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

    /// @notice Deploys the Aave V2 instances meta-adapter. Constructor takes (protocol, navCalculator); the
    ///         DataProvider set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
    function _deployAaveV2InstancesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        AaveV2InstancesMetaBalanceAdapter adapter = new AaveV2InstancesMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Aave V3 instances meta-adapter. Constructor takes (protocol, navCalculator); the set of
    ///         instance DataProviders to query is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
    function _deployAaveV3InstancesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        AaveV3InstancesMetaBalanceAdapter adapter = new AaveV3InstancesMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Compound V3 comets meta-adapter. Constructor takes (compoundRewards, rewardToken,
    ///         protocol, navCalculator) — chain-level constants; the comet set is configured on NAVCalculator
    ///         via setMetaInstances in 06 (ADR 0010).
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

        SparkLendBalanceOracle adapter = new SparkLendBalanceOracle(dataProvider, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Morpho Markets meta-adapter. Constructor takes (morpho, protocol, navCalculator); the
    ///         set of markets to query is configured on NAVCalculator via setMetaInstances in 06_Configure (ADR 0010).
    function _deployMorphoMarketsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address morpho = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "morpho")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        MorphoMarketsMetaBalanceAdapter adapter = new MorphoMarketsMetaBalanceAdapter(morpho, protocol, navCalculator);
        return address(adapter);
    }

    function _deployDaiDsr(address navCalculator) internal returns (address) {
        address dai =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "DaiDsr", "dai"));
        address dsrManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "DaiDsr", "dsrManager")
        );

        DaiDsrBalanceOracle adapter = new DaiDsrBalanceOracle(dai, dsrManager, navCalculator);
        return address(adapter);
    }

    function _deploySkySavingsUsds(address navCalculator) internal returns (address) {
        address savingsUsds = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "SkySavingsUsds", "savingsUsds")
        );

        SkySavingsUsdsBalanceOracle adapter = new SkySavingsUsdsBalanceOracle(savingsUsds, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Morpho Vaults meta-adapter. Constructor takes only (protocol, navCalculator); the set of
    ///         vaults to query is configured on NAVCalculator via setMetaInstances in 06_Configure (ADR 0010).
    function _deployMorphoVaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        MorphoVaultsMetaBalanceAdapter adapter = new MorphoVaultsMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Gearbox markets meta-adapter. Constructor takes (protocol, navCalculator); the market
    ///         set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
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

        CapBalanceOracle adapter = new CapBalanceOracle(cUsd, stcUsd, usdc, navCalculator);
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
        // The set of stake tokens is hardcoded in the adapter (AaveV3SafetyModuleBalanceOracle).
        AaveV3SafetyModuleBalanceOracle adapter = new AaveV3SafetyModuleBalanceOracle(navCalculator);
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
        AaveUmbrellaBalanceOracle adapter = new AaveUmbrellaBalanceOracle(rewardsController, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer pools meta-adapter. Constructor takes (protocol, navCalculator); the set of
    ///         pools to query is configured on NAVCalculator via setMetaInstances in 06_Configure (ADR 0010).
    function _deployBalancerV3PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        BalancerV3PoolsMetaBalanceAdapter adapter = new BalancerV3PoolsMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer gauges meta-adapter. Constructor takes (balancerMinter, protocol, navCalculator);
    ///         the set of gauges to query is configured on NAVCalculator via setMetaInstances in 06_Configure (ADR 0010).
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
    ///         poolId set is configured on NAVCalculator via setMetaInstances (metaInstancesRaw) in 06 (ADR 0010).
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
    ///         navCalculator); the gauge set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
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

    function _deployAuraRewardsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address booster = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "booster")
        );
        address balancerV2Vault = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "balancerV2Vault")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        // AURA token is resolved inside the constructor from Booster.minter().
        return address(new AuraRewardsMetaBalanceAdapter(booster, balancerV2Vault, protocol, navCalculator));
    }

    /// @notice Deploys the StakeWise V3 vaults meta-adapter. Constructor takes (underlyingToken, protocol,
    ///         navCalculator); the vault set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
    function _deployStakeWiseV3VaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        StakeWiseV3VaultsMetaBalanceAdapter adapter =
            new StakeWiseV3VaultsMetaBalanceAdapter(underlyingToken, protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Fluid fTokens meta-adapter. Constructor takes (protocol, navCalculator); the fToken
    ///         set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
    function _deployFluidFTokensMeta(string memory adapterName, address navCalculator) internal returns (address) {
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        FluidFTokensMetaBalanceAdapter adapter = new FluidFTokensMetaBalanceAdapter(protocol, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Fluid vaults meta-adapter. Constructor takes (vaultResolver, protocol, navCalculator);
    ///         the vault set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
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

    function _deployStaderWithdrawalQueue(string memory adapterName, address navCalculator) internal returns (address) {
        address userWithdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "userWithdrawalManager")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        StaderWithdrawalQueueBalanceOracle adapter =
            new StaderWithdrawalQueueBalanceOracle(userWithdrawalManager, underlyingToken, navCalculator);
        return address(adapter);
    }

    function _deployKelpWithdrawalQueue(string memory adapterName, address navCalculator) internal returns (address) {
        // The set of payout assets (stETH, ETHx, native ETH) is discovered at runtime from
        // `withdrawalManager.lrtConfig().getSupportedAssetList()`, so only the manager + identity
        // strings are read from config.
        address withdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "withdrawalManager")
        );
        KelpWithdrawalQueueBalanceOracle adapter =
            new KelpWithdrawalQueueBalanceOracle(withdrawalManager, navCalculator);
        return address(adapter);
    }

    function _deployLidoWithdrawalQueue(string memory adapterName, address navCalculator) internal returns (address) {
        address withdrawalQueue = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "withdrawalQueue")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        LidoWithdrawalQueueBalanceOracle adapter =
            new LidoWithdrawalQueueBalanceOracle(withdrawalQueue, underlyingToken, navCalculator);
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

        MerklRewardsBalanceOracle adapter = new MerklRewardsBalanceOracle(distributor, navCalculator, chainConfig.admin);
        return address(adapter);
    }

    /// @notice Deploys the Uniswap V3 pools meta-adapter. Constructor takes (positionManager, protocol,
    ///         navCalculator); the pool set is configured on NAVCalculator via setMetaInstances in 06 (ADR 0010).
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
        string memory deployed = ConfigReader.readAdapterParam(vm, currentChainId, adapterType, adapterName, "deployed");
        if (bytes(deployed).length == 0) {
            return address(0);
        }
        address addr = vm.parseAddress(deployed);
        return addr == address(0) ? address(0) : addr;
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
