// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import balance adapters
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
import {BalancerV3PoolBalanceOracle} from "../../src/balances/protocols/BalancerV3.sol";
import {Aura} from "../../src/balances/protocols/Aura.sol";
import {StakeWiseV3VaultBalanceOracle} from "../../src/balances/protocols/StakeWiseV3Vault.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "../../src/balances/protocols/StakeWiseV3OsToken.sol";

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

        // Deploy Aave V3 adapters
        _deployIfEnabled("AaveV3_USDC");
        _deployIfEnabled("AaveV3_WETH");

        // Deploy Compound V3 adapters
        _deployIfEnabled("CompoundV3_USDC");
        _deployIfEnabled("CompoundV3_WETH");

        // Deploy Spark Lend adapters
        _deployIfEnabled("SparkLend_USDC");

        // Deploy DAI DSR
        _deployIfEnabled("DaiDsr");

        // Deploy Sky Savings USDS
        _deployIfEnabled("SkySavingsUsds");

        // Deploy Morpho Vault adapters (one per vault, prefix MorphoVault_)
        _deployIfEnabled("MorphoVault_kpkUSDC_V1");
        _deployIfEnabled("MorphoVault_kpkUSDC_V2");

        // Deploy Gearbox Market adapters (one per market, prefix GearboxMarket_)
        _deployIfEnabled("GearboxMarket_kpkWETH");
        _deployIfEnabled("GearboxMarket_kpkwstETH");

        // Deploy Cap Finance adapter
        _deployIfEnabled("Cap");

        // Deploy Curve adapters (one per gauge, prefix Curve_)
        _deployIfEnabled("Curve_weETH_WETH");

        // Deploy Convex adapters (one per rewarder, prefix Convex_)
        _deployIfEnabled("Convex_crvUSD_USDT");

        // Deploy Aave V3 Safety Module adapters (one per stake token, prefix AaveV3SafetyModule_)
        _deployIfEnabled("AaveV3SafetyModule_stkAAVE");
        _deployIfEnabled("AaveV3SafetyModule_stkGHO");

        // Deploy Balancer V3 adapters (one per pool, prefix BalancerV3_)
        _deployIfEnabled("BalancerV3_weETH_WETH");

        // Deploy Aura adapters (one per pool, prefix Aura_)
        _deployIfEnabled("Aura_weETH_WETH");

        // Deploy StakeWise V3 Vault adapters (one per vault, prefix StakeWiseV3Vault_)
        _deployIfEnabled("StakeWiseV3Vault_WETH");

        // Deploy StakeWise V3 OsToken adapters (one per vault controller, prefix StakeWiseV3OsToken_)
        _deployIfEnabled("StakeWiseV3OsToken_WETH");

        // ERC20Default is deployed in NAVCalculator.initialize() when the NAV proxy is set up (02_DeployProxies); it is not deployed here.

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
        if (_startsWith(adapterName, "AaveV3_")) {
            return _deployAaveV3(adapterName, navCalculator);
        }

        // CompoundV3 adapters
        if (_startsWith(adapterName, "CompoundV3_")) {
            return _deployCompoundV3(adapterName, navCalculator);
        }

        // SparkLend adapters
        if (_startsWith(adapterName, "SparkLend_")) {
            return _deploySparkLend(adapterName, navCalculator);
        }

        // MorphoBlue adapters
        if (_startsWith(adapterName, "MorphoBlue_")) {
            return _deployMorphoBlue(adapterName, navCalculator);
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

        // AaveV3 Safety Module adapters
        if (_startsWith(adapterName, "AaveV3SafetyModule_")) {
            return _deployAaveV3SafetyModule(adapterName, navCalculator);
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

        // Unknown adapter type
        console2.log("Unknown adapter type:", adapterName);
        return address(0);
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

    function _deployMorphoBlue(string memory adapterName, address navCalculator) internal returns (address) {
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
        address stakeToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "stakeToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        AaveV3SafetyModuleBalanceOracle adapter =
            new AaveV3SafetyModuleBalanceOracle(stakeToken, protocol, positionDetail, navCalculator);
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
        address auraToken = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "auraToken")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "positionDetail");

        Aura adapter = new Aura(pool, gauge, booster, pid, auraToken, protocol, positionDetail, navCalculator);
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
