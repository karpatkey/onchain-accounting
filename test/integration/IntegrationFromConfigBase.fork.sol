// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console2} from "forge-std/console2.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

// Balance adapters
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {SparkLendBalanceOracle} from "src/balances/protocols/SparkLend.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {MorphoVaultBalanceOracle} from "src/balances/protocols/MorphoVault.sol";
import {GearboxMarketBalanceOracle} from "src/balances/protocols/GearboxMarket.sol";
import {CapBalanceOracle} from "src/balances/protocols/Cap.sol";
import {CurveBalanceOracle} from "src/balances/protocols/Curve.sol";
import {ConvexBalanceOracle} from "src/balances/protocols/Convex.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {Aura} from "src/balances/protocols/Aura.sol";

// Price feed adapters (Mainnet)
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {LDO_PriceOracle} from "src/prices/protocols/LDO_Price.sol";
import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";
import {sUSDe_PriceOracle} from "src/prices/protocols/sUSDe_Price.sol";
import {syrupUSDC_PriceOracle} from "src/prices/protocols/syrupUSDC_Price.sol";
import {wstETH_PriceOracle} from "src/prices/protocols/wstETH_Price.sol";
import {rETH_PriceOracle} from "src/prices/protocols/rETH_Price.sol";
import {cbETH_PriceOracle} from "src/prices/protocols/cbETH_Price.sol";
import {weETH_PriceOracle} from "src/prices/protocols/weETH_Price.sol";
import {rsETH_PriceOracle} from "src/prices/protocols/rsETH_Price.sol";
import {eETH_PriceOracle} from "src/prices/protocols/eETH_Price.sol";
import {ezETH_PriceOracle} from "src/prices/protocols/ezETH_Price.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

// Price feed adapters (L2)
import {wstETH_L2_PriceOracle} from "src/prices/protocols/wstETH_L2_Price.sol";
import {weETH_L2_PriceOracle} from "src/prices/protocols/weETH_L2_Price.sol";
import {cbETH_L2_PriceOracle} from "src/prices/protocols/cbETH_L2_Price.sol";
import {rsETH_L2_PriceOracle} from "src/prices/protocols/rsETH_L2_Price.sol";
import {ezETH_L2_PriceOracle} from "src/prices/protocols/ezETH_L2_Price.sol";
import {syrupUSDC_L2_PriceOracle} from "src/prices/protocols/syrupUSDC_L2_Price.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title IntegrationFromConfigBase
/// @notice Per-chain integration test harness that mirrors the deploy pipeline:
///         deploys NAVCalculator + every enabled price feed adapter (assets.json) + every enabled
///         balance adapter (chains/<id>.json), registers all assets and balance oracles, then reads
///         NAV for the configured accounts. Equivalent to running 02_2 + 03 + 04 + 06_2 + RegisterAssets
///         end-to-end inside a forked-mainnet test.
/// @dev Deployment dispatch is duplicated from script/deploy/{03,04}*.sol so the test can avoid the
///      chain-config writes those scripts perform via ConfigReader.writeAdapterAddress.
abstract contract IntegrationFromConfigBase is TestEnvConfigurator {
    // Set by child setUp before _setupAndDeploy().
    uint256 internal _chainId;
    uint256 internal _forkBlock;
    string internal _forkNetwork; // e.g. "eth-mainnet"

    NAVCalculator public nav;
    address public admin = makeAddr("integration-admin");

    uint256 public fork;

    /// @notice quoteAsset = address(0) ⇒ NAV value is denominated in USD with 8 decimals.
    address internal constant QUOTE_USD = address(0);

    /// @notice Tracked deployed adapter addresses (for diagnostics + addBalanceOracle pass).
    address[] internal _deployedBalanceAdapters;

    function _setupAndDeploy() internal {
        require(_chainId != 0, "child must set _chainId");
        require(bytes(_forkNetwork).length > 0, "child must set _forkNetwork");

        fork = createSelectForkWithCadence(getAlchemyUrl(_forkNetwork), _forkBlock);

        address sequencerFeed = _sequencerFeed(_chainId);
        string memory nativeSymbol = _nativeSymbol(_chainId);

        vm.startPrank(admin);
        nav = NAVCalculator(
            Upgrades.deployUUPSProxy(
                "NAVCalculator.sol",
                abi.encodeCall(NAVCalculator.initialize, (admin, sequencerFeed, nativeSymbol)),
                _unsafeDeployOpts()
            )
        );
        nav.grantRole(MANAGER, admin);

        _deployAllPriceFeeds();
        _deployAllBalanceAdapters();
        _registerAllAssets();
        _registerAllBalanceAdapters();
        vm.stopPrank();
    }

    function _unsafeDeployOpts() internal pure returns (UUPSDeployOptions memory opts) {
        opts.unsafeSkipAllChecks = true;
    }

    // -----------------------------------------------------------------------
    // Per-chain configuration helpers
    // -----------------------------------------------------------------------

    function _sequencerFeed(uint256 chainId) internal pure returns (address) {
        if (chainId == 10) return 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389; // Optimism
        if (chainId == 42161) return 0xFdB631F5EE196F0ed6FAa767959853A9F217697D; // Arbitrum
        if (chainId == 8453) return 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // Base
        return address(0); // Mainnet, Gnosis (L1 / no sequencer feed)
    }

    function _nativeSymbol(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 100) return "xDAI";
        return "ETH";
    }

    // -----------------------------------------------------------------------
    // Price feed deployment
    // -----------------------------------------------------------------------

    function _deployAllPriceFeeds() internal {
        if (_chainId == 1) {
            _tryDeployPriceFeed("sDAI", _deploySdai);
            _tryDeployPriceFeed("LDO", _deployLdo);
            _tryDeployPriceFeed("sUSDS", _deploySusds);
            _tryDeployPriceFeed("sUSDe", _deploySUsde);
            _tryDeployPriceFeed("syrupUSDC", _deploySyrupUsdc);
            _tryDeployPriceFeed("wstETH", _deployWstEth);
            _tryDeployPriceFeed("rETH", _deployREth);
            _tryDeployPriceFeed("cbETH", _deployCbEth);
            _tryDeployPriceFeed("weETH", _deployWeEth);
            _tryDeployPriceFeed("rsETH", _deployRsEth);
            _tryDeployPriceFeed("eETH", _deployEEth);
            _tryDeployPriceFeed("ezETH", _deployEzEth);
        } else if (_chainId == 42161) {
            _tryDeployPriceFeed("wstETH_L2", _deployWstEthL2);
            _tryDeployPriceFeed("weETH_L2", _deployWeEthL2);
            _tryDeployPriceFeed("rsETH_L2", _deployRsEthL2);
            _tryDeployPriceFeed("ezETH_L2", _deployEzEthL2);
            _tryDeployPriceFeed("syrupUSDC_L2", _deploySyrupUsdcL2);
        } else if (_chainId == 8453) {
            _tryDeployPriceFeed("wstETH_L2", _deployWstEthL2);
            _tryDeployPriceFeed("weETH_L2", _deployWeEthL2);
            _tryDeployPriceFeed("cbETH_L2", _deployCbEthL2);
        } else if (_chainId == 100) {
            _tryDeployPriceFeed("sXDAI", _deploySxdai);
            _tryDeployPriceFeed("wstETH_L2", _deployWstEthL2);
        }
        // Optimism: no Custom adapters.
    }

    function _tryDeployPriceFeed(string memory name, function() returns (address) deployer) internal {
        if (!ConfigReader.isAdapterEnabled(vm, _chainId, "priceFeeds", name)) {
            return;
        }
        address addr = deployer();
        console2.log("[priceFeed]", name, addr);
    }

    function _deploySdai() internal returns (address) {
        address sDai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sDAI", "sDai"));
        address dsrManager = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sDAI", "dsrManager"));
        address daiUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sDAI", "daiToUsdChainlinkOracle"));
        uint256 daiUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "sDAI", "daiToUsdChainlinkHeartbeat"));
        return address(new sDAI_PriceOracle(sDai, dsrManager, daiUsd, daiUsdHb));
    }

    function _deployLdo() internal returns (address) {
        address ldo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ldo"));
        address ldoEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ldoToEthChainlinkAddress"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ethToUsdChainlinkAddress"));
        uint256 ldoEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ldoToEthChainlinkHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ethToUsdChainlinkHeartbeat"));
        return address(new LDO_PriceOracle(ldo, ldoEth, ethUsd, ldoEthHb, ethUsdHb));
    }

    function _deploySusds() internal returns (address) {
        address sUsds = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDS", "sUsds"));
        address usdsUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDS", "usdsToUsdChainlinkAddress"));
        uint256 usdsUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDS", "usdsToUsdChainlinkHeartbeat"));
        return address(new sUSDS_PriceOracle(sUsds, usdsUsd, usdsUsdHb));
    }

    function _deploySUsde() internal returns (address) {
        address sUsde = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDe", "sUsde"));
        address usdeUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDe", "usdeToUsdChainlinkAddress"));
        uint256 usdeUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDe", "usdeToUsdChainlinkHeartbeat"));
        return address(new sUSDe_PriceOracle(sUsde, usdeUsd, usdeUsdHb));
    }

    function _deploySyrupUsdc() internal returns (address) {
        address syrup = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC", "syrupUsdc"));
        address usdcUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC", "usdcToUsdChainlinkAddress"));
        uint256 usdcUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC", "usdcToUsdChainlinkHeartbeat"));
        return address(new syrupUSDC_PriceOracle(syrup, usdcUsd, usdcUsdHb));
    }

    function _deployWstEth() internal returns (address) {
        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "wstEth"));
        address stEthToEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "stEthToEthChainlinkOracle"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "ethToUsdChainlinkOracle"));
        uint256 stEthToEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "stEthToEthChainlinkHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "ethToUsdChainlinkHeartbeat"));
        return address(new wstETH_PriceOracle(wstEth, stEthToEth, ethUsd, stEthToEthHb, ethUsdHb));
    }

    function _deployREth() internal returns (address) {
        address rEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "rEth"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "ethToUsdChainlinkHeartbeat"));
        return address(new rETH_PriceOracle(rEth, ethUsd, ethUsdHb));
    }

    function _deployCbEth() internal returns (address) {
        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH", "cbEth"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH", "ethToUsdChainlinkHeartbeat"));
        return address(new cbETH_PriceOracle(cbEth, ethUsd, ethUsdHb));
    }

    function _deployWeEth() internal returns (address) {
        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "weEth"));
        address weEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "weEthToEthChainlinkOracle"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "ethToUsdChainlinkOracle"));
        uint256 weEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "weEthToEthChainlinkHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "ethToUsdChainlinkHeartbeat"));
        return address(new weETH_PriceOracle(weEth, weEthEth, ethUsd, weEthEthHb, ethUsdHb));
    }

    function _deployRsEth() internal returns (address) {
        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "rsEth"));
        address rateProvider = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "rateProvider"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "ethToUsdChainlinkHeartbeat"));
        return address(new rsETH_PriceOracle(rsEth, rateProvider, ethUsd, ethUsdHb));
    }

    function _deployEEth() internal returns (address) {
        address eEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "eETH", "eEth"));
        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "eETH", "weEth"));
        address weEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "eETH", "weEthToEthChainlinkOracle"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "eETH", "ethToUsdChainlinkOracle"));
        uint256 weEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "eETH", "weEthToEthChainlinkHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "eETH", "ethToUsdChainlinkHeartbeat"));
        return address(new eETH_PriceOracle(eEth, weEth, weEthEth, ethUsd, weEthEthHb, ethUsdHb));
    }

    function _deployEzEth() internal returns (address) {
        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "ezEth"));
        address restakeManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "restakeManager"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "ethToUsdChainlinkHeartbeat"));
        return address(new ezETH_PriceOracle(ezEth, restakeManager, ethUsd, ethUsdHb));
    }

    function _deploySxdai() internal returns (address) {
        address sXdai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sXDAI", "sXdai"));
        address xDaiUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sXDAI", "xDaiToUsdChainlinkOracle"));
        uint256 xDaiUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "sXDAI", "xDaiToUsdChainlinkHeartbeat"));
        return address(new sXDAI_PriceOracle(sXdai, xDaiUsd, xDaiUsdHb));
    }

    function _deployWstEthL2() internal returns (address) {
        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "wstEth"));
        address wstEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "wstEthToEthChainlink"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "ethToUsdChainlinkOracle"));
        uint256 wstEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "wstEthToEthHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "ethToUsdChainlinkHeartbeat"));
        return address(new wstETH_L2_PriceOracle(wstEth, wstEthEth, ethUsd, wstEthEthHb, ethUsdHb));
    }

    function _deployWeEthL2() internal returns (address) {
        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "weEth"));
        address weEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "weEthToEethChainlink"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "ethToUsdChainlinkOracle"));
        uint256 weEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "weEthToEethHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "ethToUsdChainlinkHeartbeat"));
        return address(new weETH_L2_PriceOracle(weEth, weEthEth, ethUsd, weEthEthHb, ethUsdHb));
    }

    function _deployCbEthL2() internal returns (address) {
        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "cbEth"));
        address cbEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "cbEthToEthChainlink"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "ethToUsdChainlinkOracle"));
        uint256 cbEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "cbEthToEthHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "ethToUsdChainlinkHeartbeat"));
        return address(new cbETH_L2_PriceOracle(cbEth, cbEthEth, ethUsd, cbEthEthHb, ethUsdHb));
    }

    function _deployRsEthL2() internal returns (address) {
        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "rsEth"));
        address rsEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "rsEthToEthChainlink"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "ethToUsdChainlinkOracle"));
        uint256 rsEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "rsEthToEthHeartbeat"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "ethToUsdChainlinkHeartbeat"));
        return address(new rsETH_L2_PriceOracle(rsEth, rsEthEth, ethUsd, rsEthEthHb, ethUsdHb));
    }

    function _deployEzEthL2() internal returns (address) {
        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "ezEth"));
        address xRenzo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "xRenzoDeposit"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "ethToUsdChainlinkHeartbeat"));
        return address(new ezETH_L2_PriceOracle(ezEth, xRenzo, ethUsd, ethUsdHb));
    }

    function _deploySyrupUsdcL2() internal returns (address) {
        address syrup = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "syrupUsdc"));
        address syrupChainlink =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "syrupUsdcToUsdcChainlink"));
        address usdcUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "usdcToUsdChainlinkOracle"));
        uint256 syrupHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "syrupUsdcToUsdcHeartbeat"));
        uint256 usdcUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "usdcToUsdChainlinkHeartbeat"));
        return address(new syrupUSDC_L2_PriceOracle(syrup, syrupChainlink, usdcUsd, syrupHb, usdcUsdHb));
    }

    // -----------------------------------------------------------------------
    // Balance adapter deployment
    // -----------------------------------------------------------------------

    function _deployAllBalanceAdapters() internal {
        string[] memory names = _balanceAdapterNames();
        for (uint256 i = 0; i < names.length; i++) {
            string memory n = names[i];
            if (!ConfigReader.isAdapterEnabled(vm, _chainId, "balanceAdapters", n)) continue;
            address adapter = _deployBalanceAdapter(n);
            if (adapter == address(0)) {
                console2.log("[balanceAdapter] SKIP (unknown type):", n);
                continue;
            }
            _deployedBalanceAdapters.push(adapter);
            console2.log("[balanceAdapter]", n, adapter);
        }
    }

    function _deployBalanceAdapter(string memory name) internal returns (address) {
        address navAddr = address(nav);
        if (_startsWith(name, "AaveV3_")) {
            return _deployAaveV3(name, navAddr);
        }
        if (_equals(name, "SparkLend") || _startsWith(name, "SparkLend_")) {
            return _deploySparkLend(name, navAddr);
        }
        if (_startsWith(name, "MorphoMarket_")) {
            return _deployMorphoMarket(name, navAddr);
        }
        if (_startsWith(name, "MorphoVault_")) {
            return _deployMorphoVault(name, navAddr);
        }
        if (_startsWith(name, "GearboxMarket_")) {
            return _deployGearboxMarket(name, navAddr);
        }
        if (_equals(name, "Cap")) {
            return _deployCap(navAddr);
        }
        if (_startsWith(name, "Curve_")) {
            return _deployCurve(name, navAddr);
        }
        if (_startsWith(name, "Convex_")) {
            return _deployConvex(name, navAddr);
        }
        if (_startsWith(name, "AaveV3SafetyModule_")) {
            return _deployAaveV3SafetyModule(name, navAddr);
        }
        if (_startsWith(name, "BalancerV3_")) {
            return _deployBalancerV3(name, navAddr);
        }
        if (_startsWith(name, "Aura_")) {
            return _deployAura(name, navAddr);
        }
        return address(0);
    }

    function _deployAaveV3(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new AaveV3InstanceBalanceOracle(dataProvider, protocol, navAddr));
    }

    function _deploySparkLend(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new SparkLendBalanceOracle(dataProvider, protocol, navAddr));
    }

    function _deployMorphoMarket(string memory name, address navAddr) internal returns (address) {
        address morpho = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "morpho"));
        bytes32 marketId =
            vm.parseBytes32(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "marketId"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MorphoMarketBalanceOracle(morpho, marketId, protocol, navAddr));
    }

    function _deployMorphoVault(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new MorphoVaultBalanceOracle(vault, protocol, positionDetail, navAddr));
    }

    function _deployGearboxMarket(string memory name, address navAddr) internal returns (address) {
        address market = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "market"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new GearboxMarketBalanceOracle(market, protocol, positionDetail, navAddr));
    }

    function _deployCap(address navAddr) internal returns (address) {
        address cUsd = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "cUsd"));
        address stcUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "stcUsd"));
        address usdc = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "usdc"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "positionDetail");
        return address(new CapBalanceOracle(cUsd, stcUsd, usdc, protocol, positionDetail, navAddr));
    }

    function _deployCurve(string memory name, address navAddr) internal returns (address) {
        address gauge = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "gauge"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new CurveBalanceOracle(gauge, protocol, positionDetail, navAddr));
    }

    function _deployConvex(string memory name, address navAddr) internal returns (address) {
        address rewarder =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewarder"));
        address lpToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "lpToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new ConvexBalanceOracle(rewarder, lpToken, protocol, positionDetail, navAddr));
    }

    function _deployAaveV3SafetyModule(string memory name, address navAddr) internal returns (address) {
        address stakeToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "stakeToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new AaveV3SafetyModuleBalanceOracle(stakeToken, protocol, positionDetail, navAddr));
    }

    function _deployBalancerV3(string memory name, address navAddr) internal returns (address) {
        address pool = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pool"));
        address gauge = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "gauge"));
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new BalancerV3PoolBalanceOracle(pool, gauge, balancerMinter, protocol, navAddr));
    }

    function _deployAura(string memory name, address navAddr) internal returns (address) {
        address pool = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pool"));
        address gauge = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "gauge"));
        address booster =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "booster"));
        uint256 pid = vm.parseUint(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pid"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new Aura(pool, gauge, booster, pid, protocol, positionDetail, navAddr));
    }

    function _balanceAdapterNames() internal pure returns (string[] memory names) {
        names = new string[](46);
        uint256 i = 0;
        names[i++] = "AaveV3_Core";
        names[i++] = "AaveV3_Prime";
        names[i++] = "AaveV3_Arbitrum";
        names[i++] = "AaveV3_Base";
        names[i++] = "AaveV3_Optimism";
        names[i++] = "AaveV3_Gnosis";
        names[i++] = "SparkLend";
        names[i++] = "AaveV3SafetyModule_stkGHO";
        names[i++] = "Cap";
        names[i++] = "MorphoVault_kpkETHPrime_V1";
        names[i++] = "MorphoVault_kpkETHPrime_V2";
        names[i++] = "MorphoVault_kpkUSDCPrime_V1";
        names[i++] = "MorphoVault_kpkUSDCPrime_V2";
        names[i++] = "MorphoVault_kpkUSDCYieldV1";
        names[i++] = "MorphoMarket_wstETH_USDC";
        names[i++] = "MorphoMarket_cbBTC_USDC";
        names[i++] = "MorphoMarket_wstUSR_USDC";
        names[i++] = "MorphoMarket_ETHPlus_USDC";
        names[i++] = "MorphoMarket_WBTC_USDC";
        names[i++] = "MorphoMarket_RLP_USDC";
        names[i++] = "MorphoMarket_syrupUSDC_USDC";
        names[i++] = "MorphoMarket_sUSDS_USDT";
        names[i++] = "MorphoMarket_sUSDS_USDC";
        names[i++] = "MorphoMarket_ETHPlus_WETH";
        names[i++] = "MorphoMarket_wstETH_WETH";
        names[i++] = "MorphoMarket_weETH_WETH";
        names[i++] = "MorphoMarket_rsETH_WETH";
        names[i++] = "MorphoMarket_cbETH_USDC";
        names[i++] = "GearboxMarket_kpkWETH";
        names[i++] = "GearboxMarket_kpkwstETH";
        names[i++] = "BalancerV3_rETH_WETH";
        names[i++] = "BalancerV3_GHO_USDT_USDC";
        names[i++] = "BalancerV3_GHO_USDC_USDT";
        names[i++] = "BalancerV3_GHO_USDC";
        names[i++] = "Aura_rETH_WETH";
        names[i++] = "Aura_GHO_USDT_USDC";
        names[i++] = "Aura_GHO_USDC_USDT";
        names[i++] = "Aura_GHO_USDC";
        names[i++] = "Curve_weETH_WETH";
        names[i++] = "Curve_crvUSD_USDC";
        names[i++] = "Curve_crvUSD_USDT";
        names[i++] = "Curve_RLUSD_USDC";
        names[i++] = "Convex_weETH_WETH";
        names[i++] = "Convex_crvUSD_USDC";
        names[i++] = "Convex_crvUSD_USDT";
        names[i++] = "Convex_RLUSD_USDC";
    }

    // -----------------------------------------------------------------------
    // Asset registration (uses assets.json oracle addresses verbatim — these
    // are either Chainlink feeds or fund-side Custom oracles already on chain).
    // -----------------------------------------------------------------------

    function _registerAllAssets() internal {
        string[] memory symbols = _symbolsForChain(_chainId);
        for (uint256 i = 0; i < symbols.length; i++) {
            _registerAssetIfPossible(symbols[i]);
        }
    }

    function _registerAssetIfPossible(string memory symbol) internal {
        string memory addrStr = ConfigReader.readTokenAddress(vm, _chainId, symbol);
        if (bytes(addrStr).length == 0) return;
        address asset = vm.parseAddress(addrStr);
        if (asset == address(0)) return;

        string memory typeStr = ConfigReader.readTokenType(vm, _chainId, symbol);
        if (_equals(typeStr, "None")) return;
        if (!ConfigReader.hasTokenOracle(vm, _chainId, symbol)) return;

        string memory oracleStr = ConfigReader.readTokenOracle(vm, _chainId, symbol);
        address oracle = vm.parseAddress(oracleStr);
        uint256 heartbeat = vm.parseUint(ConfigReader.readTokenHeartbeat(vm, _chainId, symbol));

        IPrices.PriceType pt = _equals(typeStr, "Custom") ? IPrices.PriceType.Custom : IPrices.PriceType.Chainlink;

        // The native sentinel is pre-registered by NAVCalculator.initialize(). For it (and any other
        // pre-registered asset) use setPriceFeed instead of registerAsset.
        if (nav.isAssetRegistered(asset)) {
            try nav.setPriceFeed(asset, oracle, pt, heartbeat) {
                console2.log("[asset/setFeed]", symbol, asset);
            } catch (bytes memory err) {
                console2.log("[asset/setFeed]", symbol, "FAILED");
                console2.logBytes(err);
            }
            return;
        }

        try nav.registerAsset(asset, oracle, pt, heartbeat) {
            console2.log("[asset]", symbol, asset);
        } catch (bytes memory err) {
            console2.log("[asset]", symbol, "REGISTER FAILED");
            console2.logBytes(err);
        }
    }

    function _registerAllBalanceAdapters() internal {
        for (uint256 i = 0; i < _deployedBalanceAdapters.length; i++) {
            address a = _deployedBalanceAdapters[i];
            try nav.addBalanceOracle(a) {
            // ok
            }
            catch (bytes memory err) {
                console2.log("[oracle] addBalanceOracle FAILED for", a);
                console2.logBytes(err);
            }
        }
    }

    /// @notice Per-chain token symbol list (sourced from script/manage/RegisterAssets.s.sol).
    function _symbolsForChain(uint256 chainId) internal pure returns (string[] memory) {
        if (chainId == 1) {
            string[] memory s = new string[](29);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "eETH";
            s[4] = "weETH";
            s[5] = "rETH";
            s[6] = "ETH+";
            s[7] = "ezETH";
            s[8] = "rsETH";
            s[9] = "MORPHO";
            s[10] = "USDC";
            s[11] = "BAL";
            s[12] = "AURA";
            s[13] = "RPL";
            s[14] = "GEAR";
            s[15] = "stETH";
            s[16] = "CRV";
            s[17] = "CVX";
            s[18] = "USDS";
            s[19] = "USDT";
            s[20] = "DAI";
            s[21] = "GHO";
            s[22] = "USDe";
            s[23] = "sUSDe";
            s[24] = "RLUSD";
            s[25] = "crvUSD";
            s[26] = "sUSDS";
            s[27] = "syrupUSDC";
            s[28] = "EIGEN";
            return s;
        }
        if (chainId == 42161) {
            string[] memory s = new string[](11);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "ezETH";
            s[5] = "rsETH";
            s[6] = "MORPHO";
            s[7] = "USDC";
            s[8] = "USDT";
            s[9] = "GHO";
            s[10] = "syrupUSDC";
            return s;
        }
        if (chainId == 100) {
            string[] memory s = new string[](7);
            s[0] = "xDAI";
            s[1] = "WXDAI";
            s[2] = "WETH";
            s[3] = "wstETH";
            s[4] = "USDCe";
            s[5] = "sDAI";
            s[6] = "GHO";
            return s;
        }
        if (chainId == 8453) {
            string[] memory s = new string[](8);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "cbETH";
            s[5] = "MORPHO";
            s[6] = "USDC";
            s[7] = "GHO";
            return s;
        }
        if (chainId == 10) {
            string[] memory s = new string[](5);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "USDC";
            s[4] = "USDT";
            return s;
        }
        return new string[](0);
    }

    // -----------------------------------------------------------------------
    // String helpers (mirrored from script/deploy/04_DeployBalanceAdapters.s.sol)
    // -----------------------------------------------------------------------

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (p.length > s.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // -----------------------------------------------------------------------
    // NAV reading
    // -----------------------------------------------------------------------

    function _readUsdNav(address account) internal view returns (INAVCalculator.NAV memory) {
        return nav.getAccountNav(account, QUOTE_USD);
    }

    /// @notice Logs NAV value (in USD, 8 decimals) and stale-price asset count for one account.
    function _logNav(string memory label, address account) internal view {
        INAVCalculator.NAV memory n = _readUsdNav(account);
        console2.log("---");
        console2.log("account:", label, account);
        console2.log("nav.value (USD, 8dp):", n.value);
        console2.log("nav.stalePriceAssets.length:", n.stalePriceAssets.length);
        console2.log("nav.sequencerDown:", n.sequencerDown);
    }
}
