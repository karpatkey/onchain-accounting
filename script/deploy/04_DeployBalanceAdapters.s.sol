// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import balance adapters
import {AaveV2InstanceBalanceOracle} from "../../src/balances/protocols/AaveV2Instance.sol";
import {AaveV3InstanceBalanceOracle} from "../../src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "../../src/balances/protocols/CompoundV3Comet.sol";
import {MorphoMarketBalanceOracle} from "../../src/balances/protocols/MorphoMarket.sol";
import {SparkLendBalanceOracle} from "../../src/balances/protocols/SparkLend.sol";
import {DaiDsrBalanceOracle} from "../../src/balances/protocols/DaiDsr.sol";
import {SkySavingsUsdsBalanceOracle} from "../../src/balances/protocols/SkySavingsUsds.sol";
import {MorphoVaultBalanceOracle} from "../../src/balances/protocols/MorphoVault.sol";
import {GearboxMarketBalanceOracle} from "../../src/balances/protocols/GearboxMarket.sol";
import {CapBalanceOracle} from "../../src/balances/protocols/Cap.sol";
import {CurveBalanceOracle} from "../../src/balances/protocols/Curve.sol";
import {ConvexBalanceOracle} from "../../src/balances/protocols/Convex.sol";
import {AaveV3SafetyModuleBalanceOracle} from "../../src/balances/protocols/AaveV3SafetyModule.sol";
import {AaveUmbrellaBalanceOracle} from "../../src/balances/protocols/AaveUmbrella.sol";
import {BalancerV3PoolBalanceOracle} from "../../src/balances/protocols/BalancerV3.sol";
import {Aura} from "../../src/balances/protocols/Aura.sol";
import {StakeWiseV3VaultBalanceOracle} from "../../src/balances/protocols/StakeWiseV3Vault.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "../../src/balances/protocols/StakeWiseV3OsToken.sol";
import {MerklRewardsBalanceOracle} from "../../src/balances/protocols/MerklRewards.sol";

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
        _deployIfEnabled("AaveV3_Core"); // Mainnet Aave V3 core market
        _deployIfEnabled("AaveV3_Prime"); // Mainnet Aave V3 Prime market
        _deployIfEnabled("AaveV3_Arbitrum");
        _deployIfEnabled("AaveV3_Base");
        _deployIfEnabled("AaveV3_Optimism");
        _deployIfEnabled("AaveV3_Gnosis");

        // --- Aave V2 (Mainnet only — V2 is governance-deprecated everywhere else this repo deploys) ---
        _deployIfEnabled("AaveV2_Mainnet");

        // --- Spark Lend (Mainnet only) ---
        _deployIfEnabled("SparkLend");

        // --- Aave V3 Safety Module (Mainnet only; single multi-token adapter, see ADR 0002) ---
        _deployIfEnabled("AaveV3SafetyModule");

        // --- Aave Umbrella (Mainnet only; multi-token adapter mirroring the SM design, see ADR 0007) ---
        _deployIfEnabled("AaveUmbrella");

        // --- Cap Finance (Mainnet only) ---
        _deployIfEnabled("Cap");

        // --- Morpho Vaults (one per vault) ---
        _deployIfEnabled("MorphoVault_kpkETHPrime_V1"); // Mainnet — ETH Alpha
        _deployIfEnabled("MorphoVault_kpkETHPrime_V2"); // Mainnet — ETH Alpha
        _deployIfEnabled("MorphoVault_kpkUSDCPrime_V1"); // Mainnet — USD Alpha
        _deployIfEnabled("MorphoVault_kpkUSDCPrime_V2"); // Mainnet — USD Alpha
        _deployIfEnabled("MorphoVault_kpkUSDCYieldV1"); // Arbitrum — USD Alpha

        // --- Morpho Markets (one per market id; USD Alpha — Mainnet) ---
        _deployIfEnabled("MorphoMarket_wstETH_USDC");
        _deployIfEnabled("MorphoMarket_cbBTC_USDC"); // Mainnet + Base (different marketIds)
        _deployIfEnabled("MorphoMarket_wstUSR_USDC");
        _deployIfEnabled("MorphoMarket_ETHPlus_USDC");
        _deployIfEnabled("MorphoMarket_WBTC_USDC");
        _deployIfEnabled("MorphoMarket_RLP_USDC");
        _deployIfEnabled("MorphoMarket_syrupUSDC_USDC"); // Mainnet + Arbitrum
        _deployIfEnabled("MorphoMarket_sUSDS_USDT"); // Mainnet
        _deployIfEnabled("MorphoMarket_sUSDS_USDC"); // Arbitrum

        // --- Morpho Markets (ETH Alpha — Mainnet + Base) ---
        _deployIfEnabled("MorphoMarket_ETHPlus_WETH"); // Mainnet
        _deployIfEnabled("MorphoMarket_wstETH_WETH"); // Mainnet + Base
        _deployIfEnabled("MorphoMarket_weETH_WETH"); // Mainnet + Base
        _deployIfEnabled("MorphoMarket_rsETH_WETH"); // Mainnet
        _deployIfEnabled("MorphoMarket_cbETH_USDC"); // Base — USD Alpha

        // --- Gearbox Markets (Mainnet — ETH Alpha) ---
        _deployIfEnabled("GearboxMarket_kpkWETH");
        _deployIfEnabled("GearboxMarket_kpkwstETH");

        // --- Balancer V3 (one per pool) ---
        _deployIfEnabled("BalancerV3_rETH_WETH"); // Mainnet — ETH Alpha
        _deployIfEnabled("BalancerV3_GHO_USDT_USDC"); // Mainnet — USD Alpha (Boosted GHO/USDT/USDC underlying; Aura adapter wraps it)
        _deployIfEnabled("BalancerV3_GHO_USDC_USDT"); // Arbitrum — USD Alpha (Boosted GHO/USDC/USDT underlying)
        _deployIfEnabled("BalancerV3_GHO_USDC"); // Base — USD Alpha (Boosted GHO/USDC underlying)

        // --- Aura (one per pool) ---
        _deployIfEnabled("Aura_rETH_WETH"); // Mainnet — ETH Alpha
        _deployIfEnabled("Aura_GHO_USDT_USDC"); // Mainnet — USD Alpha
        _deployIfEnabled("Aura_GHO_USDC_USDT"); // Arbitrum — USD Alpha
        _deployIfEnabled("Aura_GHO_USDC"); // Base — USD Alpha

        // --- Curve (one per gauge — Mainnet) ---
        _deployIfEnabled("Curve_weETH_WETH"); // ETH Alpha
        _deployIfEnabled("Curve_crvUSD_USDC"); // USD Alpha (Convex-underlying)
        _deployIfEnabled("Curve_crvUSD_USDT"); // USD Alpha (Convex-underlying)
        _deployIfEnabled("Curve_RLUSD_USDC"); // USD Alpha (Convex-underlying)

        // --- Convex (one per rewarder — Mainnet) ---
        _deployIfEnabled("Convex_weETH_WETH"); // ETH Alpha
        _deployIfEnabled("Convex_crvUSD_USDC"); // USD Alpha
        _deployIfEnabled("Convex_crvUSD_USDT"); // USD Alpha
        _deployIfEnabled("Convex_RLUSD_USDC"); // USD Alpha

        // --- Merkl Rewards (single instance per chain; Distributor address is identical on every EVM chain) ---
        _deployIfEnabled("MerklRewards");

        // ERC20Default is deployed in NAVCalculator.initialize() when the NAV proxy is set up (02_DeployProxies); it is not deployed here.
        // CompoundV3, DaiDsr, SkySavingsUsds, StakeWiseV3*, and AaveV3SafetyModule_stkAAVE adapters
        // exist in this repo but are NOT used by either Alpha fund, so they are not wired here.

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

        // AaveV2 adapters (Aave V2's data provider has the same getUserReserveData / getAllReservesTokens
        // ABI as V3, so the V2 adapter is a thin subclass — see src/balances/protocols/AaveV2Instance.sol)
        if (_equals(adapterName, "AaveV2") || _startsWith(adapterName, "AaveV2_")) {
            return _deployAaveV2(adapterName, navCalculator);
        }

        // AaveV3 adapters
        if (_startsWith(adapterName, "AaveV3_")) {
            return _deployAaveV3(adapterName, navCalculator);
        }

        // CompoundV3 adapters
        if (_startsWith(adapterName, "CompoundV3_")) {
            return _deployCompoundV3(adapterName, navCalculator);
        }

        // SparkLend adapters (bare name for single-instance, prefix for future multi-market)
        if (_equals(adapterName, "SparkLend") || _startsWith(adapterName, "SparkLend_")) {
            return _deploySparkLend(adapterName, navCalculator);
        }

        // MorphoBlue adapters
        if (_startsWith(adapterName, "MorphoMarket_")) {
            return _deployMorphoMarket(adapterName, navCalculator);
        }

        // DAI DSR
        if (_equals(adapterName, "DaiDsr")) {
            return _deployDaiDsr(navCalculator);
        }

        // Sky Savings USDS
        if (_equals(adapterName, "SkySavingsUsds")) {
            return _deploySkySavingsUsds(navCalculator);
        }

        // Morpho Vault adapters
        if (_startsWith(adapterName, "MorphoVault_")) {
            return _deployMorphoVault(adapterName, navCalculator);
        }

        // Gearbox Market adapters
        if (_startsWith(adapterName, "GearboxMarket_")) {
            return _deployGearboxMarket(adapterName, navCalculator);
        }

        // Cap Finance adapter
        if (_equals(adapterName, "Cap")) {
            return _deployCap(navCalculator);
        }

        // Curve adapters
        if (_startsWith(adapterName, "Curve_")) {
            return _deployCurve(adapterName, navCalculator);
        }

        // Convex adapters
        if (_startsWith(adapterName, "Convex_")) {
            return _deployConvex(adapterName, navCalculator);
        }

        // AaveV3 Safety Module: a single multi-token adapter per chain (ADR 0002).
        if (_equals(adapterName, "AaveV3SafetyModule")) {
            return _deployAaveV3SafetyModule(adapterName, navCalculator);
        }

        // Aave Umbrella: a single multi-token adapter per chain (ADR 0007).
        if (_equals(adapterName, "AaveUmbrella")) {
            return _deployAaveUmbrella(adapterName, navCalculator);
        }

        // Balancer V3 adapters
        if (_startsWith(adapterName, "BalancerV3_")) {
            return _deployBalancerV3(adapterName, navCalculator);
        }

        // Aura adapters
        if (_startsWith(adapterName, "Aura_")) {
            return _deployAura(adapterName, navCalculator);
        }

        // StakeWise V3 Vault adapters
        if (_startsWith(adapterName, "StakeWiseV3Vault_")) {
            return _deployStakeWiseV3Vault(adapterName, navCalculator);
        }

        // StakeWise V3 OsToken adapters
        if (_startsWith(adapterName, "StakeWiseV3OsToken_")) {
            return _deployStakeWiseV3OsToken(adapterName, navCalculator);
        }

        // Merkl Rewards: proof-cached unclaimed-reward adapter (ADR 0007).
        if (_equals(adapterName, "MerklRewards")) {
            return _deployMerklRewards(adapterName, navCalculator);
        }

        // Unknown adapter type
        console2.log("Unknown adapter type:", adapterName);
        return address(0);
    }

    function _deployAaveV2(string memory adapterName, address navCalculator) internal returns (address) {
        address dataProvider = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "dataProvider")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        AaveV2InstanceBalanceOracle adapter = new AaveV2InstanceBalanceOracle(dataProvider, protocol, navCalculator);
        return address(adapter);
    }

    function _deployAaveV3(string memory adapterName, address navCalculator) internal returns (address) {
        address dataProvider = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "dataProvider")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        AaveV3InstanceBalanceOracle adapter = new AaveV3InstanceBalanceOracle(dataProvider, protocol, navCalculator);
        return address(adapter);
    }

    function _deployCompoundV3(string memory adapterName, address navCalculator) internal returns (address) {
        address compoundRewards = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "compoundRewards")
        );
        address comet =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "comet"));
        address rewardToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        CompoundV3Comet adapter = new CompoundV3Comet(compoundRewards, comet, rewardToken, protocol, navCalculator);
        return address(adapter);
    }

    function _deploySparkLend(string memory adapterName, address navCalculator) internal returns (address) {
        address dataProvider = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "dataProvider")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        SparkLendBalanceOracle adapter = new SparkLendBalanceOracle(dataProvider, protocol, navCalculator);
        return address(adapter);
    }

    function _deployMorphoMarket(string memory adapterName, address navCalculator) internal returns (address) {
        address morpho = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "morpho")
        );
        string memory marketIdStr =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "marketId");
        bytes32 marketId = vm.parseBytes32(marketIdStr);
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        MorphoMarketBalanceOracle adapter = new MorphoMarketBalanceOracle(morpho, marketId, protocol, navCalculator);
        return address(adapter);
    }

    function _deployDaiDsr(address navCalculator) internal returns (address) {
        address dai =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "DaiDsr", "dai"));
        address dsrManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "DaiDsr", "dsrManager")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "DaiDsr", "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "DaiDsr", "positionDetail");

        DaiDsrBalanceOracle adapter = new DaiDsrBalanceOracle(dai, dsrManager, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deploySkySavingsUsds(address navCalculator) internal returns (address) {
        address savingsUsds = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "SkySavingsUsds", "savingsUsds")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "SkySavingsUsds", "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "SkySavingsUsds", "positionDetail");

        SkySavingsUsdsBalanceOracle adapter =
            new SkySavingsUsdsBalanceOracle(savingsUsds, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployMorphoVault(string memory adapterName, address navCalculator) internal returns (address) {
        address vault =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vault"));
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        MorphoVaultBalanceOracle adapter = new MorphoVaultBalanceOracle(vault, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployGearboxMarket(string memory adapterName, address navCalculator) internal returns (address) {
        address market = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "market")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        GearboxMarketBalanceOracle adapter =
            new GearboxMarketBalanceOracle(market, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployCap(address navCalculator) internal returns (address) {
        address cUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "cUsd"));
        address stcUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "stcUsd"));
        address usdc =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "usdc"));
        string memory protocol = ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", "Cap", "positionDetail");

        CapBalanceOracle adapter = new CapBalanceOracle(cUsd, stcUsd, usdc, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployCurve(string memory adapterName, address navCalculator) internal returns (address) {
        address gauge =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "gauge"));
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        CurveBalanceOracle adapter = new CurveBalanceOracle(gauge, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployConvex(string memory adapterName, address navCalculator) internal returns (address) {
        address rewarder = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewarder")
        );
        address lpToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "lpToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        ConvexBalanceOracle adapter =
            new ConvexBalanceOracle(rewarder, lpToken, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployAaveV3SafetyModule(string memory adapterName, address navCalculator) internal returns (address) {
        // Schema (chains/<id>.json):
        //   "AaveV3SafetyModule": {
        //     "enabled": true,
        //     "constructor": { "protocol": "Aave V3 Safety Module" }
        //   }
        // The set of stake tokens is hardcoded in the adapter (AaveV3SafetyModuleBalanceOracle).
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        AaveV3SafetyModuleBalanceOracle adapter = new AaveV3SafetyModuleBalanceOracle(navCalculator, protocol);
        return address(adapter);
    }

    function _deployAaveUmbrella(string memory adapterName, address navCalculator) internal returns (address) {
        // Schema (chains/<id>.json):
        //   "AaveUmbrella": {
        //     "enabled": true,
        //     "constructor": {
        //       "rewardsController": "0x4655Ce3D625a63d30bA704087E52B4C31E38188B",
        //       "protocol": "Aave Umbrella"
        //     }
        //   }
        // The Umbrella stake-token set is discovered at runtime from the RewardsController address
        // above via `getAllAssets()`. See ADR 0007 for the dynamic-discovery rationale.
        address rewardsController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardsController")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        AaveUmbrellaBalanceOracle adapter = new AaveUmbrellaBalanceOracle(rewardsController, navCalculator, protocol);
        return address(adapter);
    }

    function _deployBalancerV3(string memory adapterName, address navCalculator) internal returns (address) {
        address pool =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "pool"));
        address gauge =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "gauge"));
        address balancerMinter = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "balancerMinter")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        BalancerV3PoolBalanceOracle adapter =
            new BalancerV3PoolBalanceOracle(pool, gauge, balancerMinter, protocol, navCalculator);
        return address(adapter);
    }

    function _deployAura(string memory adapterName, address navCalculator) internal returns (address) {
        address pool =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "pool"));
        address gauge =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "gauge"));
        address booster = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "booster")
        );
        uint256 pid =
            vm.parseUint(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "pid"));
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        // AURA token address is resolved dynamically inside the adapter constructor via Booster.minter()
        // (Mainnet: returns AURA; L2: returns L2Coordinator whose auraOFT() is the bridged AURA).
        Aura adapter = new Aura(pool, gauge, booster, pid, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployStakeWiseV3Vault(string memory adapterName, address navCalculator) internal returns (address) {
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        address vault =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "vault"));
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        StakeWiseV3VaultBalanceOracle adapter =
            new StakeWiseV3VaultBalanceOracle(underlyingToken, vault, protocol, positionDetail, navCalculator);
        return address(adapter);
    }

    function _deployStakeWiseV3OsToken(string memory adapterName, address navCalculator) internal returns (address) {
        address osToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "osToken")
        );
        address underlyingToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "underlyingToken")
        );
        address osTokenVaultController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "osTokenVaultController")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        StakeWiseV3OsTokenBalanceOracle adapter = new StakeWiseV3OsTokenBalanceOracle(
            osToken, underlyingToken, osTokenVaultController, protocol, positionDetail, navCalculator
        );
        return address(adapter);
    }

    function _deployMerklRewards(string memory adapterName, address navCalculator) internal returns (address) {
        // Schema (chains/<id>.json):
        //   "MerklRewards": {
        //     "enabled": true,
        //     "constructor": {
        //       "distributor": "0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae",  // same on every supported EVM chain
        //       "protocol": "Merkl",
        //       "positionDetail": "Unclaimed Rewards"
        //     }
        //   }
        // Owner is set to chainConfig.admin (the OIV Safe). The Safe will be the only address that can call
        // submitProof / clearAllocation. Proof verification on-chain prevents the owner from fabricating amounts;
        // see docs/decisions/0007-merkl-trust-minimized-cache.md.
        address distributor = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "distributor")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        require(chainConfig.admin != address(0), "MerklRewards: chainConfig.admin (initialOwner) not configured");

        MerklRewardsBalanceOracle adapter =
            new MerklRewardsBalanceOracle(distributor, navCalculator, protocol, positionDetail, chainConfig.admin);
        return address(adapter);
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
