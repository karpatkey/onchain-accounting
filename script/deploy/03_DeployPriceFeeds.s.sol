// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

// Import price adapters
import {LDO_CustomPriceFeed} from "../../src/prices/protocols/LDO_CustomPriceFeed.sol";
import {sUSDS_CustomPriceFeed} from "../../src/prices/protocols/sUSDS_CustomPriceFeed.sol";
import {sUSDe_CustomPriceFeed} from "../../src/prices/protocols/sUSDe_CustomPriceFeed.sol";
import {syrupUSDC_CustomPriceFeed} from "../../src/prices/protocols/syrupUSDC_CustomPriceFeed.sol";
import {spUSDC_CustomPriceFeed} from "../../src/prices/protocols/spUSDC_CustomPriceFeed.sol";
import {spUSDT_CustomPriceFeed} from "../../src/prices/protocols/spUSDT_CustomPriceFeed.sol";
import {spETH_CustomPriceFeed} from "../../src/prices/protocols/spETH_CustomPriceFeed.sol";
import {sDAI_CustomPriceFeed} from "../../src/prices/protocols/sDAI_CustomPriceFeed.sol";
import {RWIV_CustomPriceFeed} from "../../src/prices/protocols/RWIV_CustomPriceFeed.sol";
import {sGHO_CustomPriceFeed} from "../../src/prices/protocols/sGHO_CustomPriceFeed.sol";
import {wstETH_CustomPriceFeed} from "../../src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {rETH_CustomPriceFeed} from "../../src/prices/protocols/rETH_CustomPriceFeed.sol";
import {osToken_CustomPriceFeed} from "../../src/prices/protocols/osToken_CustomPriceFeed.sol";
import {cbETH_CustomPriceFeed} from "../../src/prices/protocols/cbETH_CustomPriceFeed.sol";
import {weETH_CustomPriceFeed} from "../../src/prices/protocols/weETH_CustomPriceFeed.sol";
import {rsETH_CustomPriceFeed} from "../../src/prices/protocols/rsETH_CustomPriceFeed.sol";
import {eETH_CustomPriceFeed} from "../../src/prices/protocols/eETH_CustomPriceFeed.sol";
import {ezETH_CustomPriceFeed} from "../../src/prices/protocols/ezETH_CustomPriceFeed.sol";
import {ETHx_CustomPriceFeed} from "../../src/prices/protocols/ETHx_CustomPriceFeed.sol";
// sXDAI is the Gnosis savings-xDAI ERC4626 rate feed — a distinct contract from mainnet sDAI
import {sXDAI_CustomPriceFeed} from "../../src/prices/protocols/sXDAI_CustomPriceFeed.sol";

// L2 price adapters
import {wstETH_L2_CustomPriceFeed} from "../../src/prices/protocols/wstETH_L2_CustomPriceFeed.sol";
import {weETH_L2_CustomPriceFeed} from "../../src/prices/protocols/weETH_L2_CustomPriceFeed.sol";
import {cbETH_L2_CustomPriceFeed} from "../../src/prices/protocols/cbETH_L2_CustomPriceFeed.sol";
import {rsETH_L2_CustomPriceFeed} from "../../src/prices/protocols/rsETH_L2_CustomPriceFeed.sol";
import {ezETH_L2_CustomPriceFeed} from "../../src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";
import {syrupUSDC_L2_CustomPriceFeed} from "../../src/prices/protocols/syrupUSDC_L2_CustomPriceFeed.sol";

import {ETHPlus_CustomPriceFeed} from "../../src/prices/protocols/ETHPlus_CustomPriceFeed.sol";

import {lsETH_CustomPriceFeed} from "../../src/prices/protocols/lsETH_CustomPriceFeed.sol";
import {OETH_CustomPriceFeed} from "../../src/prices/protocols/OETH_CustomPriceFeed.sol";
import {ezETH_CrossRateCustomPriceFeed} from "../../src/prices/protocols/ezETH_CrossRateCustomPriceFeed.sol";
import {ETHx_CrossRateCustomPriceFeed} from "../../src/prices/protocols/ETHx_CrossRateCustomPriceFeed.sol";
import {osETH_CrossRateCustomPriceFeed} from "../../src/prices/protocols/osETH_CrossRateCustomPriceFeed.sol";
import {CrossRateCustomPriceFeed} from "../../src/prices/protocols/CrossRateCustomPriceFeed.sol";
import {InvertedChainlinkCustomPriceFeed} from "src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol";
import {ankrETH_CustomPriceFeed} from "../../src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {NXM_CustomPriceFeed} from "../../src/prices/protocols/NXM_CustomPriceFeed.sol";
import {RateFeedGuard} from "../utils/RateFeedGuard.sol";

/// @title DeployPriceFeeds
/// @notice Deploys custom price feed adapters for NAVCalculator
/// @dev Price feeds are NOT upgradeable — add new ones via addPriceFeed, remove old via removePriceFeed
contract DeployPriceFeeds is BaseDeployScript {
    /// @notice An inverted feed's config declares a non-zero `baseAsset`, which the constructor cannot honour.
    /// @dev {InvertedChainlinkCustomPriceFeed.BASE_ASSET} is a compile-time `constant address(0)` — a `USD / X`
    ///      pair reads no base price out of the NAV. The config key exists only so the feed stays inside
    ///      preflight's circularity and base-allowlist checks, which read it from config; nothing passes it to
    ///      the constructor. So a non-zero value would be SILENTLY IGNORED and the config would disagree with an
    ///      IMMUTABLE contract, with the first sign of it being `verify_step` 1.5 failing against an
    ///      already-broadcast address that can never be amended. Rejected at deploy time instead.
    error InvertedFeedBaseAssetMustBeZero(string feed, address declared);

    /// @notice An inverted feed's `baseAsset` is present but is not a 20-byte address.
    /// @dev Raised instead of letting `vm.parseAddress` revert with an opaque cheatcode message, which
    ///      would hide which feed and which key were at fault.
    error InvertedFeedBaseAssetMalformed(string feed, string declared);

    function run() public override {
        setUp();

        console2.log("\n=== Deploying Price Feeds ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("");

        // Gate the deploy on rate-feed PAIR IDENTITY before anything is constructed.
        //
        // This runs here, not only in CI, because the event it protects against is this script: a 39-instance
        // redeploy re-enters every hand-entered rate-feed address, and `OracleArgumentChecks.assertChainlinkOracle`
        // in the feed constructors only proves the address is *an* aggregator — never which pair. A wrong feed of
        // the right shape deploys clean and then under-reports silently and permanently, with no staleness or
        // irregular signal anywhere. Reverting here costs a re-run; not reverting costs a redeploy plus
        // re-registration on an immutable feed. See {RateFeedGuard} for why identity and band are both required.
        uint256 guarded = RateFeedGuard.checkAll(vm, currentChainId);
        console2.log("Rate-feed pair identity verified for instances:", guarded);

        // BEFORE THE BROADCAST, for the same reason the guard above runs here. This assertion used to sit
        // inside `_deployInvertedFeed`, i.e. inside `vm.startBroadcast()` — so a non-zero `baseAsset` on an
        // inverted feed reverted the script only after every earlier feed in the run had already been
        // broadcast, leaving a half-written `deployments/<id>.json` that the next run's skip-if-deployed
        // logic then papers over. A pre-deploy stop costs a config edit; the other costs a redeploy.
        _assertInvertedFeedsDeclareZeroBase();
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

        // Deploy spUSDC Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "spUSDC")) {
            _deploySpUsdc();
        }

        // Deploy spUSDT Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "spUSDT")) {
            _deploySpUsdt();
        }

        // Deploy spETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "spETH")) {
            _deploySpEth();
        }

        // Deploy sDAI Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sDAI")) {
            _deploySDai();
        }

        // Deploy RWIV Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "RWIV")) {
            _deployRwiv();
        }

        // Deploy sGHO Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "sGHO")) {
            _deploySgho();
        }

        // Deploy wstETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "wstETH")) {
            _deployWstEth();
        }

        // stETH PRIMARY, pure fundamental: stETH/ETH held at 1.0, so it is a unit-rate eETH_CustomPriceFeed.
        // Matches how wstETH (stEthPerToken x ETH/USD) and eETH (1.0 x ETH/USD) are priced; stETH was previously the
        // only ETH-LST whose primary was a MARKET feed, which made the same claim worth two different numbers.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "stETHFundamental")) {
            _deployEEth("stETHFundamental");
        }

        // stETH divergence MONITOR: the former market primary (stETH/USD = ETH/USD x stETH/ETH), demoted. Its config
        // block is unchanged, and its shape already matches what the generic CrossRate monitor deployer reads.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "stETHCrossRate")) {
            _deployCrossRateMonitor("stETHCrossRate");
        }

        // Deploy lsETH CrossRate Price Oracle (lsETH/USD = ETH/USD x lsETH/ETH)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "lsETH")) {
            _deployLsEth();
        }

        // Deploy rETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "rETH")) {
            _deployREth();
        }

        // INTENTIONALLY BUILT BUT NEVER DEPLOYED — not an oversight. Mainnet cbETH is not held, so there is no
        // "cbETH" key in custom-price-feeds/1.json and this gate is always false. The contract is retained as the
        // natural MONITOR feed if mainnet cbETH is ever held: it reads cbETH.exchangeRate() (fundamental), which is
        // independent of the Chainlink cbETH/ETH market feed that cbETH_L2 composes — exactly the independence a
        // divergence check needs. See the NatSpec on cbETH_CustomPriceFeed. Do not delete; do not wire up without a
        // held position.
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
            _deployEEth("eETH");
        }

        // Deploy ezETH Price Oracle
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ezETH")) {
            _deployEzEth();
        }

        // Deploy ETHx Price Oracle (Stader)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ETHx")) {
            _deployEthx();
        }

        // Deploy ETHPlus Price Oracle (Reserve Protocol RToken).
        // INTENTIONALLY BUILT BUT NEVER DEPLOYED — not an oversight. The "ETHPlus" entry in
        // custom-price-feeds/1.json is "enabled": false, so this gate is always false. ETH+ is priced instead by the
        // Chainlink "Calculated ETH+/USD" feed registered in nav-config; this 8-dec Custom feed is incompatible with
        // that 18-dec Chainlink feed (PriceFeedDecimalsMismatch on registration). The disabled config entry and its
        // $comment are the RECORD of why a custom feed did not work here, so both the entry and this contract are
        // retained rather than deleted.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ETHPlus")) {
            _deployEthPlus();
        }

        // Deploy osETH (StakeWise V3) osToken custom price feed on Mainnet (osGNO is deployed in the
        // Gnosis branch). osTokens are Custom-priced ERC20s (held balance via ERC20DefaultBalanceAdapter,
        // priced convertToAssets(1e18) * underlying/USD) rather than bespoke balance adapters.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "osETH")) {
            _deployOsToken("osETH");
        }

        // Deploy ezETH / ETHx / osETH cross-rate REDUNDANCY feeds (X/USD = ETH/USD x X/ETH; the X/ETH leg is a
        // Redstone Classic Push market feed, independent of each asset's primary on-chain-rate feed).
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ezETHCrossRate")) {
            _deployEzEthCrossRate();
        }
        // ezETH's SECOND monitor, and the only one with a MARKET methodology (finding #2). ezETHCrossRate above is
        // fundamental-vs-fundamental after its 2026-07-22 migration to RedStone's ezETH_FUNDAMENTAL feed, so it cannot
        // detect a market depeg; this one wraps the RedStone Classic Push ezETH/ETH MARKET feed. Both are registered:
        // divergenceBps is primary-vs-the-WORST monitor, so the market leg dominates rather than being diluted. Uses
        // the GENERIC helper since its config block matches that shape.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ezETHCrossRateMarket")) {
            _deployCrossRateMonitor("ezETHCrossRateMarket");
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ETHxCrossRate")) {
            _deployEthxCrossRate();
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "osETHCrossRate")) {
            _deployOsEthCrossRate();
        }
        // rETH cross-rate MONITOR (rETH/USD = ETH/USD x rETH/ETH market feed); independent of the fundamental primary.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "rETHCrossRate")) {
            _deployCrossRateMonitor("rETHCrossRate");
        }

        // Deploy OETH CrossRate Price Oracle (OETH/USD = ETH/USD x OETH/ETH)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "OETH")) {
            _deployOeth();
        }

        // Deploy ankrETH Price Oracle (ankrETH/USD = ETH/USD * 1e18 / ratio)
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ankrETH")) {
            _deployAnkrEth();
        }

        // Deploy wARS Price Oracle (wARS/USD = 1 / Chainlink "USD / ARS"). Gated ONLY on its own config
        // entry: nesting this inside another feed's `if` would make an enabled wARS silently not deploy
        // whenever that unrelated feed is disabled, and RegisterAssets would then skip wARS for want of a
        // resolved custom-feed address — a silent under-report, not a loud failure.
        if (ConfigReader.isPriceFeedEnabled(vm, currentChainId, "wARS")) {
            _deployInvertedFeed("wARS");
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

    function _deployLdo() internal {
        // Check if already deployed
        address deployed = _readAdapterDeployed("priceFeeds", "LDO");
        if (deployed != address(0)) {
            console2.log("LDO_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // Read constructor parameters from the custom-price-feeds deploy config
        address ldo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldo"));
        address ldoEthOracle =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldoToEthChainlinkAddress"));
        uint256 ldoEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "ldoToEthChainlinkHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "LDO", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        // Deploy
        LDO_CustomPriceFeed ldoAdapter = new LDO_CustomPriceFeed(ldo, ldoEthOracle, ldoEthHeartbeat, nav, baseAsset);
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

        // Read constructor parameters from the custom-price-feeds deploy config
        address sUsds = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "sUsds"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDS", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        // Deploy
        sUSDS_CustomPriceFeed susdsAdapter = new sUSDS_CustomPriceFeed(sUsds, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sUSDe", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        sUSDe_CustomPriceFeed susdeAdapter = new sUSDe_CustomPriceFeed(sUsde, nav, baseAsset);
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
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        syrupUSDC_CustomPriceFeed syrupUsdcAdapter = new syrupUSDC_CustomPriceFeed(syrupUsdc, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "syrupUSDC", address(syrupUsdcAdapter));
        console2.log("syrupUSDC_CustomPriceFeed deployed at:", address(syrupUsdcAdapter));
    }

    function _deploySpUsdc() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "spUSDC");
        if (deployed != address(0)) {
            console2.log("spUSDC_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address spUsdc = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "spUSDC", "spUsdc"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "spUSDC", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        spUSDC_CustomPriceFeed spUsdcAdapter = new spUSDC_CustomPriceFeed(spUsdc, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "spUSDC", address(spUsdcAdapter));
        console2.log("spUSDC_CustomPriceFeed deployed at:", address(spUsdcAdapter));
    }

    function _deploySpUsdt() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "spUSDT");
        if (deployed != address(0)) {
            console2.log("spUSDT_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address spUsdt = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "spUSDT", "spUsdt"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "spUSDT", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        spUSDT_CustomPriceFeed spUsdtAdapter = new spUSDT_CustomPriceFeed(spUsdt, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "spUSDT", address(spUsdtAdapter));
        console2.log("spUSDT_CustomPriceFeed deployed at:", address(spUsdtAdapter));
    }

    function _deploySpEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "spETH");
        if (deployed != address(0)) {
            console2.log("spETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address spEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "spETH", "spEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "spETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        spETH_CustomPriceFeed spEthAdapter = new spETH_CustomPriceFeed(spEth, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "spETH", address(spEthAdapter));
        console2.log("spETH_CustomPriceFeed deployed at:", address(spEthAdapter));
    }

    function _deploySDai() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "sDAI");
        if (deployed != address(0)) {
            console2.log("sDAI_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address sDai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "sDai"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sDAI", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        sDAI_CustomPriceFeed sDaiAdapter = new sDAI_CustomPriceFeed(sDai, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sDAI", address(sDaiAdapter));
        console2.log("sDAI_CustomPriceFeed deployed at:", address(sDaiAdapter));
    }

    function _deployRwiv() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "RWIV");
        if (deployed != address(0)) {
            console2.log("RWIV_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address rwiv = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "RWIV", "rwiv"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "RWIV", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        RWIV_CustomPriceFeed rwivAdapter = new RWIV_CustomPriceFeed(rwiv, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "RWIV", address(rwivAdapter));
        console2.log("RWIV_CustomPriceFeed deployed at:", address(rwivAdapter));
    }

    function _deploySgho() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "sGHO");
        if (deployed != address(0)) {
            console2.log("sGHO_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address sgho = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sGHO", "sgho"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sGHO", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        sGHO_CustomPriceFeed sghoAdapter = new sGHO_CustomPriceFeed(sgho, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sGHO", address(sghoAdapter));
        console2.log("sGHO_CustomPriceFeed deployed at:", address(sghoAdapter));
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHx", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        ETHx_CustomPriceFeed ethxAdapter = new ETHx_CustomPriceFeed(ethx, stakePoolsManager, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        wstETH_CustomPriceFeed wstEthAdapter = new wstETH_CustomPriceFeed(wstEth, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "wstETH", address(wstEthAdapter));
        console2.log("wstETH_CustomPriceFeed deployed at:", address(wstEthAdapter));
    }

    function _deployLsEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "lsETH");
        if (deployed != address(0)) {
            console2.log("lsETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // CrossRate: Y/USD = (X/USD) * (Y/X). For lsETH: Y = lsETH, X = ETH.
        address lsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "underlyingAsset"));
        address lsEthEthFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "yToXFeed"));
        uint256 lsEthEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "yToXHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "lsETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        lsETH_CustomPriceFeed lsEthAdapter =
            new lsETH_CustomPriceFeed(lsEth, lsEthEthFeed, lsEthEthHeartbeat, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "lsETH", address(lsEthAdapter));
        console2.log("lsETH_CustomPriceFeed deployed at:", address(lsEthAdapter));
    }

    function _deployREth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "rETH");
        if (deployed != address(0)) {
            console2.log("rETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address rEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "rEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        rETH_CustomPriceFeed rEthAdapter = new rETH_CustomPriceFeed(rEth, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        osToken_CustomPriceFeed adapter = new osToken_CustomPriceFeed(osToken, osTokenVaultController, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", name, address(adapter));
        console2.log("osToken_CustomPriceFeed deployed at:", address(adapter));
    }

    function _deployOeth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "OETH");
        if (deployed != address(0)) {
            console2.log("OETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        // CrossRate: Y/USD = (X/USD) * (Y/X). For OETH: Y = OETH, X = ETH.
        address oeth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "underlyingAsset"));
        address oethEthFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "yToXFeed"));
        uint256 oethEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "yToXHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "OETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        OETH_CustomPriceFeed oethAdapter = new OETH_CustomPriceFeed(oeth, oethEthFeed, oethEthHeartbeat, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "OETH", address(oethAdapter));
        console2.log("OETH_CustomPriceFeed deployed at:", address(oethAdapter));
    }

    function _deployAnkrEth() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ankrETH");
        if (deployed != address(0)) {
            console2.log("ankrETH_CustomPriceFeed already deployed at:", deployed);
            return;
        }

        address ankrEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ankrETH", "ankrEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ankrETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        ankrETH_CustomPriceFeed ankrEthAdapter = new ankrETH_CustomPriceFeed(ankrEth, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        NXM_CustomPriceFeed nxmAdapter = new NXM_CustomPriceFeed(token, ramm, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        cbETH_CustomPriceFeed cbEthAdapter = new cbETH_CustomPriceFeed(cbEth, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        weETH_CustomPriceFeed weEthAdapter = new weETH_CustomPriceFeed(weEth, nav, baseAsset);
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        rsETH_CustomPriceFeed rsEthAdapter = new rsETH_CustomPriceFeed(rsEth, rateProvider, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "rsETH", address(rsEthAdapter));
        console2.log("rsETH_CustomPriceFeed deployed at:", address(rsEthAdapter));
    }

    /// @notice Deploys a UNIT-RATE `eETH_CustomPriceFeed` (`_rate()` is a constant 1e18, so the price is
    ///         `1.0 x base/USD`) for the given config key. Parameterised by key because two assets use this shape:
    ///         `eETH` itself, and `stETHFundamental` — stETH's primary, where stETH/ETH is held at 1.0 (Lido's
    ///         redemption invariant), matching how wstETH and eETH are priced. The contract name on the explorer
    ///         therefore reads `eETH` for both; that is deliberate, and it reuses already-reviewed bytecode rather
    ///         than adding a near-identical leaf to the audit surface.
    /// @dev ALL THREE key-dependent roles are parameterised, matching {_deployNxm} / {_deployOsToken}: the
    ///      idempotency probe, the config reads, and the deployment-record write. Parameterising only the reads
    ///      would write the second instance under the first one's key — silently repointing `eETH`'s own feed at a
    ///      stETH-bound contract — and the probe would then skip the deploy entirely once `eETH` exists.
    /// @param name The `custom-price-feeds/<chainId>.json` key (`"eETH"` or `"stETHFundamental"`).
    function _deployEEth(string memory name) internal {
        address deployed = _readAdapterDeployed("priceFeeds", name);
        if (deployed != address(0)) {
            console2.log("eETH_CustomPriceFeed already deployed:", name, deployed);
            return;
        }

        address eEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "eEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        eETH_CustomPriceFeed eEthAdapter = new eETH_CustomPriceFeed(eEth, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", name, address(eEthAdapter));
        console2.log("eETH_CustomPriceFeed deployed:", name, address(eEthAdapter));
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        ezETH_CustomPriceFeed ezEthAdapter = new ezETH_CustomPriceFeed(ezEth, restakeManager, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ezETH", address(ezEthAdapter));
        console2.log("ezETH_CustomPriceFeed deployed at:", address(ezEthAdapter));
    }

    // NOTE: this section header describes `_deployCrossRateMonitor`, further below — the two
    // inverted-feed helpers between here and it are a different family.
    // CrossRate redundancy feeds: Y/USD = (X/USD) * (Y/X), X = ETH. The Y/ETH leg is a Redstone market feed,
    // independent of the asset's primary on-chain-rate feed. Registered as a `monitorFeed`, NOT as a pricing feed:
    // it never prices the NAV, it only provides something for the primary to be checked against. An earlier
    // version of this line said "Registered as priceFeeds[1] (freshest-wins)", which described behaviour PR #151
    // removed — and it sat five lines above the docstring below that already says the opposite. A comment
    // asserting the reverse of the behaviour, in the place someone goes to check the behaviour, is worse than none.

    /// @notice Pre-broadcast: every enabled inverted feed must declare `baseAsset` absent or `address(0)`.
    /// @dev Keyed on the `usdToAssetChainlinkAddress` param, which is what makes an entry an inverted feed —
    ///      not on a hardcoded name, so a second `USD / X` feed is covered the day it is configured.
    ///      See {InvertedFeedBaseAssetMustBeZero} for why a non-zero value cannot be honoured.
    function _assertInvertedFeedsDeclareZeroBase() internal view {
        // ONE assertion, and deliberately only one. `baseAsset` is the single key an inverted feed can
        // declare that the CONSTRUCTOR CANNOT HONOUR — {InvertedChainlinkCustomPriceFeed.BASE_ASSET} is a
        // compile-time `constant address(0)` — so a non-zero value is silently ignored and leaves config
        // disagreeing with an immutable contract. That is specific to this family and worth a pre-broadcast
        // stop.
        //
        // PRESENCE AND PARSEABILITY OF THE OTHER PARAMS ARE DELIBERATELY *NOT* CHECKED HERE. Two commits
        // running added such checks in response to review, and both were incomplete in a new way: a digit
        // loop that red-gated hex values `vm.parseUint` accepts, address params still unvalidated, then the
        // constructor's own band invariant. The reason it kept growing is that the underlying property is
        // NOT specific to this feed: EVERY `_deploy*` helper in this script reads and parses its config
        // inside `vm.startBroadcast()`, so a malformed value anywhere aborts mid-run with earlier feeds
        // already deployed. Pre-validating one family creates the impression the rest are covered while
        // chasing an unbounded list of per-key shape rules. **DECLARED, script-wide:** config is parsed
        // in-broadcast; `preflight_config` is where config shape is gated before a run starts.
        string[] memory names = ConfigReader.getEnabledAdapters(vm, currentChainId, "deployPriceFeeds");
        for (uint256 i; i < names.length; ++i) {
            if (!ConfigReader.isPriceFeedEnabled(vm, currentChainId, names[i])) continue;
            string memory rate =
                ConfigReader.readPriceFeedParam(vm, currentChainId, names[i], "usdToAssetChainlinkAddress");
            if (bytes(rate).length == 0) continue;

            // An ABSENT key is not this gate's business: `preflight_config.base_allowlist_findings` already
            // ERRORs on a custom feed that declares no `baseAsset` at all, and stating the opposite here
            // would leave the two gates asserting contradictory contracts for the same key. This one only
            // rules on a value that IS present.
            string memory declaredBase = ConfigReader.readPriceFeedParam(vm, currentChainId, names[i], "baseAsset");
            if (bytes(declaredBase).length == 0) continue;
            // Shape-check BEFORE `vm.parseAddress`, which reverts with an opaque cheatcode error and would
            // bury the named error this function exists to raise.
            if (bytes(declaredBase).length != 42) revert InvertedFeedBaseAssetMalformed(names[i], declaredBase);
            if (vm.parseAddress(declaredBase) != address(0)) {
                revert InvertedFeedBaseAssetMustBeZero(names[i], vm.parseAddress(declaredBase));
            }
        }
    }

    /// @notice Deploys a generic {InvertedChainlinkCustomPriceFeed} from config, by feed key.
    /// @dev For assets whose ONLY Chainlink coverage is quoted `USD / X` (X per USD) — the reciprocal of the
    ///      asset/USD direction {Prices} registers. The constructor param is named `*ChainlinkAddress` so
    ///      {RateFeedGuard} recognises it as a rate feed and REQUIRES a `rateFeedGuard` block, which pins both
    ///      the pair and the direction; without that naming the guard would silently skip this feed.
    function _deployInvertedFeed(string memory name) internal {
        address deployed = _readAdapterDeployed("priceFeeds", name);
        if (deployed != address(0)) {
            console2.log("InvertedChainlink feed already deployed:", name, deployed);
            return;
        }
        address underlying =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "underlyingAsset"));
        address usdToAssetFeed =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "usdToAssetChainlinkAddress"));
        uint256 heartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "usdToAssetChainlinkHeartbeat"));

        uint256 minAnswer = vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "minAnswer"));
        uint256 maxAnswer = vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "maxAnswer"));

        InvertedChainlinkCustomPriceFeed adapter =
            new InvertedChainlinkCustomPriceFeed(underlying, usdToAssetFeed, heartbeat, minAnswer, maxAnswer);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", name, address(adapter));
        console2.log("InvertedChainlinkCustomPriceFeed deployed:", name, address(adapter));
    }

    /// @notice Deploys a generic CrossRate divergence-MONITOR feed (Y/USD = (Y/ETH market) x (ETH/USD)) from its
    ///         config entry `{underlyingAsset, yToXFeed, yToXHeartbeat, baseAsset}`. Used for LSTs whose fundamental
    ///         primary has no direct USD market feed to diverge from — the yToXFeed is an INDEPENDENT market Y/ETH
    ///         feed. Wired as a Custom monitorFeed; never prices the NAV.
    function _deployCrossRateMonitor(string memory name) internal {
        address deployed = _readAdapterDeployed("priceFeeds", name);
        if (deployed != address(0)) {
            console2.log("CrossRate monitor already deployed:", name, deployed);
            return;
        }
        address underlying =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "underlyingAsset"));
        address yToXFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "yToXFeed"));
        uint256 yToXHeartbeat = vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "yToXHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, name, "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        CrossRateCustomPriceFeed adapter =
            new CrossRateCustomPriceFeed(underlying, yToXFeed, yToXHeartbeat, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", name, address(adapter));
        console2.log("CrossRateCustomPriceFeed deployed:", name, address(adapter));
    }

    function _deployEzEthCrossRate() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ezETHCrossRate");
        if (deployed != address(0)) {
            console2.log("ezETH_CrossRateCustomPriceFeed already deployed at:", deployed);
            return;
        }
        address ezEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETHCrossRate", "underlyingAsset"));
        address ezEthEthFeed =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETHCrossRate", "yToXFeed"));
        uint256 ezEthEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETHCrossRate", "yToXHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETHCrossRate", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        ezETH_CrossRateCustomPriceFeed adapter =
            new ezETH_CrossRateCustomPriceFeed(ezEth, ezEthEthFeed, ezEthEthHeartbeat, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ezETHCrossRate", address(adapter));
        console2.log("ezETH_CrossRateCustomPriceFeed deployed at:", address(adapter));
    }

    function _deployEthxCrossRate() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "ETHxCrossRate");
        if (deployed != address(0)) {
            console2.log("ETHx_CrossRateCustomPriceFeed already deployed at:", deployed);
            return;
        }
        address ethx =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHxCrossRate", "underlyingAsset"));
        address ethxEthFeed =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHxCrossRate", "yToXFeed"));
        uint256 ethxEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHxCrossRate", "yToXHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ETHxCrossRate", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        ETHx_CrossRateCustomPriceFeed adapter =
            new ETHx_CrossRateCustomPriceFeed(ethx, ethxEthFeed, ethxEthHeartbeat, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "ETHxCrossRate", address(adapter));
        console2.log("ETHx_CrossRateCustomPriceFeed deployed at:", address(adapter));
    }

    function _deployOsEthCrossRate() internal {
        address deployed = _readAdapterDeployed("priceFeeds", "osETHCrossRate");
        if (deployed != address(0)) {
            console2.log("osETH_CrossRateCustomPriceFeed already deployed at:", deployed);
            return;
        }
        address osEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "osETHCrossRate", "underlyingAsset"));
        address osEthEthFeed =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "osETHCrossRate", "yToXFeed"));
        uint256 osEthEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "osETHCrossRate", "yToXHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "osETHCrossRate", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        osETH_CrossRateCustomPriceFeed adapter =
            new osETH_CrossRateCustomPriceFeed(osEth, osEthEthFeed, osEthEthHeartbeat, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "osETHCrossRate", address(adapter));
        console2.log("osETH_CrossRateCustomPriceFeed deployed at:", address(adapter));
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
        // CrossRate MONITORS (X/USD = ETH/USD x X/ETH market feed): independent of each L2 asset's fundamental primary.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "weETHCrossRate")) {
            _deployCrossRateMonitor("weETHCrossRate");
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "ezETHCrossRate")) {
            _deployCrossRateMonitor("ezETHCrossRate");
        }
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "rsETHCrossRate")) {
            _deployCrossRateMonitor("rsETHCrossRate");
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
        // weETH cross-rate MONITOR (weETH/USD = ETH/USD x weETH/ETH market feed); independent of the fundamental primary.
        if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "weETHCrossRate")) {
            _deployCrossRateMonitor("weETHCrossRate");
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "sXDAI", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        sXDAI_CustomPriceFeed sxdaiAdapter = new sXDAI_CustomPriceFeed(sXdai, nav, baseAsset);
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "sXDAI", address(sxdaiAdapter));
        console2.log("sXDAI_CustomPriceFeed deployed at:", address(sxdaiAdapter));
    }

    // Shared L2 deploy helpers — read constructor args from the custom-price-feeds deploy config
    // (contracts-deployment-config/custom-price-feeds/<chainId>.json) via ConfigReader.readPriceFeedParam.
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
        uint256 wstEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "wstEthToEthHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "wstETH_L2", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        wstETH_L2_CustomPriceFeed adapter =
            new wstETH_L2_CustomPriceFeed(wstEth, wstEthToEthChainlink, wstEthToEthHeartbeat, nav, baseAsset);
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
        uint256 weEthToEethHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "weEthToEethHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "weETH_L2", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        weETH_L2_CustomPriceFeed adapter =
            new weETH_L2_CustomPriceFeed(weEth, weEthToEethChainlink, weEthToEethHeartbeat, nav, baseAsset);
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
        uint256 cbEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "cbEthToEthHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "cbETH_L2", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        cbETH_L2_CustomPriceFeed adapter =
            new cbETH_L2_CustomPriceFeed(cbEth, cbEthToEthChainlink, cbEthToEthHeartbeat, nav, baseAsset);
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
        uint256 rsEthToEthHeartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "rsEthToEthHeartbeat"));
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "rsETH_L2", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        rsETH_L2_CustomPriceFeed adapter =
            new rsETH_L2_CustomPriceFeed(rsEth, rsEthToEthChainlink, rsEthToEthHeartbeat, nav, baseAsset);
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
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "ezETH_L2", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        ezETH_L2_CustomPriceFeed adapter = new ezETH_L2_CustomPriceFeed(ezEth, xRenzoDeposit, nav, baseAsset);
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
        uint256 syrupUsdcToUsdcHeartbeat = vm.parseUint(
            ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "syrupUsdcToUsdcHeartbeat")
        );
        address baseAsset =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, currentChainId, "syrupUSDC_L2", "baseAsset"));
        address nav = ConfigReader.readDeployedAddress(vm, currentChainId, "NAVCalculatorProxy");

        syrupUSDC_L2_CustomPriceFeed adapter = new syrupUSDC_L2_CustomPriceFeed(
            syrupUsdc, syrupUsdcToUsdcChainlink, syrupUsdcToUsdcHeartbeat, nav, baseAsset
        );
        ConfigReader.writeAdapterAddress(vm, currentChainId, "priceFeeds", "syrupUSDC_L2", address(adapter));
        console2.log("syrupUSDC_L2_CustomPriceFeed deployed at:", address(adapter));
    }
}
