// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import balance adapters
import {
    AaveV3InstancesMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {
    CompoundV3CometsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/CompoundV3CometsMetaBalanceAdapter.sol";
import {SparkLendBalanceAdapter} from "../../src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol";
import {
    MorphoVaultsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol";
import {
    MorphoMarketsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {
    GearboxV3MarketsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol";
import {EulerVaultsMetaBalanceAdapter} from "../../src/balances/MetaBalanceAdapters/EulerVaultsMetaBalanceAdapter.sol";
import {CapBalanceAdapter} from "../../src/balances/BalanceAdapters/CapBalanceAdapter.sol";
import {
    CurvePoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {
    CurveGaugesMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {
    ConvexCurveLPStakingMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol";
import {
    AaveV3SafetyModuleBalanceAdapter
} from "../../src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {AaveUmbrellaBalanceAdapter} from "../../src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {
    BalancerV3PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolsMetaBalanceAdapter.sol";
import {
    BalancerV3GaugesMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol";
import {
    BalancerV2PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolsMetaBalanceAdapter.sol";
import {
    BalancerV2GaugesMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/balancer/BalancerV2GaugesMetaBalanceAdapter.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {
    FluidFTokensMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/FluidFTokensMetaBalanceAdapter.sol";
import {FluidVaultsMetaBalanceAdapter} from "../../src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "../../src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {
    KelpWithdrawalQueueBalanceAdapter
} from "../../src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol";
import {
    LidoWithdrawalQueueBalanceAdapter
} from "../../src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol";
import {EthenaCooldownBalanceAdapter} from "../../src/balances/BalanceAdapters/EthenaCooldownBalanceAdapter.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "../../src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "../../src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "../../src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    EtherFiWithdrawalQueueAssistant
} from "../../src/balances/AssistedBalanceAdapters/assistants/EtherFiWithdrawalQueueAssistant.sol";
import {
    NexusMutualStakingPoolsAssistant
} from "../../src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol";
import {
    StakeWiseV3ExitQueueAssistant
} from "../../src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {
    UniswapV2PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV2PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "../../src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol";

/// @title DeployBalanceAdapters
/// @notice Deploys balance adapters based on per-chain configuration
/// @dev Reads enabled adapters from script/config/contracts-deployment-config/{balance-adapters,meta-balance-adapters}/{chainId}.json and deploys them
contract DeployBalanceAdapters is BaseDeployScript {
    function run() public override {
        setUp();

        console2.log("\n=== Deploying Balance Adapters ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("Reading config from: script/config/chains/", vm.toString(currentChainId), ".json\n");

        vm.startBroadcast();

        // Names below are the union of balance-adapter instances used by the ETH Alpha Fund
        // and USD Alpha Fund across all 7 chains. Each _deployIfEnabled call only fires when the
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

        // --- Gearbox Markets (Mainnet — ETH Alpha) ---
        _deployIfEnabled("GearboxV3MarketsMeta"); // Meta-adapter: all Gearbox markets; market set on NAV (ADR 0010)

        // --- Balancer V3 (meta-adapters: pools = unstaked LP, gauges = staked LP + rewards; sets on NAV, ADR 0010) ---
        _deployIfEnabled("BalancerV3PoolsMeta"); // Meta-adapter: all Balancer V3 pools (wallet LP); pool set on NAV
        _deployIfEnabled("BalancerV3GaugesMeta"); // Meta-adapter: all Balancer V3 gauges (staked LP + rewards); gauge set on NAV
        _deployIfEnabled("BalancerV2PoolsMeta"); // Meta-adapter: all Balancer V2 pools (wallet LP); poolId set on NAV
        _deployIfEnabled("BalancerV2GaugesMeta"); // Meta-adapter: all Balancer V2 gauges (staked LP + rewards); gauge set on NAV

        // --- Curve meta-adapters (ADR 0010: pools = wallet LP, gauges = staked LP + CRV + rewards) ---
        _deployIfEnabled("CurvePoolsMeta"); // Meta-adapter: all Curve pools (wallet LP); pool set on NAV
        _deployIfEnabled("CurveGaugesMeta"); // Meta-adapter: all Curve gauges (staked LP + CRV + rewards); gauge set on NAV

        // --- Convex meta-adapter (ADR 0010: all Convex pools; rewarder set on NAV) ---
        _deployIfEnabled("ConvexCurveLPStakingMeta"); // Meta-adapter: all Convex rewarders; instance set on NAV

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

        // --- ether.fi withdrawal-queue cache adapter (assisted; permissionless assistant-fed, ADR 0018) ---
        _deployIfEnabled("EtherFiWithdrawalQueueAssisted");

        // --- Nexus Mutual staked NXM (assisted cache adapter; StakingNFT tokenIds, ADR 0015/0018 permissionless
        //     assistant-fed; values via StakingViewer, re-verifies ownership per read) ---
        _deployIfEnabled("NexusMutualStakingPoolsAssisted");

        // --- StakeWise V3 exit-queue cache adapter (assisted; permissionless assistant-fed, ADR 0018) ---
        _deployIfEnabled("StakeWiseV3ExitQueueAssisted");

        // --- Uniswap V2 (meta-adapter: all pairs; pair set on NAV, ADR 0010) ---
        _deployIfEnabled("UniswapV2PoolsMeta"); // Meta-adapter: all Uniswap V2 pairs (shares the PancakeSwap V2 dispatch)

        // --- Uniswap V3 (meta-adapter: on-chain NFT enumeration; ADR 0010) ---
        _deployIfEnabled("UniswapV3PoolsMeta"); // Meta-adapter: all configured Uniswap V3 pools; NFTs enumerated on-chain

        // --- PancakeSwap V2 (meta-adapter) ---
        _deployIfEnabled("PancakeSwapV2PoolsMeta"); // BSC — meta-adapter: all PancakeSwap V2 pairs

        // --- PancakeSwap V3 (meta-adapter; disabled in config — never deployed, kept for parity) ---
        _deployIfEnabled("PancakeSwapV3PoolsMeta"); // meta-adapter: PancakeSwap V3 pools (on-chain NFT enumeration)

        // --- Assistants for the permissionless assisted adapters (ADR 0018) ---
        // Delegatecall helpers the owner Safe uses to enter/stake while keeping the adapter cache current. Deployed
        // alongside their adapters (not NAV-registered); recorded in the deployment state so the ops team can whitelist
        // them on the Roles modifier. Stader is a plain adapter and has no assistant.
        _deployAssistantsIfEnabled();

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

    /// @notice Deploys the delegatecall assistants paired with the permissionless assisted adapters (ADR 0018), when
    ///         their adapters are deployed. Assistants are NOT NAV-registered (they are not balance adapters); they are
    ///         recorded in the deployment state for the ops team to whitelist on the Roles modifier. Idempotent — skips
    ///         an assistant already recorded. Constructor args beyond the adapter address are read from the paired
    ///         adapter's config (`tokenController` for Nexus, `eeth` for ether.fi; StakeWise needs only the adapter).
    function _deployAssistantsIfEnabled() internal {
        // ether.fi
        address etherfiAdapter = _readAdapterDeployed("balanceAdapters", "EtherFiWithdrawalQueueAssisted");
        if (etherfiAdapter != address(0) && readDeployedAddress("EtherFiWithdrawalQueueAssistant") == address(0)) {
            address liquidityPool = vm.parseAddress(
                ConfigReader.readAdapterParam(
                    vm, currentChainId, "balanceAdapters", "EtherFiWithdrawalQueueAssisted", "liquidityPool"
                )
            );
            address withdrawRequestNft = vm.parseAddress(
                ConfigReader.readAdapterParam(
                    vm, currentChainId, "balanceAdapters", "EtherFiWithdrawalQueueAssisted", "withdrawRequestNft"
                )
            );
            address eeth = vm.parseAddress(
                ConfigReader.readAdapterParam(
                    vm, currentChainId, "balanceAdapters", "EtherFiWithdrawalQueueAssisted", "eeth"
                )
            );
            address assistant =
                address(new EtherFiWithdrawalQueueAssistant(etherfiAdapter, liquidityPool, withdrawRequestNft, eeth));
            saveDeployedAddress("EtherFiWithdrawalQueueAssistant", assistant);
            console2.log("Deployed EtherFiWithdrawalQueueAssistant:", assistant);
        }

        // Nexus Mutual (underlyingToken on the adapter config is NXM, reused as the assistant's NXM arg)
        address nexusAdapter = _readAdapterDeployed("balanceAdapters", "NexusMutualStakingPoolsAssisted");
        if (nexusAdapter != address(0) && readDeployedAddress("NexusMutualStakingPoolsAssistant") == address(0)) {
            address nxm = vm.parseAddress(
                ConfigReader.readAdapterParam(
                    vm, currentChainId, "balanceAdapters", "NexusMutualStakingPoolsAssisted", "underlyingToken"
                )
            );
            address tokenController = vm.parseAddress(
                ConfigReader.readAdapterParam(
                    vm, currentChainId, "balanceAdapters", "NexusMutualStakingPoolsAssisted", "tokenController"
                )
            );
            address assistant = address(new NexusMutualStakingPoolsAssistant(nexusAdapter, nxm, tokenController));
            saveDeployedAddress("NexusMutualStakingPoolsAssistant", assistant);
            console2.log("Deployed NexusMutualStakingPoolsAssistant:", assistant);
        }

        // StakeWise V3 (assistant needs only the adapter)
        address stakewiseAdapter = _readAdapterDeployed("balanceAdapters", "StakeWiseV3ExitQueueAssisted");
        if (stakewiseAdapter != address(0) && readDeployedAddress("StakeWiseV3ExitQueueAssistant") == address(0)) {
            address assistant = address(new StakeWiseV3ExitQueueAssistant(stakewiseAdapter));
            saveDeployedAddress("StakeWiseV3ExitQueueAssistant", assistant);
            console2.log("Deployed StakeWiseV3ExitQueueAssistant:", assistant);
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

        // Gearbox Market meta-adapter (per-instance adapters removed — superseded by GearboxV3MarketsMeta)
        if (_equals(adapterName, "GearboxV3MarketsMeta")) {
            return _deployGearboxV3MarketsMeta(adapterName, navCalculator);
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
        if (_equals(adapterName, "ConvexCurveLPStakingMeta")) {
            return _deployConvexCurveLPStakingMeta(adapterName, navCalculator);
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

        // ether.fi withdrawals: id-cached withdrawal-queue adapter (assisted; ADR 0018).
        if (_equals(adapterName, "EtherFiWithdrawalQueueAssisted")) {
            return _deployEtherFiWithdrawalQueueAssisted(adapterName, navCalculator);
        }

        // Nexus Mutual staked NXM (assisted cache adapter; StakingNFT tokenIds, ADR 0015/0018).
        if (_equals(adapterName, "NexusMutualStakingPoolsAssisted")) {
            return _deployNexusMutualStakingPoolsAssisted(adapterName, navCalculator);
        }

        // StakeWise V3 exit queue: ticket-cached exit-queue adapter (assisted; ADR 0018).
        if (_equals(adapterName, "StakeWiseV3ExitQueueAssisted")) {
            return _deployStakeWiseV3ExitQueueAssisted(adapterName, navCalculator);
        }

        // Uniswap/PancakeSwap V3 meta-adapters (on-chain NFT enumeration; ADR 0010)
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

    /// @notice Deploys the Aave V3 instances meta-adapter. Constructor takes (navCalculator); the set of
    ///         instance DataProviders to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployAaveV3InstancesMeta(string memory, address navCalculator) internal returns (address) {
        AaveV3InstancesMetaBalanceAdapter adapter = new AaveV3InstancesMetaBalanceAdapter(navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Compound V3 comets meta-adapter. Constructor takes (compoundRewards, rewardToken,
    ///         navCalculator) — chain-level constants; the comet set is configured on NAVCalculator
    ///         via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployCompoundV3CometsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address compoundRewards = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "compoundRewards")
        );
        address rewardToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardToken")
        );

        CompoundV3CometsMetaBalanceAdapter adapter =
            new CompoundV3CometsMetaBalanceAdapter(compoundRewards, rewardToken, navCalculator);
        return address(adapter);
    }

    function _deploySparkLend(string memory adapterName, address navCalculator) internal returns (address) {
        address dataProvider = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "dataProvider")
        );

        SparkLendBalanceAdapter adapter = new SparkLendBalanceAdapter(dataProvider, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Morpho Markets meta-adapter. Constructor takes (morpho, navCalculator); the
    ///         set of markets to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployMorphoMarketsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address morpho = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "morpho")
        );

        MorphoMarketsMetaBalanceAdapter adapter = new MorphoMarketsMetaBalanceAdapter(morpho, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Morpho Vaults meta-adapter. Constructor takes only (navCalculator); the set of
    ///         vaults to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployMorphoVaultsMeta(string memory, address navCalculator) internal returns (address) {
        MorphoVaultsMetaBalanceAdapter adapter = new MorphoVaultsMetaBalanceAdapter(navCalculator);
        return address(adapter);
    }

    function _deployEulerVaultsMeta(string memory, address navCalculator) internal returns (address) {
        EulerVaultsMetaBalanceAdapter adapter = new EulerVaultsMetaBalanceAdapter(navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Gearbox markets meta-adapter. Constructor takes (navCalculator); the market
    ///         set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployGearboxV3MarketsMeta(string memory, address navCalculator) internal returns (address) {
        GearboxV3MarketsMetaBalanceAdapter adapter = new GearboxV3MarketsMetaBalanceAdapter(navCalculator);
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

    function _deployCurvePoolsMeta(string memory, address navCalculator) internal returns (address) {
        return address(new CurvePoolsMetaBalanceAdapter(navCalculator));
    }

    function _deployCurveGaugesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address minter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "minter")
        );
        address crvToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "crvToken")
        );
        return address(new CurveGaugesMetaBalanceAdapter(minter, crvToken, navCalculator));
    }

    function _deployConvexCurveLPStakingMeta(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        address booster = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "booster")
        );
        address cvxToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "cvxToken")
        );
        return address(new ConvexCurveLPStakingMetaBalanceAdapter(booster, cvxToken, navCalculator));
    }

    function _deployAaveV3SafetyModule(string memory, address navCalculator) internal returns (address) {
        // The set of stake tokens is hardcoded in the adapter (AaveV3SafetyModuleBalanceAdapter).
        AaveV3SafetyModuleBalanceAdapter adapter = new AaveV3SafetyModuleBalanceAdapter(navCalculator);
        return address(adapter);
    }

    function _deployAaveUmbrella(string memory adapterName, address navCalculator) internal returns (address) {
        // Schema (contracts-deployment-config/balance-adapters/<id>.json):
        //   "AaveUmbrella": {
        //     "enabled": true,
        //     "constructor": {
        //       "rewardsController": "0x4655Ce3D625a63d30bA704087E52B4C31E38188B"
        //     }
        //   }
        // No display name in config: this adapter hardcodes ProtocolNames.AAVE_V3 (Umbrella is a product of
        // Aave V3, not a protocol of its own; the product rides in positionLabels()). The `protocol` key was
        // removed from every deploy config — meta adapters derive the name from _protocolId(), and the
        // hardcoded adapters carry it in bytecode, so nothing reads it.
        // The Umbrella stake-token set is discovered at runtime from the RewardsController address
        // above via `getAllAssets()`. See ADR 0007 for the dynamic-discovery rationale.
        address rewardsController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardsController")
        );
        AaveUmbrellaBalanceAdapter adapter = new AaveUmbrellaBalanceAdapter(rewardsController, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer pools meta-adapter. Constructor takes (navCalculator); the set of
    ///         pools to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployBalancerV3PoolsMeta(string memory, address navCalculator) internal returns (address) {
        BalancerV3PoolsMetaBalanceAdapter adapter = new BalancerV3PoolsMetaBalanceAdapter(navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer gauges meta-adapter. Constructor takes (balancerMinter, navCalculator);
    ///         the set of gauges to query is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06_Configure (ADR 0010).
    function _deployBalancerV3GaugesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address balancerMinter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "balancerMinter")
        );

        BalancerV3GaugesMetaBalanceAdapter adapter =
            new BalancerV3GaugesMetaBalanceAdapter(balancerMinter, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer V2 pools meta-adapter. Constructor takes (vault, navCalculator); the
    ///         poolId set is configured on NAVCalculator via addMetaInstances/removeMetaInstances (metaInstancesRaw) in 06 (ADR 0010).
    function _deployBalancerV2PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address vault =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vault"));

        BalancerV2PoolsMetaBalanceAdapter adapter = new BalancerV2PoolsMetaBalanceAdapter(vault, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Balancer V2 gauges meta-adapter. Constructor takes (vault, balancerMinter,
    ///         navCalculator); the gauge set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployBalancerV2GaugesMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address vault =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vault"));
        address balancerMinter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "balancerMinter")
        );

        BalancerV2GaugesMetaBalanceAdapter adapter =
            new BalancerV2GaugesMetaBalanceAdapter(vault, balancerMinter, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the StakeWise V3 vaults meta-adapter. Constructor takes (underlyingToken,
    ///         osTokenVaultController, navCalculator); the vault set is configured on NAVCalculator via
    ///         addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployStakeWiseV3VaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        address osTokenVaultController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "osTokenVaultController")
        );

        StakeWiseV3VaultsMetaBalanceAdapter adapter =
            new StakeWiseV3VaultsMetaBalanceAdapter(underlyingToken, osTokenVaultController, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Fluid fTokens meta-adapter. Constructor takes (navCalculator); the fToken
    ///         set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployFluidFTokensMeta(string memory, address navCalculator) internal returns (address) {
        FluidFTokensMetaBalanceAdapter adapter = new FluidFTokensMetaBalanceAdapter(navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Fluid vaults meta-adapter. Constructor takes (vaultResolver, navCalculator);
    ///         the vault set is configured on NAVCalculator via addMetaInstances/removeMetaInstances in 06 (ADR 0010).
    function _deployFluidVaultsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address vaultResolver = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vaultResolver")
        );
        FluidVaultsMetaBalanceAdapter adapter = new FluidVaultsMetaBalanceAdapter(vaultResolver, navCalculator);
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

    function _deployEtherFiWithdrawalQueueAssisted(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        // Permissionless assistant-fed adapter (ADR 0018): no admin/roles — the id cache is msg.sender-keyed
        // and fed on-chain by the delegatecall assistant. NAV registration + assistant deploy wiring deferred.
        address withdrawRequestNft = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "withdrawRequestNft")
        );
        address liquidityPool = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "liquidityPool")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );

        EtherFiWithdrawalQueueAssistedBalanceAdapter adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            withdrawRequestNft, liquidityPool, underlyingToken, navCalculator
        );
        return address(adapter);
    }

    function _deployNexusMutualStakingPoolsAssisted(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        // Assisted adapter (permissionless assistant-fed; ADR 0015/0018): the caller submits an account's StakingNFT
        // tokenIds via the msg.sender-keyed submit; the adapter values each via StakingViewer.getTokens and re-verifies
        // ownership via tokenInfo per read, so a feeder can only under-report (id-cache, never amounts). No roles.
        // underlyingToken = NXM.
        address stakingNft = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "stakingNft")
        );
        address stakingViewer = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "stakingViewer")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        // Permissionless assistant-fed adapter (ADR 0018): no admin/roles — the id cache is msg.sender-keyed
        // and fed on-chain by the delegatecall assistant. NAV registration + assistant deploy wiring deferred.
        NexusMutualStakingPoolsAssistedBalanceAdapter adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            stakingNft, stakingViewer, underlyingToken, navCalculator
        );
        return address(adapter);
    }

    function _deployStakeWiseV3ExitQueueAssisted(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        // Permissionless assistant-fed (ADR 0018): submit/remove are msg.sender-keyed (no roles). The adapter values
        // from live on-chain reads and verifies each tuple belongs to the account via calculateExitedAssets(
        // receiver=account), so a feeder cannot fabricate amounts (under-report only). See
        // docs/decisions/0018-assistant-fed-assisted-balance-adapters.md.
        address vaultsRegistry = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vaultsRegistry")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        // StakeWise's receipt/LST token symbol for this chain ("osETH" mainnet, "osGNO" Gnosis); pins receiptSymbol so
        // the position label reads "<receiptSymbol> Exit Queue", consistent with the sibling queues.
        string memory receiptSymbol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "receiptSymbol");
        // StakeWise's post-checkpoint claim delay in seconds (86400 = 24h on V3 mainnet); pins EXIT_CLAIM_DELAY so the
        // exited-but-still-delayed portion is reported locked, not claimable.
        uint256 exitClaimDelay = vm.parseUint(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "exitClaimDelay")
        );
        // Permissionless assistant-fed adapter (ADR 0018): no admin/roles — the coordinate cache is msg.sender-keyed
        // and fed on-chain by the delegatecall assistant. NAV registration + assistant wiring deferred.
        StakeWiseV3ExitQueueAssistedBalanceAdapter adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            vaultsRegistry, underlyingToken, receiptSymbol, navCalculator, exitClaimDelay
        );
        return address(adapter);
    }

    /// @notice Deploys the Uniswap V3 pools meta-adapter (ADR 0010; on-chain NFT enumeration via the NPM's
    ///         ERC721Enumerable surface). Constructor takes (positionManager, navCalculator); the active
    ///         pool set lives on NAVCalculator (nav-config instances). Reverts the interim assisted adapter.
    function _deployUniswapV3PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        address positionManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionManager")
        );

        UniswapV3PoolsMetaBalanceAdapter adapter = new UniswapV3PoolsMetaBalanceAdapter(positionManager, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the PancakeSwap V3 pools meta-adapter (subclass of the Uniswap V3 meta-adapter, differs only
    ///         in the protocol-identity slugs and the `_slot0` uint32-feeProtocol decode override). Same constructor
    ///         shape as the Uniswap V3 pools meta-adapter.
    function _deployPancakeSwapV3PoolsMeta(string memory adapterName, address navCalculator)
        internal
        returns (address)
    {
        address positionManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionManager")
        );

        PancakeSwapV3PoolsMetaBalanceAdapter adapter =
            new PancakeSwapV3PoolsMetaBalanceAdapter(positionManager, navCalculator);
        return address(adapter);
    }

    /// @notice Deploys the Uniswap V2 pools meta-adapter. Serves PancakeSwap V2 too (same contract via the
    ///         PancakeSwapV2PoolsMeta thin subclass when keyed "PancakeSwapV2PoolsMeta"). Constructor takes
    ///         (navCalculator); the pair set is configured on NAVCalculator (ADR 0010).
    function _deployUniswapV2PoolsMeta(string memory adapterName, address navCalculator) internal returns (address) {
        if (_equals(adapterName, "PancakeSwapV2PoolsMeta")) {
            return address(new PancakeSwapV2PoolsMetaBalanceAdapter(navCalculator));
        }
        return address(new UniswapV2PoolsMetaBalanceAdapter(navCalculator));
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
