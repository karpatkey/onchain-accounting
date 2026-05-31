// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

// Balance adapters
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {AaveV2InstanceBalanceOracle} from "src/balances/protocols/AaveV2Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {SparkLendBalanceOracle} from "src/balances/protocols/SparkLend.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {MorphoVaultBalanceOracle} from "src/balances/protocols/MorphoVault.sol";
import {MorphoVaultsMetaBalanceOracle} from "src/balances/protocols/MorphoVaultsMeta.sol";
import {MorphoMarketsMetaBalanceOracle} from "src/balances/protocols/MorphoMarketsMeta.sol";
import {AaveV3InstancesMetaBalanceOracle} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {ERC4626WrapBalanceOracle} from "src/balances/protocols/ERC4626Wrap.sol";
import {GearboxMarketBalanceOracle} from "src/balances/protocols/GearboxMarket.sol";
import {CapBalanceOracle} from "src/balances/protocols/Cap.sol";
import {CurveBalanceOracle} from "src/balances/protocols/Curve.sol";
import {ConvexBalanceOracle} from "src/balances/protocols/Convex.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {AaveUmbrellaBalanceOracle} from "src/balances/protocols/AaveUmbrella.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {MetaBalancerV3PoolBalanceAdapter} from "src/balances/protocols/balancer/MetaBalancerV3PoolBalanceAdapter.sol";
import {MetaBalancerV3GaugeBalanceAdapter} from "src/balances/protocols/balancer/MetaBalancerV3GaugeBalanceAdapter.sol";
import {Aura} from "src/balances/protocols/Aura.sol";
import {MerklRewardsBalanceOracle, IMerklDistributor} from "src/balances/protocols/MerklRewards.sol";
import {FluidFTokenBalanceOracle} from "src/balances/protocols/FluidFToken.sol";
import {FluidVaultBalanceOracle} from "src/balances/protocols/FluidVault.sol";
import {StaderWithdrawalQueueBalanceOracle} from "src/balances/protocols/StaderWithdrawalQueue.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/StakeWiseV3OsToken.sol";
import {StakeWiseV3VaultBalanceOracle} from "src/balances/protocols/StakeWiseV3Vault.sol";
import {UniswapV2BalanceOracle} from "src/balances/protocols/UniswapV2.sol";
import {UniswapV3PoolBalanceOracle} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";
import {PancakeSwapV2BalanceOracle} from "src/balances/protocols/pancakeswap/PancakeSwapV2.sol";
import {PancakeSwapV3PoolBalanceOracle} from "src/balances/protocols/pancakeswap/PancakeSwapV3Pool.sol";

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
import {ETHx_PriceOracle} from "src/prices/protocols/ETHx_Price.sol";
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
    using stdJson for string;

    // Set by child setUp before _setupAndDeploy().
    uint256 internal _chainId;
    uint256 internal _forkBlock; // optional override; if 0 the value from accounts.json is used
    string internal _forkNetwork; // e.g. "eth-mainnet"

    NAVCalculator public nav;
    address public admin = makeAddr("integration-admin");

    uint256 public fork;

    /// @notice quoteAsset = address(0) ⇒ NAV value is denominated in USD with 8 decimals.
    address internal constant QUOTE_USD = address(0);

    /// @notice Path to the integration test accounts/snapshot file (relative to project root).
    string internal constant ACCOUNTS_JSON = "test/integration/accounts.json";

    /// @notice Path to the Merkl proof fixture file consumed in setup. Regenerated by
    ///         script/test/refresh-integration-snapshot.sh; missing or empty entries are tolerated.
    string internal constant MERKL_PROOFS_JSON = "test/integration/merkl-proofs.json";

    /// @notice Address of the deployed MerklRewards adapter for this chain (zero if not deployed).
    address internal _merklOracle;

    /// @notice Tracked deployed adapter addresses (for diagnostics + addBalanceOracle pass).
    address[] internal _deployedBalanceAdapters;

    /// @notice Config names parallel to `_deployedBalanceAdapters` (used to read per-adapter config such as
    ///         a meta-adapter's `metaInstances` list after registration).
    string[] internal _deployedBalanceAdapterNames;

    /// @notice Maps feed name → ephemerally-deployed price feed address. Populated by
    ///         _tryDeployPriceFeed during _deployAllPriceFeeds. Serves two purposes in
    ///         _registerAssetIfPossible: (1) fallback when assets.json.pricefeed is blank (feed
    ///         exists in code but not yet deployed to production); (2) override when a prod
    ///         address exists but has the old ERC165 ID (e.g. after latestRoundData() was added
    ///         to IPriceFeedCustom). Key is the feed deploy name, not the token symbol — use
    ///         _priceFeedNameForSymbol to convert. Fork-only; production registration via
    ///         RegisterAssets.s.sol reads pricefeed from assets.json.
    mapping(string => address) internal _ephemeralPriceFeeds;

    function _setupAndDeploy() internal {
        require(_chainId != 0, "child must set _chainId");
        require(bytes(_forkNetwork).length > 0, "child must set _forkNetwork");

        if (_forkBlock == 0) {
            _forkBlock = _readForkBlockFromAccountsJson(_chainId);
        }

        fork = createSelectForkWithCadence(getAlchemyUrl(_forkNetwork), _forkBlock);

        // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml libraries config).
        // Etch its runtime code so DELEGATECALL succeeds on any fork where it hasn't been deployed yet.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(0xf6cb8f59B182B7BdefC6975874419028034f9379, priceFeedLibImpl.code);

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
        // Asset registration MUST precede balance-adapter deployment because some adapter
        // constructors (e.g. ERC4626WrapBalanceOracle) require the underlying asset to be
        // registered before they can deploy. Production deploy mirrors this via the Safe-TX
        // bundle ordering in 06_Configure.s.sol (registerAsset → addBalanceOracle).
        _registerAllAssets();
        _deployAllBalanceAdapters();
        _registerAllBalanceAdapters();
        _configureMetaInstances();
        _seedMerklProofs();
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
        // Mainnet (1), Gnosis (100), BSC (56), Polygon (137): no L2 sequencer feed.
        return address(0);
    }

    function _nativeSymbol(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 100) return "xDAI";
        if (chainId == 56) return "BNB";
        if (chainId == 137) return "POL";
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
            _tryDeployPriceFeed("ETHx", _deployEthx);
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
        _ephemeralPriceFeeds[name] = addr;
        console2.log("[priceFeed]", name, addr);
    }

    /// @notice Returns the price feed name (as used in _deployAllPriceFeeds) for a given token symbol.
    function _priceFeedNameForSymbol(string memory symbol) internal view returns (string memory) {
        if (_chainId == 1) {
            return symbol;
        }
        if (_chainId == 100 && _equals(symbol, "sDAI")) {
            return "sXDAI";
        }
        return string(abi.encodePacked(symbol, "_L2"));
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
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "ethToUsdChainlinkHeartbeat"));
        return address(new wstETH_PriceOracle(wstEth, ethUsd, ethUsdHb));
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

    function _deployEthx() internal returns (address) {
        address ethx = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "ethx"));
        address stakePoolsManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "stakePoolsManager"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "ethToUsdChainlinkHeartbeat"));
        return address(new ETHx_PriceOracle(ethx, stakePoolsManager, ethUsd, ethUsdHb));
    }

    // -----------------------------------------------------------------------
    // Balance adapter deployment
    // -----------------------------------------------------------------------

    function _deployAllBalanceAdapters() internal {
        string[] memory names = ConfigReader.getEnabledAdapters(vm, _chainId, "balanceAdapters");
        for (uint256 i = 0; i < names.length; i++) {
            string memory n = names[i];
            // MerklRewards is always deployed in the integration test (independent of the
            // chain-config `enabled` flag, which only gates production deploys). The cache is
            // empty unless `merkl-proofs.json` has entries for this chain — see `_seedMerklProofs`.
            // This keeps the integration test exercising the Merkl wiring on every run, while
            // production deploys still honor the `enabled` flag.
            if (!_equals(n, "MerklRewards") && !ConfigReader.isAdapterEnabled(vm, _chainId, "balanceAdapters", n)) {
                continue;
            }
            address adapter = _deployBalanceAdapter(n);
            if (adapter == address(0)) {
                console2.log("[balanceAdapter] SKIP (unknown type):", n);
                continue;
            }
            _deployedBalanceAdapters.push(adapter);
            _deployedBalanceAdapterNames.push(n);
            console2.log("[balanceAdapter]", n, adapter);
        }
    }

    function _deployBalanceAdapter(string memory name) internal returns (address) {
        address navAddr = address(nav);
        if (_equals(name, "AaveV3InstancesMeta")) {
            return _deployAaveV3InstancesMeta(name, navAddr);
        }
        if (_startsWith(name, "AaveV3_")) {
            return _deployAaveV3(name, navAddr);
        }
        if (_startsWith(name, "CompoundV3_")) {
            return _deployCompoundV3(name, navAddr);
        }
        if (_equals(name, "SparkLend") || _startsWith(name, "SparkLend_")) {
            return _deploySparkLend(name, navAddr);
        }
        if (_equals(name, "MorphoMarketsMeta")) {
            return _deployMorphoMarketsMeta(name, navAddr);
        }
        if (_startsWith(name, "MorphoMarket_")) {
            return _deployMorphoMarket(name, navAddr);
        }
        if (_equals(name, "MorphoVaultsMeta")) {
            return _deployMorphoVaultsMeta(name, navAddr);
        }
        if (_startsWith(name, "MorphoVault_")) {
            return _deployMorphoVault(name, navAddr);
        }
        if (_startsWith(name, "ERC4626Wrap_")) {
            return _deployERC4626Wrap(name, navAddr);
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
        if (_equals(name, "AaveV3SafetyModule")) {
            return _deployAaveV3SafetyModule(name, navAddr);
        }
        if (_equals(name, "AaveUmbrella")) {
            return _deployAaveUmbrella(name, navAddr);
        }
        if (_equals(name, "BalancerPoolsMeta")) {
            return _deployBalancerPoolsMeta(name, navAddr);
        }
        if (_equals(name, "BalancerGaugesMeta")) {
            return _deployBalancerGaugesMeta(name, navAddr);
        }
        if (_startsWith(name, "BalancerV3_")) {
            return _deployBalancerV3(name, navAddr);
        }
        if (_startsWith(name, "Aura_")) {
            return _deployAura(name, navAddr);
        }
        if (_equals(name, "MerklRewards")) {
            return _deployMerklRewards(name, navAddr);
        }
        if (_startsWith(name, "AaveV2_") || _equals(name, "AaveV2")) {
            return _deployAaveV2(name, navAddr);
        }
        if (_startsWith(name, "Fluid_fToken_")) {
            return _deployFluidFToken(name, navAddr);
        }
        if (_startsWith(name, "Fluid_Vault_")) {
            return _deployFluidVault(name, navAddr);
        }
        if (_equals(name, "StaderWithdrawalQueue")) {
            return _deployStaderWithdrawalQueue(name, navAddr);
        }
        if (_startsWith(name, "StakeWiseV3OsToken_")) {
            return _deployStakeWiseV3OsToken(name, navAddr);
        }
        if (_startsWith(name, "StakeWiseV3Vault_")) {
            return _deployStakeWiseV3Vault(name, navAddr);
        }
        if (_startsWith(name, "UniswapV2_")) {
            return _deployUniswapV2(name, navAddr);
        }
        if (_startsWith(name, "UniswapV3_")) {
            return _deployUniswapV3Pool(name, navAddr);
        }
        if (_startsWith(name, "PancakeSwapV2_")) {
            return _deployPancakeSwapV2(name, navAddr);
        }
        if (_startsWith(name, "PancakeSwapV3_")) {
            return _deployPancakeSwapV3Pool(name, navAddr);
        }
        return address(0);
    }

    function _deployAaveV3(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new AaveV3InstanceBalanceOracle(dataProvider, protocol, positionDetail, positionId, navAddr));
    }

    function _deploySparkLend(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new SparkLendBalanceOracle(dataProvider, protocol, positionDetail, positionId, navAddr));
    }

    function _deployCompoundV3(string memory name, address navAddr) internal returns (address) {
        address compoundRewards =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "compoundRewards"));
        address comet = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "comet"));
        address rewardToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewardToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(
            new CompoundV3Comet(compoundRewards, comet, rewardToken, protocol, positionDetail, positionId, navAddr)
        );
    }

    function _deployMorphoMarket(string memory name, address navAddr) internal returns (address) {
        address morpho = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "morpho"));
        bytes32 marketId =
            vm.parseBytes32(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "marketId"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        return address(new MorphoMarketBalanceOracle(morpho, marketId, protocol, positionDetail, navAddr));
    }

    function _deployMorphoVaultsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MorphoVaultsMetaBalanceOracle(protocol, navAddr));
    }

    function _deployBalancerPoolsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MetaBalancerV3PoolBalanceAdapter(protocol, navAddr));
    }

    function _deployBalancerGaugesMeta(string memory name, address navAddr) internal returns (address) {
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MetaBalancerV3GaugeBalanceAdapter(balancerMinter, protocol, navAddr));
    }

    function _deployMorphoMarketsMeta(string memory name, address navAddr) internal returns (address) {
        address morpho = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "morpho"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MorphoMarketsMetaBalanceOracle(morpho, protocol, navAddr));
    }

    function _deployAaveV3InstancesMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new AaveV3InstancesMetaBalanceOracle(protocol, navAddr));
    }

    function _deployMorphoVault(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new MorphoVaultBalanceOracle(vault, protocol, positionDetail, positionId, navAddr));
    }

    function _deployERC4626Wrap(string memory name, address navAddr) internal returns (address) {
        address wrapper =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "wrapper"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new ERC4626WrapBalanceOracle(wrapper, protocol, positionDetail, positionId, navAddr));
    }

    function _deployGearboxMarket(string memory name, address navAddr) internal returns (address) {
        address market = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "market"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new GearboxMarketBalanceOracle(market, protocol, positionDetail, positionId, navAddr));
    }

    function _deployCap(address navAddr) internal returns (address) {
        address cUsd = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "cUsd"));
        address stcUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "stcUsd"));
        address usdc = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "usdc"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "positionId");
        return address(new CapBalanceOracle(cUsd, stcUsd, usdc, protocol, positionDetail, positionId, navAddr));
    }

    function _deployCurve(string memory name, address navAddr) internal returns (address) {
        address gauge = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "gauge"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new CurveBalanceOracle(gauge, protocol, positionDetail, positionId, navAddr));
    }

    function _deployConvex(string memory name, address navAddr) internal returns (address) {
        address rewarder =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewarder"));
        address lpToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "lpToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new ConvexBalanceOracle(rewarder, lpToken, protocol, positionDetail, positionId, navAddr));
    }

    function _deployAaveV3SafetyModule(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new AaveV3SafetyModuleBalanceOracle(navAddr, protocol, positionDetail, positionId));
    }

    function _deployAaveUmbrella(string memory name, address navAddr) internal returns (address) {
        address rewardsController =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewardsController"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new AaveUmbrellaBalanceOracle(rewardsController, navAddr, protocol, positionDetail, positionId));
    }

    function _deployBalancerV3(string memory name, address navAddr) internal returns (address) {
        address pool = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pool"));
        address gauge = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "gauge"));
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(
            new BalancerV3PoolBalanceOracle(pool, gauge, balancerMinter, protocol, positionDetail, positionId, navAddr)
        );
    }

    function _deployMerklRewards(string memory name, address navAddr) internal returns (address) {
        // The integration test owns the adapter (admin = msg.sender once we vm.startPrank(admin)) so
        // it can call submitProof during setup. Production deploys use chainConfig.admin instead — see
        // script/deploy/04_DeployBalanceAdapters.s.sol::_deployMerklRewards.
        address distributor =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "distributor"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        address adapter =
            address(new MerklRewardsBalanceOracle(distributor, navAddr, protocol, positionDetail, positionId, admin));
        _merklOracle = adapter;
        return adapter;
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
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new Aura(pool, gauge, booster, pid, protocol, positionDetail, positionId, navAddr));
    }

    function _deployAaveV2(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new AaveV2InstanceBalanceOracle(dataProvider, protocol, positionDetail, positionId, navAddr));
    }

    function _deployFluidFToken(string memory name, address navAddr) internal returns (address) {
        address fToken = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "fToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new FluidFTokenBalanceOracle(fToken, protocol, positionDetail, positionId, navAddr));
    }

    function _deployFluidVault(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        address vaultResolver =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vaultResolver"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new FluidVaultBalanceOracle(vault, vaultResolver, protocol, positionDetail, positionId, navAddr));
    }

    function _deployStaderWithdrawalQueue(string memory name, address navAddr) internal returns (address) {
        address userWithdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "userWithdrawalManager")
        );
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(
            new StaderWithdrawalQueueBalanceOracle(
                userWithdrawalManager, underlyingToken, protocol, positionDetail, positionId, navAddr
            )
        );
    }

    function _deployStakeWiseV3OsToken(string memory name, address navAddr) internal returns (address) {
        address osToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "osToken"));
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        address osTokenVaultController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "osTokenVaultController")
        );
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(
            new StakeWiseV3OsTokenBalanceOracle(
                osToken, underlyingToken, osTokenVaultController, protocol, positionDetail, positionId, navAddr
            )
        );
    }

    function _deployStakeWiseV3Vault(string memory name, address navAddr) internal returns (address) {
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(
            new StakeWiseV3VaultBalanceOracle(underlyingToken, vault, protocol, positionDetail, positionId, navAddr)
        );
    }

    function _deployUniswapV2(string memory name, address navAddr) internal returns (address) {
        address pair = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pair"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new UniswapV2BalanceOracle(pair, protocol, positionDetail, positionId, navAddr));
    }

    function _deployUniswapV3Pool(string memory name, address navAddr) internal returns (address) {
        address pool = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pool"));
        address positionManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionManager"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return
            address(
                new UniswapV3PoolBalanceOracle(pool, positionManager, protocol, positionDetail, positionId, navAddr)
            );
    }

    function _deployPancakeSwapV2(string memory name, address navAddr) internal returns (address) {
        address pair = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pair"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(new PancakeSwapV2BalanceOracle(pair, protocol, positionDetail, positionId, navAddr));
    }

    function _deployPancakeSwapV3Pool(string memory name, address navAddr) internal returns (address) {
        address pool = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "pool"));
        address positionManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionManager"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        string memory positionDetail =
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionDetail");
        string memory positionId = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionId");
        return address(
            new PancakeSwapV3PoolBalanceOracle(pool, positionManager, protocol, positionDetail, positionId, navAddr)
        );
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

        // Resolve the oracle address. Prefer assets.json's hardcoded `pricefeed` (set by
        // 03_DeployPriceFeeds at production deploy time). When that field is blank — i.e. the
        // feed contract exists in code but hasn't been deployed to production yet, e.g. ETHx
        // pre-mainnet-deploy — fall back to the ephemerally-deployed instance from
        // _deployAllPriceFeeds. This makes the integration test exercise the feed end-to-end
        // before the production deploy lands. Once the production deploy completes and
        // assets.json.pricefeed is populated, this branch becomes inert for that symbol.
        address oracle;
        if (ConfigReader.hasTokenOracle(vm, _chainId, symbol)) {
            oracle = vm.parseAddress(ConfigReader.readTokenOracle(vm, _chainId, symbol));
        } else if (_ephemeralPriceFeeds[_priceFeedNameForSymbol(symbol)] != address(0)) {
            oracle = _ephemeralPriceFeeds[_priceFeedNameForSymbol(symbol)];
            console2.log("[asset/ephemeral]", symbol, oracle);
        } else {
            return;
        }
        uint256 heartbeat = vm.parseUint(ConfigReader.readTokenHeartbeat(vm, _chainId, symbol));

        IPrices.PriceType pt = _equals(typeStr, "Custom") ? IPrices.PriceType.Custom : IPrices.PriceType.Chainlink;

        // For Custom feeds: prefer the ephemerally-deployed feed over any prod address in assets.json.
        // Reason: adding latestRoundData() to IPriceFeedCustom changed the ERC165 interface ID —
        // old deployed addresses fail checkPriceOracleSupport(). The ephemeral feed (new code)
        // passes the check and is functionally equivalent for fork tests.
        if (pt == IPrices.PriceType.Custom) {
            address fresh = _ephemeralPriceFeeds[_priceFeedNameForSymbol(symbol)];
            if (fresh != address(0)) oracle = fresh;
        }

        // The native sentinel is pre-registered by NAVCalculator.initialize(). For it (and any other
        // pre-registered asset) add the first price feed via addPriceFeed.
        if (nav.isAssetRegistered(asset)) {
            try nav.addPriceFeed(asset, oracle, pt, heartbeat) {
                console2.log("[asset/addFeed]", symbol, asset);
            } catch (bytes memory err) {
                console2.log("[asset/addFeed]", symbol, "FAILED");
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

    /// @notice Applies each meta-adapter's `metaInstances` config to NAVCalculator (ADR 0010). This is how the
    ///         NAV calculator is told which instances of a protocol to query — e.g. the Morpho-vault universe.
    /// @dev Runs after registration (setMetaInstances requires the oracle to be registered) and within the same
    ///      `admin` prank that holds MANAGER. Adapters with no `metaInstances` config are skipped.
    function _configureMetaInstances() internal {
        for (uint256 i = 0; i < _deployedBalanceAdapters.length; i++) {
            address a = _deployedBalanceAdapters[i];
            string memory name = _deployedBalanceAdapterNames[i];

            // Union address-keyed (`metaInstances`, widened) + raw bytes32 (`metaInstancesRaw`, e.g. marketIds).
            address[] memory addrs =
                ConfigReader.readAdapterAddressArray(vm, _chainId, "balanceAdapters", name, "metaInstances");
            bytes32[] memory raw =
                ConfigReader.readAdapterBytes32Array(vm, _chainId, "balanceAdapters", name, "metaInstancesRaw");
            if (addrs.length + raw.length == 0) continue;

            bytes32[] memory instances = new bytes32[](addrs.length + raw.length);
            for (uint256 j = 0; j < addrs.length; j++) {
                instances[j] = bytes32(uint256(uint160(addrs[j])));
            }
            for (uint256 j = 0; j < raw.length; j++) {
                instances[addrs.length + j] = raw[j];
            }

            // No try/catch: the per-instance adapters are disabled in config, so a failed setMetaInstances must
            // fail the run loudly rather than silently omit the migrated positions from snapshots/asserts.
            nav.setMetaInstances(a, instances);
            console2.log("[meta] setMetaInstances", name, instances.length);
        }
    }

    /// @notice Pre-populates the MerklRewards adapter cache from `merkl-proofs.json` (regenerated on
    ///         every snapshot bump). Tolerant of missing/empty/stale fixtures: silently skips the
    ///         chain block if not present, logs and continues on per-entry verification failure.
    /// @dev    Called from setUp while vm.startPrank(admin) is active. Submitter must equal the
    ///         adapter's owner (set to `admin` in `_deployMerklRewards`).
    function _seedMerklProofs() internal {
        if (_merklOracle == address(0)) return;
        if (!vm.exists(MERKL_PROOFS_JSON)) {
            console2.log("[merkl] no proof fixture file; skipping cache seed");
            return;
        }
        string memory json = vm.readFile(MERKL_PROOFS_JSON);
        string memory chainKey = string.concat("$[\"", vm.toString(_chainId), "\"]");
        if (!vm.keyExistsJson(json, chainKey)) {
            console2.log("[merkl] no fixtures for chain; skipping cache seed");
            return;
        }

        // Warn loudly if the fixture's captured root doesn't match the live root at this fork block.
        // This happens when the Merkl root rotated between the `cast call --block` and the API fetch
        // during refresh-integration-snapshot.sh — a narrow but real race window. All proofs will
        // fail submitProof in that case, silently zeroing Merkl rewards in NAV.
        // Fix: re-run refresh-integration-snapshot.sh to re-capture proofs against the current root.
        string memory expectedRootKey = string.concat(chainKey, ".expectedRoot");
        if (vm.keyExistsJson(json, expectedRootKey)) {
            bytes32 expectedRoot = vm.parseJsonBytes32(json, expectedRootKey);
            address distributor = MerklRewardsBalanceOracle(_merklOracle).DISTRIBUTOR();
            bytes32 liveRoot = IMerklDistributor(distributor).getMerkleRoot();
            if (expectedRoot != bytes32(0) && expectedRoot != liveRoot) {
                console2.log(
                    "[merkl] WARNING: fixture root does not match live Distributor root at this fork block."
                    " All proof submissions will fail and Merkl rewards will be 0 in NAV."
                    " Re-run refresh-integration-snapshot.sh to capture proofs against the current root."
                );
            }
        }

        string memory usersKey = string.concat(chainKey, ".users");
        if (!vm.keyExistsJson(json, usersKey)) {
            console2.log("[merkl] empty proof block; skipping");
            return;
        }
        address[] memory users = vm.parseJsonAddressArray(json, usersKey);
        address[] memory tokens = vm.parseJsonAddressArray(json, string.concat(chainKey, ".tokens"));
        string[] memory amountStrs = vm.parseJsonStringArray(json, string.concat(chainKey, ".amounts"));
        if (users.length == 0) {
            console2.log("[merkl] zero entries; cache stays empty");
            return;
        }
        require(
            users.length == tokens.length && users.length == amountStrs.length,
            "merkl-proofs.json users/tokens/amounts length mismatch"
        );
        uint256 ok;
        uint256 failed;
        for (uint256 i = 0; i < users.length; i++) {
            string memory proofKey = string.concat(chainKey, ".proofs[", vm.toString(i), "]");
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, proofKey);
            uint256 amount = vm.parseUint(amountStrs[i]);
            try MerklRewardsBalanceOracle(_merklOracle).submitProof(users[i], tokens[i], amount, proof) {
                ok++;
            } catch (bytes memory err) {
                failed++;
                console2.log("[merkl] submitProof failed (proof stale or root mismatch?) user=", users[i]);
                console2.logBytes(err);
            }
        }
        console2.log("[merkl] proofs cached:", ok);
        if (failed != 0) console2.log("[merkl] proofs failed (treated as 0 in NAV):", failed);
    }

    /// @notice Per-chain token symbol list (sourced from script/manage/RegisterAssets.s.sol).
    function _symbolsForChain(uint256 chainId) internal pure returns (string[] memory) {
        if (chainId == 1) {
            string[] memory s = new string[](33);
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
            s[28] = "ETHx";
            s[29] = "COMP";
            s[30] = "EURC";
            s[31] = "WBTC";
            s[32] = "AAVE";
            return s;
        }
        if (chainId == 42161) {
            string[] memory s = new string[](12);
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
            s[11] = "COMP";
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
            string[] memory s = new string[](9);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "weETH";
            s[4] = "cbETH";
            s[5] = "MORPHO";
            s[6] = "USDC";
            s[7] = "GHO";
            s[8] = "COMP";
            return s;
        }
        if (chainId == 10) {
            string[] memory s = new string[](6);
            s[0] = "ETH";
            s[1] = "WETH";
            s[2] = "wstETH";
            s[3] = "USDC";
            s[4] = "USDT";
            s[5] = "COMP";
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

    // -----------------------------------------------------------------------
    // NAV position detail serialization (used by RefreshIntegrationSnapshot)
    // -----------------------------------------------------------------------

    /// @notice Serializes one Position to a JSON object string.
    /// @dev Protocol/positionDetail strings are written verbatim — our adapters use
    ///      plain ASCII labels with no quotes or backslashes, so no escaping is needed.
    function _positionToJson(INAVCalculator.Position memory pos) internal pure returns (string memory out) {
        out = string.concat(
            '{"symbol":"',
            pos.underlyingAsset.symbol,
            '","address":"',
            vm.toString(pos.underlyingAsset.asset),
            '","decimals":',
            vm.toString(uint256(pos.underlyingAsset.decimals))
        );
        out = string.concat(out, ',"amount":"', vm.toString(pos.amount), '","isDebt":', pos.isDebt ? "true" : "false");
        out = string.concat(
            out,
            ',"valueUsd8dp":"',
            vm.toString(pos.value),
            '","price":"',
            vm.toString(pos.price),
            '","priceDecimals":',
            vm.toString(uint256(pos.priceDecimals))
        );
        // positionDetail is a JSON object — embed unquoted so inner keys aren't double-encoded.
        out = string.concat(
            out,
            ',"protocol":"',
            pos.protocol,
            '","positionDetail":',
            pos.positionDetail,
            ',"positionId":"',
            pos.positionId,
            '"}'
        );
    }

    /// @notice Calls getAccountPositions for every enabled account on _chainId and returns
    ///         a JSON object string keyed by account address.
    function _buildPositionDetailsJson() internal view returns (string memory out) {
        string memory json = _readAccountsJson();
        out = "{";
        bool first = true;
        uint256 i;
        while (true) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            if (!vm.keyExists(json, base)) break;

            string memory addrStr = json.readString(string.concat(base, ".address"));
            if (bytes(addrStr).length == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address account = vm.parseAddress(addrStr);
            uint256[] memory enabled = json.readUintArray(string.concat(base, ".enabledChains"));

            if (_contains(enabled, _chainId)) {
                if (!first) out = string.concat(out, ",");
                first = false;

                INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, QUOTE_USD);
                out = string.concat(out, '"', vm.toString(account), '":[');
                for (uint256 j = 0; j < positions.length; j++) {
                    if (j > 0) out = string.concat(out, ",");
                    out = string.concat(out, _positionToJson(positions[j]));
                }
                out = string.concat(out, "]");
            }
            unchecked {
                ++i;
            }
        }
        out = string.concat(out, "}");
    }

    // -----------------------------------------------------------------------
    // accounts.json: drives both the test asserts and the bump script.
    // Schema lives in docs/howto/refresh-integration-test-blocks.md.
    // -----------------------------------------------------------------------

    /// @dev Reads the per-chain `forkBlock` from accounts.json. The bump script keeps this current.
    function _readForkBlockFromAccountsJson(uint256 chainId) internal view returns (uint256) {
        string memory json = _readAccountsJson();
        string memory key = string.concat(".chains.", vm.toString(chainId), ".forkBlock");
        require(vm.keyExists(json, key), "accounts.json: missing chains.<id>.forkBlock");
        return json.readUint(key);
    }

    /// @notice Iterate every account in accounts.json whose enabledChains includes _chainId,
    ///         read NAV via getAccountNav, log it, and assert it equals the snapshotted expected value.
    /// @dev Deferred-failure: walks every enabled (account, chain) pair, logs each actual NAV vs
    ///      expected, accumulates mismatches into a single list, and reverts at the end with a
    ///      summary if any account failed. This way a single CI run surfaces every drifted snapshot
    ///      at once instead of stopping at the first mismatch — important when the harness adapter
    ///      surface changes and many snapshots need re-pinning.
    function _assertNavsForCurrentChain() internal view {
        require(_chainId != 0, "_chainId not set");
        string memory json = _readAccountsJson();

        uint256 mismatches = 0;
        uint256 i;
        while (true) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            if (!vm.keyExists(json, base)) break;

            string memory addrStr = json.readString(string.concat(base, ".address"));
            if (bytes(addrStr).length == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address account = vm.parseAddress(addrStr);
            string memory label = json.readString(string.concat(base, ".label"));
            uint256[] memory enabledChains = json.readUintArray(string.concat(base, ".enabledChains"));

            if (_contains(enabledChains, _chainId)) {
                string memory expectedKey = string.concat(base, ".expected.", vm.toString(_chainId), ".navUsd8dp");
                require(
                    vm.keyExists(json, expectedKey),
                    string.concat("accounts.json: missing expected.<chain>.navUsd8dp for ", label)
                );
                int256 expected = vm.parseInt(json.readString(expectedKey));

                INAVCalculator.NAV memory n = _readUsdNav(account);
                _logNav(label, account);
                if (n.value != expected) {
                    console2.log("[NAV-MISMATCH]", label, "chainId:", _chainId);
                    console2.log("  expected (8dp USD):", expected);
                    console2.log("  actual   (8dp USD):", n.value);
                    unchecked {
                        ++mismatches;
                    }
                }
                if (n.stalePriceAssets.length != 0) {
                    console2.log("[STALE-PRICES]", label, "count:", n.stalePriceAssets.length);
                    unchecked {
                        ++mismatches;
                    }
                }
                if (n.sequencerDown) {
                    console2.log("[SEQUENCER-DOWN]", label);
                    unchecked {
                        ++mismatches;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
        require(mismatches == 0, "one or more NAV assertions failed; see [NAV-MISMATCH] logs above");
    }

    function _readAccountsJson() internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile(string.concat(vm.projectRoot(), "/", ACCOUNTS_JSON));
    }

    function _contains(uint256[] memory haystack, uint256 needle) internal pure returns (bool) {
        for (uint256 i; i < haystack.length; ++i) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Snapshot emission — called by refresh-integration-snapshot.sh via
    // `forge test --match-test test_emitSnapshots` (replaces forge script to
    // avoid the chain-1 hang documented in docs/howto/refresh-integration-test-blocks.md).
    // -----------------------------------------------------------------------

    /// @notice Emits SNAPSHOT lines + writes nav-positions JSON without asserting.
    ///         Always passes; the shell script greps SNAPSHOT lines and applies them to
    ///         accounts.json with jq — identical to the forge-script path.
    function test_emitSnapshots() public {
        _emitNavSnapshotsForCurrentChain();
        _emitNavPositionsForCurrentChain();
    }

    function _emitNavSnapshotsForCurrentChain() internal view {
        string memory json = _readAccountsJson();
        uint256 i;
        while (true) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            if (!vm.keyExists(json, base)) break;
            string memory addrStr = json.readString(string.concat(base, ".address"));
            if (bytes(addrStr).length == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address account = vm.parseAddress(addrStr);
            uint256[] memory enabled = json.readUintArray(string.concat(base, ".enabledChains"));
            if (_contains(enabled, _chainId)) {
                INAVCalculator.NAV memory n = _readUsdNav(account);
                // SNAPSHOT format must match RefreshIntegrationSnapshot.s.sol exactly so that
                // the harvest_chain parser in refresh-integration-snapshot.sh works unchanged.
                console2.log(
                    string.concat(
                        "SNAPSHOT|",
                        vm.toString(_chainId),
                        "|",
                        vm.toString(i),
                        "|",
                        vm.toString(account),
                        "|",
                        vm.toString(n.value),
                        "|",
                        n.sequencerDown ? "true" : "false",
                        "|",
                        vm.toString(n.stalePriceAssets.length)
                    )
                );
            }
            unchecked {
                ++i;
            }
        }
    }

    function _emitNavPositionsForCurrentChain() internal {
        vm.writeFile(
            string.concat("test/integration/nav-positions-", vm.toString(_chainId), ".json"),
            string.concat(
                '{"chainId":',
                vm.toString(_chainId),
                ',"forkBlock":',
                vm.toString(_forkBlock),
                ',"accounts":',
                _buildPositionDetailsJson(),
                "}"
            )
        );
    }
}
