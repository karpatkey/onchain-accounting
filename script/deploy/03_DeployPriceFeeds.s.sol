// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import price adapters
import {sDAI_PriceOracle} from "../../src/prices/protocols/sDAI_Price.sol";
import {LDO_PriceOracle} from "../../src/prices/protocols/LDO_Price.sol";
import {sUSDS_PriceOracle} from "../../src/prices/protocols/sUSDS_Price.sol";

// import {CrossRatePriceAdapter} from "../../src/prices/protocols/CrossRate_Price.sol";

/// @title DeployPriceFeeds
/// @notice Deploys custom price feed adapters for NAVCalculator
/// @dev Price feeds are NOT upgradeable - they can be swapped via setPriceFeed
contract DeployPriceFeeds is BaseDeployScript {
    function run() public override {
        setUp();

        console2.log("\n=== Deploying Price Feeds ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("");

        // Deploy price feeds based on chain and enabled configuration
        if (currentChainId == 1) {
            // Mainnet
            _deployMainnetPriceAdapters();
        } else if (currentChainId == 42161) {
            // Arbitrum
            _deployArbitrumPriceAdapters();
        } else if (currentChainId == 10) {
            // Optimism
            _deployOptimismPriceAdapters();
        } else if (currentChainId == 8453) {
            // Base
            _deployBasePriceAdapters();
        } else if (currentChainId == 100) {
            // Gnosis
            _deployGnosisPriceAdapters();
        } else {
            console2.log("No price feeds configured for chain:", currentChainId);
        }

        console2.log("\n=== Next Steps ===");
        console2.log("1. Verify deployed price feeds on Etherscan");
        console2.log("2. Use ManageAdapters script to set price feeds in NAVCalculator");
        console2.log("   Example: _setPriceFeed(assetAddress, priceFeedAddress, 'Custom', heartbeat)");
        console2.log("====================");
    }

    // Mainnet price feed deployments
    function _deployMainnetPriceAdapters() internal {
        console2.log("Deploying Mainnet price feeds...\n");

        vm.startBroadcast();

        // Deploy sDAI Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sDAI")) {
            _deploySDAI();
        }

        // Deploy LDO Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "LDO")) {
            _deployLDO();
        }

        // Deploy sUSDS Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sUSDS")) {
            _deploySUSDS();
        }

        vm.stopBroadcast();
    }

    function _deploySDAI() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "sDAI");
        if (deployed != address(0)) {
            console2.log("sDAI_PriceOracle already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address sDai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "sDai"));
        address dsrManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "dsrManager"));
        address daiOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "daiToUsdChainlinkOracle")
        );
        uint256 daiHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "daiToUsdChainlinkHeartbeat")
        );

        // Deploy
        sDAI_PriceOracle sdaiAdapter = new sDAI_PriceOracle(sDai, dsrManager, daiOracle, daiHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sDAI", address(sdaiAdapter));
        console2.log("sDAI_PriceOracle deployed at:", address(sdaiAdapter));
    }

    function _deployLDO() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "LDO");
        if (deployed != address(0)) {
            console2.log("LDO_PriceOracle already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address ldo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldo"));
        address ldoEthOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldoToEthChainlinkAddress")
        );
        address ethUsdOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ethToUsdChainlinkAddress")
        );
        uint256 ldoEthHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldoToEthChainlinkHeartbeat")
        );
        uint256 ethUsdHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ethToUsdChainlinkHeartbeat")
        );

        // Deploy
        LDO_PriceOracle ldoAdapter =
            new LDO_PriceOracle(ldo, ldoEthOracle, ethUsdOracle, ldoEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "LDO", address(ldoAdapter));
        console2.log("LDO_PriceOracle deployed at:", address(ldoAdapter));
    }

    function _deploySUSDS() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "sUSDS");
        if (deployed != address(0)) {
            console2.log("sUSDS_PriceOracle already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address sUsds = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "sUsds"));
        address usdsUsdOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "usdsToUsdChainlinkAddress")
        );
        uint256 usdsUsdHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "usdsToUsdChainlinkHeartbeat")
        );

        // Deploy
        sUSDS_PriceOracle susdsAdapter = new sUSDS_PriceOracle(sUsds, usdsUsdOracle, usdsUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sUSDS", address(susdsAdapter));
        console2.log("sUSDS_PriceOracle deployed at:", address(susdsAdapter));
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

    // Arbitrum price feed deployments
    function _deployArbitrumPriceAdapters() internal {
        console2.log("Deploying Arbitrum price feeds...\n");

        vm.startBroadcast();

        // Add Arbitrum-specific price feeds here
        // Example:
        // CrossRatePriceAdapter crossRate = new CrossRatePriceAdapter(feed1, feed2);
        // saveDeployedAddress("CrossRatePriceAdapter", address(crossRate));

        vm.stopBroadcast();

        console2.log("Arbitrum price feeds deployed successfully!");
    }

    // Optimism price feed deployments
    function _deployOptimismPriceAdapters() internal {
        console2.log("Deploying Optimism price feeds...\n");

        vm.startBroadcast();

        // Add Optimism-specific price feeds here

        vm.stopBroadcast();

        console2.log("Optimism price feeds deployed successfully!");
    }

    // Base price feed deployments
    function _deployBasePriceAdapters() internal {
        console2.log("Deploying Base price feeds...\n");

        vm.startBroadcast();

        // Add Base-specific price feeds here

        vm.stopBroadcast();

        console2.log("Base price feeds deployed successfully!");
    }

    // Gnosis price feed deployments
    function _deployGnosisPriceAdapters() internal {
        console2.log("Deploying Gnosis price feeds...\n");

        vm.startBroadcast();

        // sXDAI Price Oracle (Gnosis savings xDAI)
        // Note: sXDAI_Price.sol exists but has contract name sDAI_PriceOracle (likely a typo in original)
        // Uncomment when ready to deploy:
        // import {sDAI_PriceOracle as sXDAI_PriceOracle} from "../../src/prices/protocols/sXDAI_Price.sol";
        // sXDAI_PriceOracle sxdaiAdapter = new sXDAI_PriceOracle();
        // saveDeployedAddress("sXDAI_PriceOracle", address(sxdaiAdapter));

        vm.stopBroadcast();

        console2.log("Gnosis price feeds deployed successfully!");
    }
}
