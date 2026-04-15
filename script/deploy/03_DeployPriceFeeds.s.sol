// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import price adapters
import {sDAI_PriceOracle} from "../../src/prices/protocols/sDAI_Price.sol";
import {LDO_PriceOracle} from "../../src/prices/protocols/LDO_Price.sol";
import {sUSDS_PriceOracle} from "../../src/prices/protocols/sUSDS_Price.sol";
import {sUSDe_PriceOracle} from "../../src/prices/protocols/sUSDe_Price.sol";
import {syrupUSDC_PriceOracle} from "../../src/prices/protocols/syrupUSDC_Price.sol";
import {wstETH_PriceOracle} from "../../src/prices/protocols/wstETH_Price.sol";
import {rETH_PriceOracle} from "../../src/prices/protocols/rETH_Price.sol";
import {cbETH_PriceOracle} from "../../src/prices/protocols/cbETH_Price.sol";
import {weETH_PriceOracle} from "../../src/prices/protocols/weETH_Price.sol";
import {rsETH_PriceOracle} from "../../src/prices/protocols/rsETH_Price.sol";
import {eETH_PriceOracle} from "../../src/prices/protocols/eETH_Price.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "../../src/prices/protocols/sXDAI_Price.sol";

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
            _deploySdai();
        }

        // Deploy LDO Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "LDO")) {
            _deployLdo();
        }

        // Deploy sUSDS Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sUSDS")) {
            _deploySusds();
        }

        // Deploy sUSDe Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sUSDe")) {
            _deploySUsde();
        }

        // Deploy syrupUSDC Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "syrupUSDC")) {
            _deploySyrupUsdc();
        }

        // Deploy wstETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH")) {
            _deployWstEth();
        }

        // Deploy rETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "rETH")) {
            _deployREth();
        }

        // Deploy cbETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "cbETH")) {
            _deployCbEth();
        }

        // Deploy weETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "weETH")) {
            _deployWeEth();
        }

        // Deploy rsETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "rsETH")) {
            _deployRsEth();
        }

        // Deploy eETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "eETH")) {
            _deployEEth();
        }

        vm.stopBroadcast();
    }

    function _deploySdai() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "sDAI");
        if (deployed != address(0)) {
            console2.log("sDAI_PriceOracle already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address sDai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "sDai"));
        address dsrManager = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "dsrManager"));
        address daiOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "daiToUsdChainlinkOracle"));
        uint256 daiHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "daiToUsdChainlinkHeartbeat"));

        // Deploy
        sDAI_PriceOracle sdaiAdapter = new sDAI_PriceOracle(sDai, dsrManager, daiOracle, daiHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sDAI", address(sdaiAdapter));
        console2.log("sDAI_PriceOracle deployed at:", address(sdaiAdapter));
    }

    function _deployLdo() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "LDO");
        if (deployed != address(0)) {
            console2.log("LDO_PriceOracle already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address ldo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldo"));
        address ldoEthOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldoToEthChainlinkAddress"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ethToUsdChainlinkAddress"));
        uint256 ldoEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldoToEthChainlinkHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ethToUsdChainlinkHeartbeat"));

        // Deploy
        LDO_PriceOracle ldoAdapter =
            new LDO_PriceOracle(ldo, ldoEthOracle, ethUsdOracle, ldoEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "LDO", address(ldoAdapter));
        console2.log("LDO_PriceOracle deployed at:", address(ldoAdapter));
    }

    function _deploySusds() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "sUSDS");
        if (deployed != address(0)) {
            console2.log("sUSDS_PriceOracle already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address sUsds = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "sUsds"));
        address usdsUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "usdsToUsdChainlinkAddress"));
        uint256 usdsUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "usdsToUsdChainlinkHeartbeat"));

        // Deploy
        sUSDS_PriceOracle susdsAdapter = new sUSDS_PriceOracle(sUsds, usdsUsdOracle, usdsUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sUSDS", address(susdsAdapter));
        console2.log("sUSDS_PriceOracle deployed at:", address(susdsAdapter));
    }

    function _deploySUsde() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "sUSDe");
        if (deployed != address(0)) {
            console2.log("sUSDe_PriceOracle already deployed at:", deployed);
            return;
        }

        address sUsde = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "sUsde"));
        address usdeUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "usdeToUsdChainlinkAddress"));
        uint256 usdeUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "usdeToUsdChainlinkHeartbeat"));

        sUSDe_PriceOracle susdeAdapter = new sUSDe_PriceOracle(sUsde, usdeUsdOracle, usdeUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sUSDe", address(susdeAdapter));
        console2.log("sUSDe_PriceOracle deployed at:", address(susdeAdapter));
    }

    function _deploySyrupUsdc() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "syrupUSDC");
        if (deployed != address(0)) {
            console2.log("syrupUSDC_PriceOracle already deployed at:", deployed);
            return;
        }

        address syrupUsdc =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC", "syrupUsdc"));
        address usdcUsdOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC", "usdcToUsdChainlinkAddress")
        );
        uint256 usdcUsdHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC", "usdcToUsdChainlinkHeartbeat")
        );

        syrupUSDC_PriceOracle syrupUsdcAdapter = new syrupUSDC_PriceOracle(syrupUsdc, usdcUsdOracle, usdcUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "syrupUSDC", address(syrupUsdcAdapter));
        console2.log("syrupUSDC_PriceOracle deployed at:", address(syrupUsdcAdapter));
    }

    function _deployWstEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "wstETH");
        if (deployed != address(0)) {
            console2.log("wstETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "wstEth"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "ethToUsdChainlinkHeartbeat"));

        wstETH_PriceOracle wstEthAdapter = new wstETH_PriceOracle(wstEth, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "wstETH", address(wstEthAdapter));
        console2.log("wstETH_PriceOracle deployed at:", address(wstEthAdapter));
    }

    function _deployREth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rETH");
        if (deployed != address(0)) {
            console2.log("rETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address rEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "rEth"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "ethToUsdChainlinkHeartbeat"));

        rETH_PriceOracle rEthAdapter = new rETH_PriceOracle(rEth, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rETH", address(rEthAdapter));
        console2.log("rETH_PriceOracle deployed at:", address(rEthAdapter));
    }

    function _deployCbEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "cbETH");
        if (deployed != address(0)) {
            console2.log("cbETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "cbEth"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "ethToUsdChainlinkHeartbeat"));

        cbETH_PriceOracle cbEthAdapter = new cbETH_PriceOracle(cbEth, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "cbETH", address(cbEthAdapter));
        console2.log("cbETH_PriceOracle deployed at:", address(cbEthAdapter));
    }

    function _deployWeEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "weETH");
        if (deployed != address(0)) {
            console2.log("weETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH", "weEth"));
        address weEthToEthOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH", "weEthToEthChainlinkOracle"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH", "ethToUsdChainlinkOracle"));
        uint256 weEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH", "weEthToEthChainlinkHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH", "ethToUsdChainlinkHeartbeat"));

        weETH_PriceOracle weEthAdapter =
            new weETH_PriceOracle(weEth, weEthToEthOracle, ethUsdOracle, weEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "weETH", address(weEthAdapter));
        console2.log("weETH_PriceOracle deployed at:", address(weEthAdapter));
    }

    function _deployRsEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rsETH");
        if (deployed != address(0)) {
            console2.log("rsETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "rsEth"));
        address rateProvider =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "rateProvider"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "ethToUsdChainlinkHeartbeat"));

        rsETH_PriceOracle rsEthAdapter = new rsETH_PriceOracle(rsEth, rateProvider, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rsETH", address(rsEthAdapter));
        console2.log("rsETH_PriceOracle deployed at:", address(rsEthAdapter));
    }

    function _deployEEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "eETH");
        if (deployed != address(0)) {
            console2.log("eETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address eEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "eETH", "eEth"));
        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "eETH", "weEth"));
        address weEthToEthOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "eETH", "weEthToEthChainlinkOracle"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "eETH", "ethToUsdChainlinkOracle"));
        uint256 weEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "eETH", "weEthToEthChainlinkHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "eETH", "ethToUsdChainlinkHeartbeat"));

        eETH_PriceOracle eEthAdapter =
            new eETH_PriceOracle(eEth, weEth, weEthToEthOracle, ethUsdOracle, weEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "eETH", address(eEthAdapter));
        console2.log("eETH_PriceOracle deployed at:", address(eEthAdapter));
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

        // Deploy sXDAI Price Oracle (Gnosis savings xDAI)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sXDAI")) {
            _deploySxdai();
        }

        vm.stopBroadcast();

        console2.log("Gnosis price feeds deployed successfully!");
    }

    function _deploySxdai() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "sXDAI");
        if (deployed != address(0)) {
            console2.log("sXDAI_PriceOracle already deployed at:", deployed);
            return;
        }

        address sXdai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "sXdai"));
        address xDaiUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "xDaiToUsdChainlinkOracle"));
        uint256 xDaiUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "xDaiToUsdChainlinkHeartbeat"));

        sXDAI_PriceOracle sxdaiAdapter = new sXDAI_PriceOracle(sXdai, xDaiUsdOracle, xDaiUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sXDAI", address(sxdaiAdapter));
        console2.log("sXDAI_PriceOracle deployed at:", address(sxdaiAdapter));
    }
}
