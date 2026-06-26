// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";

// Balance adapters
import {AaveV2InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV2InstancesMeta.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "src/balances/protocols/CompoundV3CometsMeta.sol";
import {SparkLendBalanceAdapter} from "src/balances/protocols/SparkLend.sol";
import {MorphoVaultsMetaBalanceAdapter} from "src/balances/protocols/MorphoVaultsMeta.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/protocols/MorphoMarketsMeta.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {ERC4626WrapBalanceAdapter} from "src/balances/protocols/ERC4626Wrap.sol";
import {GearboxMarketsMetaBalanceAdapter} from "src/balances/protocols/GearboxMarketsMeta.sol";
import {CapBalanceAdapter} from "src/balances/protocols/Cap.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/protocols/curve/CurvePoolsMeta.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/protocols/curve/CurveGaugesMeta.sol";
import {ConvexRewardsMetaBalanceAdapter} from "src/balances/protocols/ConvexRewardsMeta.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {AaveUmbrellaBalanceAdapter} from "src/balances/protocols/AaveUmbrella.sol";
import {BalancerV3PoolsMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV3PoolsMeta.sol";
import {BalancerV2PoolsMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV2PoolsMeta.sol";
import {BalancerV2GaugesMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV2GaugesMeta.sol";
import {BalancerV3GaugesMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV3GaugesMeta.sol";
import {MerklRewardsBalanceAdapter, IMerklDistributor} from "src/balances/protocols/MerklRewards.sol";
import {FluidFTokensMetaBalanceAdapter} from "src/balances/protocols/FluidFTokensMeta.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/protocols/FluidVaultsMeta.sol";
import {StaderWithdrawalQueueBalanceAdapter} from "src/balances/protocols/StaderWithdrawalQueue.sol";
import {StakeWiseV3VaultsMetaBalanceAdapter} from "src/balances/protocols/StakeWiseV3VaultsMeta.sol";
import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV3PoolsMeta.sol";
import {UniswapV2PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV2PoolsMeta.sol";
import {PancakeSwapV2PoolsMetaBalanceAdapter} from "src/balances/protocols/pancakeswap/PancakeSwapV2PoolsMeta.sol";
import {PancakeSwapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMeta.sol";

// Price feed adapters (Mainnet)
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {LDO_PriceOracle} from "src/prices/protocols/LDO_Price.sol";
import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";
import {sUSDe_PriceOracle} from "src/prices/protocols/sUSDe_Price.sol";
import {syrupUSDC_PriceOracle} from "src/prices/protocols/syrupUSDC_Price.sol";
import {wstETH_PriceOracle} from "src/prices/protocols/wstETH_Price.sol";
import {CrossRatePriceAdapter} from "src/prices/protocols/CrossRate_Price.sol";
import {rETH_PriceOracle} from "src/prices/protocols/rETH_Price.sol";
import {ankrETH_PriceOracle} from "src/prices/protocols/ankrETH_Price.sol";
import {NXM_PriceOracle} from "src/prices/protocols/NXM_Price.sol";
import {osToken_PriceOracle} from "src/prices/protocols/osToken_Price.sol";
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
import {aa} from "test/helpers/AdapterArray.sol";

/// @title IntegrationFromConfigBase
/// @notice Per-chain integration test harness that mirrors the deploy pipeline:
///         deploys NAVCalculator + every enabled price feed adapter (assets.json) + every enabled
///         balance adapter (chains/<id>.json), registers all assets and balance adapters, then reads
///         NAV for the configured accounts. Equivalent to running 02_2 + 03 + 04 + 06_Configure + RegisterAssets
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
    address internal _merklAdapter;

    /// @notice Tracked deployed adapter addresses (for diagnostics + addBalanceAdapter pass).
    address[] internal _deployedBalanceAdapters;

    /// @notice Config names parallel to `_deployedBalanceAdapters` (used to read per-adapter config such as
    ///         a meta-adapter's `metaInstances` list after registration).
    string[] internal _deployedBalanceAdapterNames;

    /// @notice Maps feed name → ephemerally-deployed price feed address. Populated by
    ///         _tryDeployPriceFeed during _deployAllPriceFeeds. Serves two purposes in
    ///         _registerAssetIfPossible: (1) fallback when an asset's Custom feed has no deployed
    ///         address (feed exists in code but not yet deployed to production); (2) override when a
    ///         prod address exists but has the old ERC165 ID (e.g. after latestRoundData() was added
    ///         to IPriceFeedCustom). Key is the feed deploy name from assets.json's `priceFeeds[].feed`,
    ///         resolved via ConfigReader.readAssetFeedName. Fork-only; production registration via
    ///         RegisterAssets.s.sol reads feeds from assets.json.
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
        vm.etch(LibraryPins.PRICE_FEED_LIB, priceFeedLibImpl.code);
        vm.etch(0x2F1F6c17D64bE96F583D390be212aFCF8D0F102a, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

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
        // constructors (e.g. ERC4626WrapBalanceAdapter) require the underlying asset to be
        // registered before they can deploy. Production deploy mirrors this via the Safe-TX
        // bundle ordering in 06_Configure.s.sol (registerAsset → addBalanceAdapter).
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
            _tryDeployPriceFeed("stETH", _deployStEth);
            _tryDeployPriceFeed("rETH", _deployREth);
            _tryDeployPriceFeed("cbETH", _deployCbEth);
            _tryDeployPriceFeed("weETH", _deployWeEth);
            _tryDeployPriceFeed("rsETH", _deployRsEth);
            _tryDeployPriceFeed("eETH", _deployEEth);
            _tryDeployPriceFeed("ezETH", _deployEzEth);
            _tryDeployPriceFeed("ETHx", _deployEthx);
            _tryDeployPriceFeed("osETH", _deployOsEth);
            _tryDeployPriceFeed("OETH", _deployOeth);
            _tryDeployPriceFeed("ankrETH", _deployAnkrEth);
            _tryDeployPriceFeed("NXM", _deployNxm);
            _tryDeployPriceFeed("wNXM", _deployWnxm);
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
            _tryDeployPriceFeed("osGNO", _deployOsGno);
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

    function _deployStEth() internal returns (address) {
        // stETH reuses the generic CrossRatePriceAdapter: stETH/USD = (ETH/USD) x (stETH/ETH).
        address underlying = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "stETH", "underlyingAsset"));
        address xToUsd = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "stETH", "xToUsdFeed"));
        address yToX = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "stETH", "yToXFeed"));
        uint256 xToUsdHb = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "stETH", "xToUsdHeartbeat"));
        uint256 yToXHb = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "stETH", "yToXHeartbeat"));
        return address(new CrossRatePriceAdapter(underlying, xToUsd, yToX, xToUsdHb, yToXHb));
    }

    function _deployREth() internal returns (address) {
        address rEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "rEth"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "ethToUsdChainlinkHeartbeat"));
        return address(new rETH_PriceOracle(rEth, ethUsd, ethUsdHb));
    }

    function _deployOeth() internal returns (address) {
        // OETH reuses the generic CrossRatePriceAdapter: OETH/USD = (ETH/USD) x (OETH/ETH).
        address underlying = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "underlyingAsset"));
        address xToUsd = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "xToUsdFeed"));
        address yToX = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "yToXFeed"));
        uint256 xToUsdHb = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "xToUsdHeartbeat"));
        uint256 yToXHb = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "yToXHeartbeat"));
        return address(new CrossRatePriceAdapter(underlying, xToUsd, yToX, xToUsdHb, yToXHb));
    }

    function _deployAnkrEth() internal returns (address) {
        address ankrEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ankrETH", "ankrEth"));
        address ethUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ankrETH", "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "ankrETH", "ethToUsdChainlinkHeartbeat"));
        return address(new ankrETH_PriceOracle(ankrEth, ethUsd, ethUsdHb));
    }

    function _deployNxm() internal returns (address) {
        return _deployNxmLike("NXM");
    }

    function _deployWnxm() internal returns (address) {
        return _deployNxmLike("wNXM");
    }

    /// @dev NXM and wNXM share one feed shape (RAMM book value); `name` selects the config + priced token.
    function _deployNxmLike(string memory name) internal returns (address) {
        address token = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "token"));
        address ramm = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "ramm"));
        address ethUsd = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "ethToUsdChainlinkOracle"));
        uint256 ethUsdHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, name, "ethToUsdChainlinkHeartbeat"));
        return address(new NXM_PriceOracle(token, ramm, ethUsd, ethUsdHb));
    }

    function _deployOsEth() internal returns (address) {
        return _deployOsToken("osETH");
    }

    function _deployOsGno() internal returns (address) {
        return _deployOsToken("osGNO");
    }

    function _deployOsToken(string memory name) internal returns (address) {
        address osToken = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "osToken"));
        address controller =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "osTokenVaultController"));
        address underlyingUsd =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "underlyingToUsdChainlinkOracle"));
        uint256 hb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, name, "underlyingToUsdChainlinkHeartbeat"));
        return address(new osToken_PriceOracle(osToken, controller, underlyingUsd, hb));
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
        if (_equals(name, "CompoundV3CometsMeta")) {
            return _deployCompoundV3CometsMeta(name, navAddr);
        }
        if (_equals(name, "SparkLend") || _startsWith(name, "SparkLend_")) {
            return _deploySparkLend(name, navAddr);
        }
        if (_equals(name, "MorphoMarketsMeta")) {
            return _deployMorphoMarketsMeta(name, navAddr);
        }
        if (_equals(name, "MorphoVaultsMeta")) {
            return _deployMorphoVaultsMeta(name, navAddr);
        }
        if (_startsWith(name, "ERC4626Wrap_")) {
            return _deployERC4626Wrap(name, navAddr);
        }
        if (_equals(name, "GearboxMarketsMeta")) {
            return _deployGearboxMarketsMeta(name, navAddr);
        }
        if (_equals(name, "Cap")) {
            return _deployCap(navAddr);
        }
        if (_equals(name, "CurvePoolsMeta")) {
            return _deployCurvePoolsMeta(name, navAddr);
        }
        if (_equals(name, "CurveGaugesMeta")) {
            return _deployCurveGaugesMeta(name, navAddr);
        }
        if (_equals(name, "ConvexRewardsMeta")) {
            return _deployConvexRewardsMeta(name, navAddr);
        }
        if (_equals(name, "AaveV3SafetyModule")) {
            return _deployAaveV3SafetyModule(name, navAddr);
        }
        if (_equals(name, "AaveUmbrella")) {
            return _deployAaveUmbrella(name, navAddr);
        }
        if (_equals(name, "BalancerV3PoolsMeta")) {
            return _deployBalancerV3PoolsMeta(name, navAddr);
        }
        if (_equals(name, "BalancerV3GaugesMeta")) {
            return _deployBalancerV3GaugesMeta(name, navAddr);
        }
        if (_equals(name, "BalancerV2PoolsMeta")) {
            return _deployBalancerV2PoolsMeta(name, navAddr);
        }
        if (_equals(name, "BalancerV2GaugesMeta")) {
            return _deployBalancerV2GaugesMeta(name, navAddr);
        }
        if (_equals(name, "MerklRewards")) {
            return _deployMerklRewards(name, navAddr);
        }
        if (_equals(name, "AaveV2InstancesMeta")) {
            return _deployAaveV2InstancesMeta(name, navAddr);
        }
        if (_equals(name, "FluidFTokensMeta")) {
            return _deployFluidFTokensMeta(name, navAddr);
        }
        if (_equals(name, "FluidVaultsMeta")) {
            return _deployFluidVaultsMeta(name, navAddr);
        }
        if (_equals(name, "StaderWithdrawalQueue")) {
            return _deployStaderWithdrawalQueue(name, navAddr);
        }
        if (_equals(name, "StakeWiseV3VaultsMeta")) {
            return _deployStakeWiseV3VaultsMeta(name, navAddr);
        }
        if (_equals(name, "UniswapV3PoolsMeta")) {
            return _deployUniswapV3PoolsMeta(name, navAddr);
        }
        if (_equals(name, "PancakeSwapV3PoolsMeta")) {
            return _deployPancakeSwapV3PoolsMeta(name, navAddr);
        }
        if (_equals(name, "UniswapV2PoolsMeta") || _equals(name, "PancakeSwapV2PoolsMeta")) {
            return _deployUniswapV2PoolsMeta(name, navAddr);
        }
        return address(0);
    }

    function _deployAaveV3(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        return address(new SparkLendBalanceAdapter(dataProvider, navAddr));
    }

    function _deploySparkLend(string memory name, address navAddr) internal returns (address) {
        address dataProvider =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "dataProvider"));
        return address(new SparkLendBalanceAdapter(dataProvider, navAddr));
    }

    function _deployCompoundV3CometsMeta(string memory name, address navAddr) internal returns (address) {
        address compoundRewards =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "compoundRewards"));
        address rewardToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewardToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new CompoundV3CometsMetaBalanceAdapter(compoundRewards, rewardToken, protocol, navAddr));
    }

    function _deployMorphoVaultsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MorphoVaultsMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployBalancerV3PoolsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new BalancerV3PoolsMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployBalancerV3GaugesMeta(string memory name, address navAddr) internal returns (address) {
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new BalancerV3GaugesMetaBalanceAdapter(balancerMinter, protocol, navAddr));
    }

    function _deployBalancerV2PoolsMeta(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new BalancerV2PoolsMetaBalanceAdapter(vault, protocol, navAddr));
    }

    function _deployBalancerV2GaugesMeta(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new BalancerV2GaugesMetaBalanceAdapter(vault, balancerMinter, protocol, navAddr));
    }

    function _deployMorphoMarketsMeta(string memory name, address navAddr) internal returns (address) {
        address morpho = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "morpho"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new MorphoMarketsMetaBalanceAdapter(morpho, protocol, navAddr));
    }

    function _deployAaveV3InstancesMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new AaveV3InstancesMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployERC4626Wrap(string memory name, address navAddr) internal returns (address) {
        address wrapper =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "wrapper"));
        return address(new ERC4626WrapBalanceAdapter(wrapper, navAddr));
    }

    function _deployGearboxMarketsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new GearboxMarketsMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployCap(address navAddr) internal returns (address) {
        address cUsd = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "cUsd"));
        address stcUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "stcUsd"));
        address usdc = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "Cap", "usdc"));
        return address(new CapBalanceAdapter(cUsd, stcUsd, usdc, navAddr));
    }

    function _deployCurvePoolsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new CurvePoolsMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployCurveGaugesMeta(string memory name, address navAddr) internal returns (address) {
        address minter = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "minter"));
        address crvToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "crvToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new CurveGaugesMetaBalanceAdapter(minter, crvToken, protocol, navAddr));
    }

    function _deployConvexRewardsMeta(string memory name, address navAddr) internal returns (address) {
        address booster =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "booster"));
        address cvxToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "cvxToken"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new ConvexRewardsMetaBalanceAdapter(booster, cvxToken, protocol, navAddr));
    }

    function _deployAaveV3SafetyModule(string memory name, address navAddr) internal returns (address) {
        return address(new AaveV3SafetyModuleBalanceAdapter(navAddr));
    }

    function _deployAaveUmbrella(string memory name, address navAddr) internal returns (address) {
        address rewardsController =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewardsController"));
        return address(new AaveUmbrellaBalanceAdapter(rewardsController, navAddr));
    }

    function _deployMerklRewards(string memory name, address navAddr) internal returns (address) {
        // The integration test owns the adapter (admin = msg.sender once we vm.startPrank(admin)) so
        // it can call submitProof during setup. Production deploys use chainConfig.admin instead — see
        // script/deploy/04_DeployBalanceAdapters.s.sol::_deployMerklRewards.
        address distributor =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "distributor"));
        address adapter = address(new MerklRewardsBalanceAdapter(distributor, navAddr, admin));
        _merklAdapter = adapter;
        return adapter;
    }

    function _deployAaveV2InstancesMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new AaveV2InstancesMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployFluidFTokensMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new FluidFTokensMetaBalanceAdapter(protocol, navAddr));
    }

    function _deployFluidVaultsMeta(string memory name, address navAddr) internal returns (address) {
        address vaultResolver =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vaultResolver"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new FluidVaultsMetaBalanceAdapter(vaultResolver, protocol, navAddr));
    }

    function _deployStaderWithdrawalQueue(string memory name, address navAddr) internal returns (address) {
        address userWithdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "userWithdrawalManager")
        );
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        return address(new StaderWithdrawalQueueBalanceAdapter(userWithdrawalManager, underlyingToken, navAddr));
    }

    function _deployStakeWiseV3VaultsMeta(string memory name, address navAddr) internal returns (address) {
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        address osTokenVaultController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "osTokenVaultController")
        );
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return
            address(new StakeWiseV3VaultsMetaBalanceAdapter(underlyingToken, osTokenVaultController, protocol, navAddr));
    }

    function _deployUniswapV3PoolsMeta(string memory name, address navAddr) internal returns (address) {
        address positionManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionManager"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new UniswapV3PoolsMetaBalanceAdapter(positionManager, protocol, navAddr));
    }

    function _deployPancakeSwapV3PoolsMeta(string memory name, address navAddr) internal returns (address) {
        address positionManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionManager"));
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        return address(new PancakeSwapV3PoolsMetaBalanceAdapter(positionManager, protocol, navAddr));
    }

    function _deployUniswapV2PoolsMeta(string memory name, address navAddr) internal returns (address) {
        string memory protocol = ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "protocol");
        if (_equals(name, "PancakeSwapV2PoolsMeta")) {
            return address(new PancakeSwapV2PoolsMetaBalanceAdapter(protocol, navAddr));
        }
        return address(new UniswapV2PoolsMetaBalanceAdapter(protocol, navAddr));
    }

    // -----------------------------------------------------------------------
    // Asset registration (uses assets.json adapter addresses verbatim — these
    // are either Chainlink feeds or fund-side Custom adapters already on chain).
    // -----------------------------------------------------------------------

    function _registerAllAssets() internal {
        string[] memory symbols = ConfigReader.getAssetSymbols(vm, _chainId);
        for (uint256 i = 0; i < symbols.length; i++) {
            _registerAssetIfPossible(symbols[i]);
        }
    }

    /// @notice Registers an asset and wires ALL of its configured price feeds: the first via registerAsset, any
    ///         additional via addPriceFeed (ADR 0009 redundancy). Custom feeds resolve to the in-test ephemeral
    ///         deployment (`_ephemeralPriceFeeds[<feed name>]`), since this harness deploys feeds in-memory rather
    ///         than from a deployments file. Chainlink/Redstone/API3 feeds use the static address from
    ///         `nav-config/assets-and-price-feeds/<chainId>.json`.
    function _registerAssetIfPossible(string memory symbol) internal {
        string memory addrStr = ConfigReader.readAssetAddress(vm, _chainId, symbol);
        if (bytes(addrStr).length == 0) return;
        address asset = vm.parseAddress(addrStr);
        if (asset == address(0)) return;

        uint256 feedCount = ConfigReader.assetFeedCount(vm, _chainId, symbol);
        bool registered = nav.isAssetRegistered(asset);

        for (uint256 i = 0; i < feedCount; i++) {
            string memory t = ConfigReader.readAssetFeedType(vm, _chainId, symbol, i);
            if (_equals(t, "None")) continue;
            // Shared type→enum mapping (ConfigReader.readAssetFeedPriceType — same table production RegisterAssets uses,
            // so the two can't disagree on which types are recognized). Fail fast on an unrecognized type.
            (IPrices.PriceType pt, bool validType) = ConfigReader.readAssetFeedPriceType(vm, _chainId, symbol, i);
            if (!validType) revert(string(abi.encodePacked("unknown price feed type '", t, "' for ", symbol)));

            address adapter;
            if (pt == IPrices.PriceType.Custom) {
                // Ephemeral (new-code) feed deployed in this harness, keyed by the configured feed name. Preferred
                // over any prod address because IPriceFeedCustom's ERC165 id changed (old deployments fail the check).
                adapter = _ephemeralPriceFeeds[ConfigReader.readAssetFeedName(vm, _chainId, symbol, i)];
            } else {
                string memory fa = ConfigReader.readAssetFeedAddress(vm, _chainId, symbol, i);
                if (bytes(fa).length > 0) adapter = vm.parseAddress(fa);
            }
            if (adapter == address(0)) continue;

            uint256 hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, _chainId, symbol, i));
            if (!registered) {
                try nav.registerAsset(asset, adapter, pt, hb) {
                    registered = true;
                    console2.log("[asset]", symbol, asset);
                } catch (bytes memory err) {
                    console2.log("[asset]", symbol, "REGISTER FAILED");
                    console2.logBytes(err);
                }
            } else {
                try nav.addPriceFeed(asset, adapter, pt, hb) {
                    console2.log("[asset/addFeed]", symbol, asset);
                } catch (bytes memory err) {
                    console2.log("[asset/addFeed]", symbol, "FAILED");
                    console2.logBytes(err);
                }
            }
        }
    }

    function _registerAllBalanceAdapters() internal {
        // Mirror production 06_Configure: route plain vs meta by which NAV-config file the adapter's name is in
        // (nav-config/balance-adapters vs nav-config/meta-balance-adapters), NOT by ERC165. Using the same source of
        // truth as production means a mis-filed adapter (meta name in the plain file, or vice-versa) fails here exactly
        // as it would in 06 — the registration reverts, the adapter is left unregistered, and the NAV assertion catches
        // it. An adapter in neither nav file is intentionally not registered (mirrors prod's deployed-but-not-added).
        for (uint256 i = 0; i < _deployedBalanceAdapters.length; i++) {
            address a = _deployedBalanceAdapters[i];
            string memory name = _deployedBalanceAdapterNames[i];
            bool isMeta = ConfigReader.isAdapterEnabled(vm, _chainId, "navMetaBalanceAdapters", name);
            // MerklRewards is force-deployed by this harness (independent of config, see _deployAllBalanceAdapters) to
            // exercise Merkl-reward NAV; it is a plain adapter not present in any nav-config file, so register it via
            // the plain path here to match that deploy-side special case.
            bool isPlain = ConfigReader.isAdapterEnabled(vm, _chainId, "navBalanceAdapters", name)
                || _equals(name, "MerklRewards");

            if (isMeta) {
                // Meta path: register with an empty set; _configureMetaInstances seeds the actual instances after.
                try nav.addMetaBalanceAdapter(a, new bytes32[](0)) {
                // ok
                }
                catch (bytes memory err) {
                    console2.log("[adapter] addMetaBalanceAdapter FAILED for", name, a);
                    console2.logBytes(err);
                }
            } else if (isPlain) {
                try nav.addBalanceAdapters(aa(a)) {
                // ok
                }
                catch (bytes memory err) {
                    console2.log("[adapter] addBalanceAdapters FAILED for", name, a);
                    console2.logBytes(err);
                }
            } else {
                console2.log("[adapter] not in any nav-config file, not registered:", name, a);
            }
        }
    }

    /// @notice Applies each meta-adapter's `metaInstances` config to NAVCalculator (ADR 0010). This is how the
    ///         NAV calculator is told which instances of a protocol to query — e.g. the Morpho-vault universe.
    /// @dev Runs after registration (addMetaInstances requires the adapter to be registered) and within the same
    ///      `admin` prank that holds MANAGER. Adapters with no `metaInstances` config are skipped.
    function _configureMetaInstances() internal {
        for (uint256 i = 0; i < _deployedBalanceAdapters.length; i++) {
            address a = _deployedBalanceAdapters[i];
            string memory name = _deployedBalanceAdapterNames[i];

            // Union address-keyed (`instances`, widened) + raw bytes32 (`instancesRaw`, e.g. marketIds) from the
            // meta-adapter NAV-config file (nav-config/meta-balance-adapters/<id>.json).
            address[] memory addrs =
                ConfigReader.readAdapterAddressArray(vm, _chainId, "navMetaBalanceAdapters", name, "instances");
            bytes32[] memory raw =
                ConfigReader.readAdapterBytes32Array(vm, _chainId, "navMetaBalanceAdapters", name, "instancesRaw");
            if (addrs.length + raw.length == 0) continue;

            bytes32[] memory instances = new bytes32[](addrs.length + raw.length);
            for (uint256 j = 0; j < addrs.length; j++) {
                instances[j] = bytes32(uint256(uint160(addrs[j])));
            }
            for (uint256 j = 0; j < raw.length; j++) {
                instances[addrs.length + j] = raw[j];
            }

            // No try/catch: the per-instance adapters are disabled in config, so a failed addMetaInstances must
            // fail the run loudly rather than silently omit the migrated positions from snapshots/asserts.
            nav.addMetaInstances(a, instances);
            console2.log("[meta] addMetaInstances", name, instances.length);
        }
    }

    /// @notice Pre-populates the MerklRewards adapter cache from `merkl-proofs.json` (regenerated on
    ///         every snapshot bump). Tolerant of missing/empty/stale fixtures: silently skips the
    ///         chain block if not present, logs and continues on per-entry verification failure.
    /// @dev    Called from setUp while vm.startPrank(admin) is active. Submitter must equal the
    ///         adapter's owner (set to `admin` in `_deployMerklRewards`).
    function _seedMerklProofs() internal {
        if (_merklAdapter == address(0)) return;
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
            address distributor = MerklRewardsBalanceAdapter(_merklAdapter).DISTRIBUTOR();
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
            try MerklRewardsBalanceAdapter(_merklAdapter).submitProof(users[i], tokens[i], amount, proof) {
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
    function _positionToJson(INAVCalculator.Position memory pos) internal view returns (string memory out) {
        // Attempt to read human-readable protocol name from the adapter.
        // Used by generate-comparison-report.py to map positions to DeBank protocol IDs.
        string memory protoName = "";
        try IPositionDescribable(pos.balanceAdapter).protocolName() returns (string memory n) {
            protoName = n;
        } catch {}

        out = string.concat(
            '{"symbol":"',
            pos.balanceAsset.symbol,
            '","address":"',
            vm.toString(pos.balanceAsset.asset),
            '","decimals":',
            vm.toString(uint256(pos.balanceAsset.decimals))
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
        out = string.concat(
            out,
            ',"protocolId":"',
            vm.toString(pos.protocolId),
            '","positionId":"',
            vm.toString(pos.positionId),
            '","positionKind":',
            vm.toString(uint256(uint8(pos.positionKind))),
            ',"protocolName":"',
            protoName,
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
