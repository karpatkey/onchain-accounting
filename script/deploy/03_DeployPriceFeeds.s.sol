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
import {ezETH_PriceOracle} from "../../src/prices/protocols/ezETH_Price.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "../../src/prices/protocols/sXDAI_Price.sol";

// L2 price adapters
import {wstETH_L2_PriceOracle} from "../../src/prices/protocols/wstETH_L2_Price.sol";
import {weETH_L2_PriceOracle} from "../../src/prices/protocols/weETH_L2_Price.sol";
import {cbETH_L2_PriceOracle} from "../../src/prices/protocols/cbETH_L2_Price.sol";
import {rsETH_L2_PriceOracle} from "../../src/prices/protocols/rsETH_L2_Price.sol";
import {ezETH_L2_PriceOracle} from "../../src/prices/protocols/ezETH_L2_Price.sol";
import {syrupUSDC_L2_PriceOracle} from "../../src/prices/protocols/syrupUSDC_L2_Price.sol";

// Note: ETHPlus_PriceOracle is intentionally NOT wired.
// The Alpha funds use a Chainlink feed (`ethPlusToUsdChainlink`) as ETH+ price source,
// so the Custom adapter at src/prices/protocols/ETHPlus_Price.sol is not deployed.

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

        // Deploy ezETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ezETH")) {
            _deployEzEth();
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

    function _deployEzEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ezETH");
        if (deployed != address(0)) {
            console2.log("ezETH_PriceOracle already deployed at:", deployed);
            return;
        }

        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "ezEth"));
        address restakeManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "restakeManager"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "ethToUsdChainlinkHeartbeat"));

        ezETH_PriceOracle ezEthAdapter = new ezETH_PriceOracle(ezEth, restakeManager, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ezETH", address(ezEthAdapter));
        console2.log("ezETH_PriceOracle deployed at:", address(ezEthAdapter));
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

        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH_L2")) {
            _deployWstEthL2();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "weETH_L2")) {
            _deployWeEthL2();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "rsETH_L2")) {
            _deployRsEthL2();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ezETH_L2")) {
            _deployEzEthL2();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "syrupUSDC_L2")) {
            _deploySyrupUsdcL2();
        }

        vm.stopBroadcast();
    }

    // Optimism price feed deployments
    // No Custom price adapters are required — the Alpha funds on Optimism use only
    // Chainlink feeds (wstETH/USD via direct Chainlink, USDC/USD, USDT/USD), which do
    // not need a deployed adapter.
    function _deployOptimismPriceAdapters() internal {
        console2.log("Deploying Optimism price feeds...");
        console2.log("No Custom price adapters configured for Optimism (Alpha funds use Chainlink).");
    }

    // Base price feed deployments
    function _deployBasePriceAdapters() internal {
        console2.log("Deploying Base price feeds...\n");

        vm.startBroadcast();

        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH_L2")) {
            _deployWstEthL2();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "weETH_L2")) {
            _deployWeEthL2();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "cbETH_L2")) {
            _deployCbEthL2();
        }

        vm.stopBroadcast();
    }

    // Gnosis price feed deployments
    function _deployGnosisPriceAdapters() internal {
        console2.log("Deploying Gnosis price feeds...\n");

        vm.startBroadcast();

        // Deploy sXDAI Price Oracle (Gnosis savings xDAI)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sXDAI")) {
            _deploySxdai();
        }

        // Deploy wstETH_L2 Price Oracle (Gnosis uses Aave ratio provider instead of Chainlink)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH_L2")) {
            _deployWstEthL2();
        }

        vm.stopBroadcast();
    }

    // Shared L2 deploy helpers — read constructor args from assets.json priceFeeds section.
    // The same adapter type is deployed on multiple chains (wstETH_L2 on Arbitrum, Base, Gnosis, etc.)
    // with different underlying token + feed addresses per chain; `currentChainId` selects the right row.
    function _deployWstEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "wstETH_L2");
        if (deployed != address(0)) {
            console2.log("wstETH_L2_PriceOracle already deployed at:", deployed);
            return;
        }

        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "wstEth"));
        address wstEthToEthChainlink =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "wstEthToEthChainlink"));
        address ethUsdOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "ethToUsdChainlinkOracle")
        );
        uint256 wstEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "wstEthToEthHeartbeat"));
        uint256 ethUsdHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "ethToUsdChainlinkHeartbeat")
        );

        wstETH_L2_PriceOracle adapter = new wstETH_L2_PriceOracle(
            wstEth, wstEthToEthChainlink, ethUsdOracle, wstEthToEthHeartbeat, ethUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "wstETH_L2", address(adapter));
        console2.log("wstETH_L2_PriceOracle deployed at:", address(adapter));
    }

    function _deployWeEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "weETH_L2");
        if (deployed != address(0)) {
            console2.log("weETH_L2_PriceOracle already deployed at:", deployed);
            return;
        }

        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "weEth"));
        address weEthToEethChainlink =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "weEthToEethChainlink"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "ethToUsdChainlinkOracle"));
        uint256 weEthToEethHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "weEthToEethHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "ethToUsdChainlinkHeartbeat"));

        weETH_L2_PriceOracle adapter =
            new weETH_L2_PriceOracle(weEth, weEthToEethChainlink, ethUsdOracle, weEthToEethHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "weETH_L2", address(adapter));
        console2.log("weETH_L2_PriceOracle deployed at:", address(adapter));
    }

    function _deployCbEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "cbETH_L2");
        if (deployed != address(0)) {
            console2.log("cbETH_L2_PriceOracle already deployed at:", deployed);
            return;
        }

        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "cbEth"));
        address cbEthToEthChainlink =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "cbEthToEthChainlink"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "ethToUsdChainlinkOracle"));
        uint256 cbEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "cbEthToEthHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "ethToUsdChainlinkHeartbeat"));

        cbETH_L2_PriceOracle adapter =
            new cbETH_L2_PriceOracle(cbEth, cbEthToEthChainlink, ethUsdOracle, cbEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "cbETH_L2", address(adapter));
        console2.log("cbETH_L2_PriceOracle deployed at:", address(adapter));
    }

    function _deployRsEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rsETH_L2");
        if (deployed != address(0)) {
            console2.log("rsETH_L2_PriceOracle already deployed at:", deployed);
            return;
        }

        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "rsEth"));
        address rsEthToEthChainlink =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "rsEthToEthChainlink"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "ethToUsdChainlinkOracle"));
        uint256 rsEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "rsEthToEthHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "ethToUsdChainlinkHeartbeat"));

        rsETH_L2_PriceOracle adapter =
            new rsETH_L2_PriceOracle(rsEth, rsEthToEthChainlink, ethUsdOracle, rsEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rsETH_L2", address(adapter));
        console2.log("rsETH_L2_PriceOracle deployed at:", address(adapter));
    }

    function _deployEzEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ezETH_L2");
        if (deployed != address(0)) {
            console2.log("ezETH_L2_PriceOracle already deployed at:", deployed);
            return;
        }

        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "ezEth"));
        address xRenzoDeposit =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "xRenzoDeposit"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "ethToUsdChainlinkHeartbeat"));

        ezETH_L2_PriceOracle adapter = new ezETH_L2_PriceOracle(ezEth, xRenzoDeposit, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ezETH_L2", address(adapter));
        console2.log("ezETH_L2_PriceOracle deployed at:", address(adapter));
    }

    function _deploySyrupUsdcL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "syrupUSDC_L2");
        if (deployed != address(0)) {
            console2.log("syrupUSDC_L2_PriceOracle already deployed at:", deployed);
            return;
        }

        address syrupUsdc =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "syrupUsdc"));
        address syrupUsdcToUsdcChainlink = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "syrupUsdcToUsdcChainlink")
        );
        address usdcUsdOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "usdcToUsdChainlinkOracle")
        );
        uint256 syrupUsdcToUsdcHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "syrupUsdcToUsdcHeartbeat")
        );
        uint256 usdcUsdHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "usdcToUsdChainlinkHeartbeat")
        );

        syrupUSDC_L2_PriceOracle adapter = new syrupUSDC_L2_PriceOracle(
            syrupUsdc, syrupUsdcToUsdcChainlink, usdcUsdOracle, syrupUsdcToUsdcHeartbeat, usdcUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "syrupUSDC_L2", address(adapter));
        console2.log("syrupUSDC_L2_PriceOracle deployed at:", address(adapter));
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
