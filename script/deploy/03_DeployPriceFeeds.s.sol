// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import price adapters
import {sDAI_CustomPriceFeed} from "../../src/prices/protocols/sDAI_CustomPriceFeed.sol";
import {LDO_CustomPriceFeed} from "../../src/prices/protocols/LDO_CustomPriceFeed.sol";
import {sUSDS_CustomPriceFeed} from "../../src/prices/protocols/sUSDS_CustomPriceFeed.sol";
import {sUSDe_CustomPriceFeed} from "../../src/prices/protocols/sUSDe_CustomPriceFeed.sol";
import {syrupUSDC_CustomPriceFeed} from "../../src/prices/protocols/syrupUSDC_CustomPriceFeed.sol";
import {RWIV_CustomPriceFeed} from "../../src/prices/protocols/RWIV_CustomPriceFeed.sol";
import {wstETH_CustomPriceFeed} from "../../src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {rETH_CustomPriceFeed} from "../../src/prices/protocols/rETH_CustomPriceFeed.sol";
import {osToken_CustomPriceFeed} from "../../src/prices/protocols/osToken_CustomPriceFeed.sol";
import {cbETH_CustomPriceFeed} from "../../src/prices/protocols/cbETH_CustomPriceFeed.sol";
import {weETH_CustomPriceFeed} from "../../src/prices/protocols/weETH_CustomPriceFeed.sol";
import {rsETH_CustomPriceFeed} from "../../src/prices/protocols/rsETH_CustomPriceFeed.sol";
import {eETH_CustomPriceFeed} from "../../src/prices/protocols/eETH_CustomPriceFeed.sol";
import {ezETH_CustomPriceFeed} from "../../src/prices/protocols/ezETH_CustomPriceFeed.sol";
import {ETHx_CustomPriceFeed} from "../../src/prices/protocols/ETHx_CustomPriceFeed.sol";
// sXDAI shares the sDAI contract name — aliased import to avoid a naming collision
import {sXDAI_CustomPriceFeed} from "../../src/prices/protocols/sXDAI_CustomPriceFeed.sol";

// L2 price adapters
import {wstETH_L2_CustomPriceFeed} from "../../src/prices/protocols/wstETH_L2_CustomPriceFeed.sol";
import {weETH_L2_CustomPriceFeed} from "../../src/prices/protocols/weETH_L2_CustomPriceFeed.sol";
import {cbETH_L2_CustomPriceFeed} from "../../src/prices/protocols/cbETH_L2_CustomPriceFeed.sol";
import {rsETH_L2_CustomPriceFeed} from "../../src/prices/protocols/rsETH_L2_CustomPriceFeed.sol";
import {ezETH_L2_CustomPriceFeed} from "../../src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";
import {syrupUSDC_L2_CustomPriceFeed} from "../../src/prices/protocols/syrupUSDC_L2_CustomPriceFeed.sol";

import {ETHPlus_CustomPriceFeed} from "../../src/prices/protocols/ETHPlus_CustomPriceFeed.sol";

import {CrossRate_CustomPriceFeed} from "../../src/prices/protocols/CrossRate_CustomPriceFeed.sol";
import {ankrETH_CustomPriceFeed} from "../../src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {NXM_CustomPriceFeed} from "../../src/prices/protocols/NXM_CustomPriceFeed.sol";

/// @title DeployPriceFeeds
/// @notice Deploys custom price feed adapters for NAVCalculator
/// @dev Price feeds are NOT upgradeable — add new ones via addPriceFeed, remove old via removePriceFeed
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
        } else if (currentChainId == 137) {
            // Polygon: only Chainlink-priced assets are registered today (POL, WPOL, WETH,
            // USDC, USDT). No custom price-feed contracts to deploy. Add a branch here when
            // wstETH/sUSDe/etc. are onboarded with their custom adapters.
            console2.log("No custom price feeds to deploy on Polygon (Chainlink-only).");
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

        // Deploy RWIV Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "RWIV")) {
            _deployRwiv();
        }

        // Deploy wstETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH")) {
            _deployWstEth();
        }

        // Deploy stETH CrossRate Price Oracle (stETH/USD = ETH/USD x stETH/ETH)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "stETH")) {
            _deployStEth();
        }

        // Deploy lsETH CrossRate Price Oracle (lsETH/USD = ETH/USD x lsETH/ETH)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "lsETH")) {
            _deployLsEth();
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

        // Deploy ETHx Price Oracle (Stader)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ETHx")) {
            _deployEthx();
        }

        // Deploy ETHPlus Price Oracle (Reserve Protocol RToken)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ETHPlus")) {
            _deployEthPlus();
        }

        // Deploy osETH (StakeWise V3) osToken custom price feed on Mainnet (osGNO is deployed in the
        // Gnosis branch). osTokens are Custom-priced ERC20s (held balance via ERC20DefaultBalanceAdapter,
        // priced convertToAssets(1e18) * underlying/USD) rather than bespoke balance adapters.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "osETH")) {
            _deployOsToken("osETH");
        }

        // Deploy OETH CrossRate Price Oracle (OETH/USD = ETH/USD x OETH/ETH)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "OETH")) {
            _deployOeth();
        }

        // Deploy ankrETH Price Oracle (ankrETH/USD = ETH/USD * 1e18 / ratio)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ankrETH")) {
            _deployAnkrEth();
        }

        // Deploy NXM / wNXM Price Oracle (price = RAMM.getInternalPrice() [ETH/NXM] * ETH/USD)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "NXM")) {
            _deployNxm("NXM");
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wNXM")) {
            _deployNxm("wNXM");
        }

        vm.stopBroadcast();
    }

    function _deploySdai() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "sDAI");
        if (deployed != address(0)) {
            console2.log("sDAI_CustomPriceFeed already deployed at:", deployed);
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
        sDAI_CustomPriceFeed sdaiAdapter = new sDAI_CustomPriceFeed(sDai, dsrManager, daiOracle, daiHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sDAI", address(sdaiAdapter));
        console2.log("sDAI_CustomPriceFeed deployed at:", address(sdaiAdapter));
    }

    function _deployLdo() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "LDO");
        if (deployed != address(0)) {
            console2.log("LDO_CustomPriceFeed already deployed at:", deployed);
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
        LDO_CustomPriceFeed ldoAdapter =
            new LDO_CustomPriceFeed(ldo, ldoEthOracle, ethUsdOracle, ldoEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "LDO", address(ldoAdapter));
        console2.log("LDO_CustomPriceFeed deployed at:", address(ldoAdapter));
    }

    function _deploySusds() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "sUSDS");
        if (deployed != address(0)) {
            console2.log("sUSDS_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from assets config
        address sUsds = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "sUsds"));
        address usdsUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "usdsToUsdChainlinkAddress"));
        uint256 usdsUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "usdsToUsdChainlinkHeartbeat"));

        // Deploy
        sUSDS_CustomPriceFeed susdsAdapter = new sUSDS_CustomPriceFeed(sUsds, usdsUsdOracle, usdsUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sUSDS", address(susdsAdapter));
        console2.log("sUSDS_CustomPriceFeed deployed at:", address(susdsAdapter));
    }

    function _deploySUsde() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "sUSDe");
        if (deployed != address(0)) {
            console2.log("sUSDe_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address sUsde = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "sUsde"));
        address usdeUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "usdeToUsdChainlinkAddress"));
        uint256 usdeUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "usdeToUsdChainlinkHeartbeat"));

        sUSDe_CustomPriceFeed susdeAdapter = new sUSDe_CustomPriceFeed(sUsde, usdeUsdOracle, usdeUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sUSDe", address(susdeAdapter));
        console2.log("sUSDe_CustomPriceFeed deployed at:", address(susdeAdapter));
    }

    function _deploySyrupUsdc() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "syrupUSDC");
        if (deployed != address(0)) {
            console2.log("syrupUSDC_CustomPriceFeed already deployed at:", deployed);
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

        syrupUSDC_CustomPriceFeed syrupUsdcAdapter =
            new syrupUSDC_CustomPriceFeed(syrupUsdc, usdcUsdOracle, usdcUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "syrupUSDC", address(syrupUsdcAdapter));
        console2.log("syrupUSDC_CustomPriceFeed deployed at:", address(syrupUsdcAdapter));
    }

    function _deployRwiv() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "RWIV");
        if (deployed != address(0)) {
            console2.log("RWIV_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address rwiv = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "RWIV", "rwiv"));
        address usdcUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "RWIV", "usdcToUsdChainlinkAddress"));
        uint256 usdcUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "RWIV", "usdcToUsdChainlinkHeartbeat"));

        RWIV_CustomPriceFeed rwivAdapter = new RWIV_CustomPriceFeed(rwiv, usdcUsdOracle, usdcUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "RWIV", address(rwivAdapter));
        console2.log("RWIV_CustomPriceFeed deployed at:", address(rwivAdapter));
    }

    function _deployEthx() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ETHx");
        if (deployed != address(0)) {
            console2.log("ETHx_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address ethx = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHx", "ethx"));
        address stakePoolsManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHx", "stakePoolsManager"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHx", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHx", "ethToUsdChainlinkHeartbeat"));

        ETHx_CustomPriceFeed ethxAdapter =
            new ETHx_CustomPriceFeed(ethx, stakePoolsManager, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ETHx", address(ethxAdapter));
        console2.log("ETHx_CustomPriceFeed deployed at:", address(ethxAdapter));
    }

    function _deployWstEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "wstETH");
        if (deployed != address(0)) {
            console2.log("wstETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "wstEth"));
        address stEthToEthOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "stEthToEthChainlinkOracle"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "ethToUsdChainlinkOracle"));
        uint256 stEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "stEthToEthChainlinkHeartbeat"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "ethToUsdChainlinkHeartbeat"));

        wstETH_CustomPriceFeed wstEthAdapter =
            new wstETH_CustomPriceFeed(wstEth, stEthToEthOracle, ethUsdOracle, stEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "wstETH", address(wstEthAdapter));
        console2.log("wstETH_CustomPriceFeed deployed at:", address(wstEthAdapter));
    }

    function _deployStEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "stETH");
        if (deployed != address(0)) {
            console2.log("stETH CrossRate_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // CrossRate: Y/USD = (X/USD) * (Y/X). For stETH: Y = stETH, X = ETH.
        address stEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "stETH", "underlyingAsset"));
        address ethUsdFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "stETH", "xToUsdFeed"));
        address stEthEthFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "stETH", "yToXFeed"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "stETH", "xToUsdHeartbeat"));
        uint256 stEthEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "stETH", "yToXHeartbeat"));

        CrossRate_CustomPriceFeed stEthAdapter =
            new CrossRate_CustomPriceFeed(stEth, ethUsdFeed, stEthEthFeed, ethUsdHeartbeat, stEthEthHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "stETH", address(stEthAdapter));
        console2.log("stETH CrossRate_CustomPriceFeed deployed at:", address(stEthAdapter));
    }

    function _deployLsEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "lsETH");
        if (deployed != address(0)) {
            console2.log("lsETH CrossRate_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // CrossRate: Y/USD = (X/USD) * (Y/X). For lsETH: Y = lsETH, X = ETH.
        address lsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "underlyingAsset"));
        address ethUsdFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "xToUsdFeed"));
        address lsEthEthFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "yToXFeed"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "xToUsdHeartbeat"));
        uint256 lsEthEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "yToXHeartbeat"));

        CrossRate_CustomPriceFeed lsEthAdapter =
            new CrossRate_CustomPriceFeed(lsEth, ethUsdFeed, lsEthEthFeed, ethUsdHeartbeat, lsEthEthHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "lsETH", address(lsEthAdapter));
        console2.log("lsETH CrossRate_CustomPriceFeed deployed at:", address(lsEthAdapter));
    }

    function _deployREth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rETH");
        if (deployed != address(0)) {
            console2.log("rETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address rEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "rEth"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "ethToUsdChainlinkHeartbeat"));

        rETH_CustomPriceFeed rEthAdapter = new rETH_CustomPriceFeed(rEth, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rETH", address(rEthAdapter));
        console2.log("rETH_CustomPriceFeed deployed at:", address(rEthAdapter));
    }

    /// @notice Deploys the generic osToken price feed (osETH, osGNO) for the given adapter name.
    function _deployOsToken(string memory name) internal {
        address deployed = _readAdapterDeployed("priceFeeds", name);
        if (deployed != address(0)) {
            console2.log("osToken_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address osToken = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "osToken"));
        address osTokenVaultController =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "osTokenVaultController"));
        address underlyingUsdOracle = vm.parseAddress(
            ConfigReader.readPriceFeedParam(vm, currentChainId, name, "underlyingToUsdChainlinkOracle")
        );
        uint256 heartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, name, "underlyingToUsdChainlinkHeartbeat")
        );

        osToken_CustomPriceFeed adapter =
            new osToken_CustomPriceFeed(osToken, osTokenVaultController, underlyingUsdOracle, heartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", name, address(adapter));
        console2.log("osToken_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deployOeth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "OETH");
        if (deployed != address(0)) {
            console2.log("OETH CrossRate_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // CrossRate: Y/USD = (X/USD) * (Y/X). For OETH: Y = OETH, X = ETH.
        address oeth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "underlyingAsset"));
        address ethUsdFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "xToUsdFeed"));
        address oethEthFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "yToXFeed"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "xToUsdHeartbeat"));
        uint256 oethEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "yToXHeartbeat"));

        CrossRate_CustomPriceFeed oethAdapter =
            new CrossRate_CustomPriceFeed(oeth, ethUsdFeed, oethEthFeed, ethUsdHeartbeat, oethEthHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "OETH", address(oethAdapter));
        console2.log("OETH CrossRate_CustomPriceFeed deployed at:", address(oethAdapter));
    }

    function _deployAnkrEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ankrETH");
        if (deployed != address(0)) {
            console2.log("ankrETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address ankrEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ankrETH", "ankrEth"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ankrETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ankrETH", "ethToUsdChainlinkHeartbeat"));

        ankrETH_CustomPriceFeed ankrEthAdapter = new ankrETH_CustomPriceFeed(ankrEth, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ankrETH", address(ankrEthAdapter));
        console2.log("ankrETH_CustomPriceFeed deployed at:", address(ankrEthAdapter));
    }

    /// @notice Deploys the NXM_CustomPriceFeed for the given config name ("NXM" or "wNXM"). Both price the same RAMM
    ///         book value; the `token` constructor arg sets which token the feed reports as its underlying.
    function _deployNxm(string memory name) internal {
        address deployed = _readAdapterDeployed("priceFeeds", name);
        if (deployed != address(0)) {
            console2.log("NXM_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address token = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "token"));
        address ramm = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "ramm"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "ethToUsdChainlinkHeartbeat"));

        NXM_CustomPriceFeed nxmAdapter = new NXM_CustomPriceFeed(token, ramm, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", name, address(nxmAdapter));
        console2.log("NXM_CustomPriceFeed deployed at:", address(nxmAdapter));
    }

    function _deployCbEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "cbETH");
        if (deployed != address(0)) {
            console2.log("cbETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "cbEth"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "ethToUsdChainlinkHeartbeat"));

        cbETH_CustomPriceFeed cbEthAdapter = new cbETH_CustomPriceFeed(cbEth, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "cbETH", address(cbEthAdapter));
        console2.log("cbETH_CustomPriceFeed deployed at:", address(cbEthAdapter));
    }

    function _deployWeEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "weETH");
        if (deployed != address(0)) {
            console2.log("weETH_CustomPriceFeed already deployed at:", deployed);
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

        weETH_CustomPriceFeed weEthAdapter =
            new weETH_CustomPriceFeed(weEth, weEthToEthOracle, ethUsdOracle, weEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "weETH", address(weEthAdapter));
        console2.log("weETH_CustomPriceFeed deployed at:", address(weEthAdapter));
    }

    function _deployRsEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rsETH");
        if (deployed != address(0)) {
            console2.log("rsETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "rsEth"));
        address rateProvider =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "rateProvider"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "ethToUsdChainlinkHeartbeat"));

        rsETH_CustomPriceFeed rsEthAdapter =
            new rsETH_CustomPriceFeed(rsEth, rateProvider, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rsETH", address(rsEthAdapter));
        console2.log("rsETH_CustomPriceFeed deployed at:", address(rsEthAdapter));
    }

    function _deployEEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "eETH");
        if (deployed != address(0)) {
            console2.log("eETH_CustomPriceFeed already deployed at:", deployed);
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

        eETH_CustomPriceFeed eEthAdapter =
            new eETH_CustomPriceFeed(eEth, weEth, weEthToEthOracle, ethUsdOracle, weEthToEthHeartbeat, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "eETH", address(eEthAdapter));
        console2.log("eETH_CustomPriceFeed deployed at:", address(eEthAdapter));
    }

    function _deployEzEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ezETH");
        if (deployed != address(0)) {
            console2.log("ezETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "ezEth"));
        address restakeManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "restakeManager"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "ethToUsdChainlinkHeartbeat"));

        ezETH_CustomPriceFeed ezEthAdapter =
            new ezETH_CustomPriceFeed(ezEth, restakeManager, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ezETH", address(ezEthAdapter));
        console2.log("ezETH_CustomPriceFeed deployed at:", address(ezEthAdapter));
    }

    function _deployEthPlus() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ETHPlus");
        if (deployed != address(0)) {
            console2.log("ETHPlus_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address ethPlus = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHPlus", "ethPlus"));
        uint256 heartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHPlus", "reserveProtocolHeartbeat"));

        ETHPlus_CustomPriceFeed adapter = new ETHPlus_CustomPriceFeed(ethPlus, heartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ETHPlus", address(adapter));
        console2.log("ETHPlus_CustomPriceFeed deployed at:", address(adapter));
    }

    /// @notice Helper to read deployed adapter address
    function _readAdapterDeployed(string memory adapterType, string memory adapterName)
        internal
        view
        returns (address)
    {
        return ConfigReader.readDeployedAdapterAddress(vm, currentChainId, adapterType, adapterName);
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

        // Deploy wstETH_L2 Price Oracle (Gnosis uses Aave ratio provider feed, not Chainlink)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH_L2")) {
            _deployWstEthL2();
        }

        // Deploy osGNO (StakeWise V3) osToken price feed: convertToAssets(1e18) [osGNO/GNO] x GNO/USD.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "osGNO")) {
            _deployOsToken("osGNO");
        }

        vm.stopBroadcast();
    }

    function _deploySxdai() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "sXDAI");
        if (deployed != address(0)) {
            console2.log("sXDAI_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address sXdai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "sXdai"));
        address xDaiUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "xDaiToUsdChainlinkOracle"));
        uint256 xDaiUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "xDaiToUsdChainlinkHeartbeat"));

        sXDAI_CustomPriceFeed sxdaiAdapter = new sXDAI_CustomPriceFeed(sXdai, xDaiUsdOracle, xDaiUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sXDAI", address(sxdaiAdapter));
        console2.log("sXDAI_CustomPriceFeed deployed at:", address(sxdaiAdapter));
    }

    // Shared L2 deploy helpers — read constructor args from assets.json priceFeeds section.
    // The same adapter type is deployed on multiple chains (wstETH_L2 on Arbitrum, Base, Gnosis, etc.)
    // with different underlying token + feed addresses per chain; `currentChainId` selects the right row.
    function _deployWstEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "wstETH_L2");
        if (deployed != address(0)) {
            console2.log("wstETH_L2_CustomPriceFeed already deployed at:", deployed);
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

        wstETH_L2_CustomPriceFeed adapter = new wstETH_L2_CustomPriceFeed(
            wstEth, wstEthToEthChainlink, ethUsdOracle, wstEthToEthHeartbeat, ethUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "wstETH_L2", address(adapter));
        console2.log("wstETH_L2_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deployWeEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "weETH_L2");
        if (deployed != address(0)) {
            console2.log("weETH_L2_CustomPriceFeed already deployed at:", deployed);
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

        weETH_L2_CustomPriceFeed adapter = new weETH_L2_CustomPriceFeed(
            weEth, weEthToEethChainlink, ethUsdOracle, weEthToEethHeartbeat, ethUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "weETH_L2", address(adapter));
        console2.log("weETH_L2_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deployCbEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "cbETH_L2");
        if (deployed != address(0)) {
            console2.log("cbETH_L2_CustomPriceFeed already deployed at:", deployed);
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

        cbETH_L2_CustomPriceFeed adapter = new cbETH_L2_CustomPriceFeed(
            cbEth, cbEthToEthChainlink, ethUsdOracle, cbEthToEthHeartbeat, ethUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "cbETH_L2", address(adapter));
        console2.log("cbETH_L2_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deployRsEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rsETH_L2");
        if (deployed != address(0)) {
            console2.log("rsETH_L2_CustomPriceFeed already deployed at:", deployed);
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

        rsETH_L2_CustomPriceFeed adapter = new rsETH_L2_CustomPriceFeed(
            rsEth, rsEthToEthChainlink, ethUsdOracle, rsEthToEthHeartbeat, ethUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rsETH_L2", address(adapter));
        console2.log("rsETH_L2_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deployEzEthL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ezETH_L2");
        if (deployed != address(0)) {
            console2.log("ezETH_L2_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "ezEth"));
        address xRenzoDeposit =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "xRenzoDeposit"));
        address ethUsdOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "ethToUsdChainlinkHeartbeat"));

        ezETH_L2_CustomPriceFeed adapter =
            new ezETH_L2_CustomPriceFeed(ezEth, xRenzoDeposit, ethUsdOracle, ethUsdHeartbeat);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ezETH_L2", address(adapter));
        console2.log("ezETH_L2_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deploySyrupUsdcL2() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "syrupUSDC_L2");
        if (deployed != address(0)) {
            console2.log("syrupUSDC_L2_CustomPriceFeed already deployed at:", deployed);
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

        syrupUSDC_L2_CustomPriceFeed adapter = new syrupUSDC_L2_CustomPriceFeed(
            syrupUsdc, syrupUsdcToUsdcChainlink, usdcUsdOracle, syrupUsdcToUsdcHeartbeat, usdcUsdHeartbeat
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "syrupUSDC_L2", address(adapter));
        console2.log("syrupUSDC_L2_CustomPriceFeed deployed at:", address(adapter));
    }
}
