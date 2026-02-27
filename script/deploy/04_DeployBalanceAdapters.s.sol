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

        // Unknown adapter type
        console2.log("Unknown adapter type:", adapterName);
        return address(0);
    }

    function _deployAaveV3(string memory adapterName, address navCalculator) internal returns (address) {
        address dataProvider = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "dataProvider")
        );
        address rewardsDistributor = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardsDistributor")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        AaveV3InstanceBalanceOracle adapter =
            new AaveV3InstanceBalanceOracle(dataProvider, rewardsDistributor, protocol, navCalculator);
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
        address rewardsDistributor = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "rewardsDistributor")
        );
        string memory protocol =
            ConfigReader.readAdapterParam(vm, currentChainId, "balanceAdapters", adapterName, "protocol");

        SparkLendBalanceOracle adapter =
            new SparkLendBalanceOracle(dataProvider, rewardsDistributor, protocol, navCalculator);
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
