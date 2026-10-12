// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {UndispatchedAdapterGuard} from "test/integration/UndispatchedAdapterGuard.sol";
// NOTE: meta adapters take no display-name argument — `MetaBalanceAdapter.protocolName()` derives it from
// `_protocolId()`. This harness mirrors `04_DeployBalanceAdapters`, and both construct them with addresses only.
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";

// Balance adapters
import {
    CompoundV3CometsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/CompoundV3CometsMetaBalanceAdapter.sol";
import {SparkLendBalanceAdapter} from "src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol";
import {MorphoVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol";
import {
    AaveSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AaveSavingsWalletMetaBalanceAdapter.sol";
import {
    AnkrStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/AnkrStakedEthWalletMetaBalanceAdapter.sol";
import {
    CoinbaseStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/CoinbaseStakedEthWalletMetaBalanceAdapter.sol";
import {
    EthenaSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol";
import {
    EtherFiStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/EtherFiStakedEthWalletMetaBalanceAdapter.sol";
import {
    KelpRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/KelpRestakedEthWalletMetaBalanceAdapter.sol";
import {
    LidoStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LidoStakedEthWalletMetaBalanceAdapter.sol";
import {
    LiquidCollectiveStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/LiquidCollectiveStakedEthWalletMetaBalanceAdapter.sol";
import {
    MapleSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/MapleSavingsWalletMetaBalanceAdapter.sol";
import {
    NexusMutualVaultsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/NexusMutualVaultsWalletMetaBalanceAdapter.sol";
import {
    RenzoRestakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RenzoRestakedEthWalletMetaBalanceAdapter.sol";
import {
    ReserveBasketsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/ReserveBasketsWalletMetaBalanceAdapter.sol";
import {
    RocketPoolStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/RocketPoolStakedEthWalletMetaBalanceAdapter.sol";
import {
    SkySavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SkySavingsWalletMetaBalanceAdapter.sol";
import {
    SparkSavingsWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/SparkSavingsWalletMetaBalanceAdapter.sol";
import {
    StaderStakedEthWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StaderStakedEthWalletMetaBalanceAdapter.sol";
import {
    StakeWiseV3OsTokenWalletMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/walletYield/StakeWiseV3OsTokenWalletMetaBalanceAdapter.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";
import {InvertedChainlinkCustomPriceFeed} from "src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {
    AaveV3InstancesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {AaveV4SpokesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/AaveV4SpokesMetaBalanceAdapter.sol";
import {
    GearboxV3MarketsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol";
import {CapStablecoinBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapStablecoinBalanceAdapter.sol";
import {CapSavingsBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapSavingsBalanceAdapter.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {
    ConvexCurveLPStakingMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {AaveUmbrellaBalanceAdapter} from "src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {
    BalancerV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolsMetaBalanceAdapter.sol";
import {
    BalancerV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolsMetaBalanceAdapter.sol";
import {
    BalancerV2GaugesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2GaugesMetaBalanceAdapter.sol";
import {
    BalancerV3GaugesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV3GaugesMetaBalanceAdapter.sol";
import {FluidFTokensMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidFTokensMetaBalanceAdapter.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {KelpWithdrawalQueueBalanceAdapter} from "src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol";
import {
    StakeWiseV3VaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol";
import {PolygonStakingMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/PolygonStakingMetaBalanceAdapter.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {
    UniswapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV2PoolsMetaBalanceAdapter.sol";
import {
    PancakeSwapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol";

// Price feed adapters (Mainnet)
import {LDO_CustomPriceFeed} from "src/prices/protocols/LDO_CustomPriceFeed.sol";
import {sUSDS_CustomPriceFeed} from "src/prices/protocols/sUSDS_CustomPriceFeed.sol";
import {spUSDC_CustomPriceFeed} from "src/prices/protocols/spUSDC_CustomPriceFeed.sol";
import {spUSDT_CustomPriceFeed} from "src/prices/protocols/spUSDT_CustomPriceFeed.sol";
import {spETH_CustomPriceFeed} from "src/prices/protocols/spETH_CustomPriceFeed.sol";
import {sDAI_CustomPriceFeed} from "src/prices/protocols/sDAI_CustomPriceFeed.sol";
import {sUSDe_CustomPriceFeed} from "src/prices/protocols/sUSDe_CustomPriceFeed.sol";
import {syrupUSDC_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_CustomPriceFeed.sol";
import {sGHO_CustomPriceFeed} from "src/prices/protocols/sGHO_CustomPriceFeed.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";
import {OETH_CustomPriceFeed} from "src/prices/protocols/OETH_CustomPriceFeed.sol";
import {rETH_CustomPriceFeed} from "src/prices/protocols/rETH_CustomPriceFeed.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";
import {NXM_CustomPriceFeed} from "src/prices/protocols/NXM_CustomPriceFeed.sol";
import {osToken_CustomPriceFeed} from "src/prices/protocols/osToken_CustomPriceFeed.sol";
import {cbETH_CustomPriceFeed} from "src/prices/protocols/cbETH_CustomPriceFeed.sol";
import {weETH_CustomPriceFeed} from "src/prices/protocols/weETH_CustomPriceFeed.sol";
import {rsETH_CustomPriceFeed} from "src/prices/protocols/rsETH_CustomPriceFeed.sol";
import {eETH_CustomPriceFeed} from "src/prices/protocols/eETH_CustomPriceFeed.sol";
import {ezETH_CustomPriceFeed} from "src/prices/protocols/ezETH_CustomPriceFeed.sol";
import {ETHx_CustomPriceFeed} from "src/prices/protocols/ETHx_CustomPriceFeed.sol";
import {sXDAI_CustomPriceFeed} from "src/prices/protocols/sXDAI_CustomPriceFeed.sol";

// Price feed adapters (L2)
import {wstETH_L2_CustomPriceFeed} from "src/prices/protocols/wstETH_L2_CustomPriceFeed.sol";
import {weETH_L2_CustomPriceFeed} from "src/prices/protocols/weETH_L2_CustomPriceFeed.sol";
import {cbETH_L2_CustomPriceFeed} from "src/prices/protocols/cbETH_L2_CustomPriceFeed.sol";
import {rsETH_L2_CustomPriceFeed} from "src/prices/protocols/rsETH_L2_CustomPriceFeed.sol";
import {ezETH_L2_CustomPriceFeed} from "src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";
import {syrupUSDC_L2_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_L2_CustomPriceFeed.sol";

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

    /// @notice Tracked deployed adapter addresses (for diagnostics + addBalanceAdapter pass).
    address[] internal _deployedBalanceAdapters;

    /// @notice Every ephemerally-deployed price feed address (parallel purpose to
    ///         _ephemeralPriceFeeds, which is a name-keyed mapping and thus not iterable).
    ///         Used by the backtest harness to vm.makePersistent the whole stack.
    address[] internal _deployedPriceFeedAddresses;

    /// @notice Config names parallel to `_deployedBalanceAdapters` (used to read per-adapter config such as
    ///         a meta-adapter's `metaInstances` list after registration).
    string[] internal _deployedBalanceAdapterNames;

    /// @notice Maps feed name → ephemerally-deployed price feed address. Populated by
    ///         _tryDeployPriceFeed during _deployAllPriceFeeds. Serves two purposes in
    ///         _registerAssetIfPossible: (1) fallback when an asset's Custom feed has no deployed
    ///         address (feed exists in code but not yet deployed to production); (2) override when a
    ///         prod address exists but has the old ERC165 ID (e.g. after latestRoundData() was added
    ///         to ICustomPriceFeed). Key is the feed deploy name from assets.json's `priceFeeds[].feed`,
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
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

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
        // Asset registration MUST precede balance-adapter deployment because some adapters
        // require their underlying asset to be NAV-registered before they can value a
        // position. Production deploy mirrors this via the Safe-TX
        // bundle ordering in 06_Configure.s.sol (registerAsset → addBalanceAdapter).
        _registerAllAssets();
        _deployAllBalanceAdapters();
        _registerAllBalanceAdapters();
        _configureMetaInstances();
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
            _tryDeployPriceFeed("LDO", _deployLdo);
            _tryDeployPriceFeed("sUSDS", _deploySusds);
            _tryDeployPriceFeed("sUSDe", _deploySUsde);
            _tryDeployPriceFeed("sGHO", _deploySgho);
            _tryDeployPriceFeed("wARS", _deployWars);
            _tryDeployPriceFeed("syrupUSDC", _deploySyrupUsdc);
            _tryDeployPriceFeed("spUSDC", _deploySpUsdc);
            _tryDeployPriceFeed("spUSDT", _deploySpUsdt);
            _tryDeployPriceFeed("spETH", _deploySpEth);
            _tryDeployPriceFeed("sDAI", _deploySDai);
            _tryDeployPriceFeed("wstETH", _deployWstEth);
            _tryDeployPriceFeed("stETHFundamental", _deployStEthFundamental);
            _tryDeployPriceFeed("stETHCrossRate", _deployStEthCrossRate);
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
        _deployedPriceFeedAddresses.push(addr);
        console2.log("[priceFeed]", name, addr);
    }

    function _deployLdo() internal returns (address) {
        address ldo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ldo"));
        address ldoEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ldoToEthChainlinkAddress"));
        uint256 ldoEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "ldoToEthChainlinkHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "LDO", "baseAsset"));
        return address(new LDO_CustomPriceFeed(ldo, ldoEth, ldoEthHb, address(nav), baseAsset));
    }

    function _deploySusds() internal returns (address) {
        address sUsds = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDS", "sUsds"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDS", "baseAsset"));
        return address(new sUSDS_CustomPriceFeed(sUsds, address(nav), baseAsset));
    }

    function _deploySpUsdc() internal returns (address) {
        address spUsdc = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "spUSDC", "spUsdc"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "spUSDC", "baseAsset"));
        return address(new spUSDC_CustomPriceFeed(spUsdc, address(nav), baseAsset));
    }

    function _deploySpUsdt() internal returns (address) {
        address spUsdt = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "spUSDT", "spUsdt"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "spUSDT", "baseAsset"));
        return address(new spUSDT_CustomPriceFeed(spUsdt, address(nav), baseAsset));
    }

    function _deploySpEth() internal returns (address) {
        address spEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "spETH", "spEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "spETH", "baseAsset"));
        return address(new spETH_CustomPriceFeed(spEth, address(nav), baseAsset));
    }

    function _deploySDai() internal returns (address) {
        address sDai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sDAI", "sDai"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sDAI", "baseAsset"));
        return address(new sDAI_CustomPriceFeed(sDai, address(nav), baseAsset));
    }

    function _deploySUsde() internal returns (address) {
        address sUsde = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDe", "sUsde"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sUSDe", "baseAsset"));
        return address(new sUSDe_CustomPriceFeed(sUsde, address(nav), baseAsset));
    }

    function _deploySgho() internal returns (address) {
        address sgho = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sGHO", "sgho"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sGHO", "baseAsset"));
        return address(new sGHO_CustomPriceFeed(sgho, address(nav), baseAsset));
    }

    /// @dev wARS via {InvertedChainlinkCustomPriceFeed}. A Custom price feed that is NOT dispatched here is
    ///      skipped in TOTAL SILENCE — `_registerAssetIfPossible` reads `_ephemeralPriceFeeds[name]`, gets
    ///      `address(0)` and `continue`s with no console line and no revert. There is no
    ///      `UndispatchedAdapterGuard` equivalent on this side, so unlike a balance adapter the omission
    ///      does not fail closed: the asset is simply never registered, every holding of it values at $0,
    ///      and `refresh-integration-snapshot.sh` would pin that under-report as the expected NAV.
    ///      **Scope of what this actually buys, stated honestly:** NO chain-1 fixture holds wARS today
    ///      (checked on-chain across all 14 accounts), so this arm currently deploys and registers the feed
    ///      but VALUES nothing through it. It removes the hazard for the day a fixture does hold wARS —
    ///      which is exactly when a silent omission would otherwise be pinned — and it is not a substitute
    ///      for the dedicated unit and fork suites, which are where this feed's real coverage lives.
    function _deployWars() internal returns (address) {
        address underlying = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wARS", "underlyingAsset"));
        address usdToAssetFeed =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wARS", "usdToAssetChainlinkAddress"));
        uint256 heartbeat =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wARS", "usdToAssetChainlinkHeartbeat"));
        uint256 minAnswer = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wARS", "minAnswer"));
        uint256 maxAnswer = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wARS", "maxAnswer"));
        return
            address(new InvertedChainlinkCustomPriceFeed(underlying, usdToAssetFeed, heartbeat, minAnswer, maxAnswer));
    }

    function _deploySyrupUsdc() internal returns (address) {
        address syrup = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC", "syrupUsdc"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC", "baseAsset"));
        return address(new syrupUSDC_CustomPriceFeed(syrup, address(nav), baseAsset));
    }

    function _deployWstEth() internal returns (address) {
        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "wstEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH", "baseAsset"));
        return address(new wstETH_CustomPriceFeed(wstEth, address(nav), baseAsset));
    }

    /// @notice stETH divergence MONITOR: the former market primary, demoted. Deploys the GENERIC
    ///         CrossRateCustomPriceFeed — the same contract `03_DeployPriceFeeds._deployCrossRateMonitor` ships —
    ///         rather than the named stETH_CustomPriceFeed subclass, so this fork test exercises the bytecode that
    ///         will actually be deployed. The two are behaviourally identical (the subclass is a constructor-only
    ///         pass-through with no overrides), but they are distinct artifacts to `preflight/bytecode_audit.py`.
    function _deployStEthCrossRate() internal returns (address) {
        string memory k = "stETHCrossRate";
        address underlying = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, k, "underlyingAsset"));
        address yToX = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, k, "yToXFeed"));
        uint256 yToXHb = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, k, "yToXHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, k, "baseAsset"));
        return address(new CrossRateCustomPriceFeed(underlying, yToX, yToXHb, address(nav), baseAsset));
    }

    function _deployREth() internal returns (address) {
        address rEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "rEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rETH", "baseAsset"));
        return address(new rETH_CustomPriceFeed(rEth, address(nav), baseAsset));
    }

    function _deployOeth() internal returns (address) {
        // OETH/USD = (OETH/ETH) x (ETH/USD), via the dedicated OETH_CustomPriceFeed (a CrossRate subclass).
        address underlying = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "underlyingAsset"));
        address yToX = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "yToXFeed"));
        uint256 yToXHb = vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "yToXHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "OETH", "baseAsset"));
        return address(new OETH_CustomPriceFeed(underlying, yToX, yToXHb, address(nav), baseAsset));
    }

    function _deployAnkrEth() internal returns (address) {
        address ankrEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ankrETH", "ankrEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ankrETH", "baseAsset"));
        return address(new ankrETH_CustomPriceFeed(ankrEth, address(nav), baseAsset));
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "baseAsset"));
        return address(new NXM_CustomPriceFeed(token, ramm, address(nav), baseAsset));
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
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "baseAsset"));
        return address(new osToken_CustomPriceFeed(osToken, controller, address(nav), baseAsset));
    }

    function _deployCbEth() internal returns (address) {
        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH", "cbEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH", "baseAsset"));
        return address(new cbETH_CustomPriceFeed(cbEth, address(nav), baseAsset));
    }

    function _deployWeEth() internal returns (address) {
        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "weEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH", "baseAsset"));
        return address(new weETH_CustomPriceFeed(weEth, address(nav), baseAsset));
    }

    function _deployRsEth() internal returns (address) {
        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "rsEth"));
        address rateProvider = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "rateProvider"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH", "baseAsset"));
        return address(new rsETH_CustomPriceFeed(rsEth, rateProvider, address(nav), baseAsset));
    }

    /// @notice Unit-rate `eETH_CustomPriceFeed` (`_rate()` == 1e18) for a given config key. Two assets use this
    ///         shape: eETH itself, and stETH's fundamental primary (stETH/ETH held at 1.0, as for wstETH/eETH).
    function _deployUnitRateFeed(string memory name) internal returns (address) {
        address token = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "eEth"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, name, "baseAsset"));
        return address(new eETH_CustomPriceFeed(token, address(nav), baseAsset));
    }

    function _deployEEth() internal returns (address) {
        return _deployUnitRateFeed("eETH");
    }

    function _deployStEthFundamental() internal returns (address) {
        return _deployUnitRateFeed("stETHFundamental");
    }

    function _deployEzEth() internal returns (address) {
        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "ezEth"));
        address restakeManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "restakeManager"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH", "baseAsset"));
        return address(new ezETH_CustomPriceFeed(ezEth, restakeManager, address(nav), baseAsset));
    }

    function _deploySxdai() internal returns (address) {
        address sXdai = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sXDAI", "sXdai"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "sXDAI", "baseAsset"));
        return address(new sXDAI_CustomPriceFeed(sXdai, address(nav), baseAsset));
    }

    function _deployWstEthL2() internal returns (address) {
        address wstEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "wstEth"));
        address wstEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "wstEthToEthChainlink"));
        uint256 wstEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "wstEthToEthHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "wstETH_L2", "baseAsset"));
        return address(new wstETH_L2_CustomPriceFeed(wstEth, wstEthEth, wstEthEthHb, address(nav), baseAsset));
    }

    function _deployWeEthL2() internal returns (address) {
        address weEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "weEth"));
        address weEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "weEthToEethChainlink"));
        uint256 weEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "weEthToEethHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "weETH_L2", "baseAsset"));
        return address(new weETH_L2_CustomPriceFeed(weEth, weEthEth, weEthEthHb, address(nav), baseAsset));
    }

    function _deployCbEthL2() internal returns (address) {
        address cbEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "cbEth"));
        address cbEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "cbEthToEthChainlink"));
        uint256 cbEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "cbEthToEthHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "cbETH_L2", "baseAsset"));
        return address(new cbETH_L2_CustomPriceFeed(cbEth, cbEthEth, cbEthEthHb, address(nav), baseAsset));
    }

    function _deployRsEthL2() internal returns (address) {
        address rsEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "rsEth"));
        address rsEthEth =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "rsEthToEthChainlink"));
        uint256 rsEthEthHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "rsEthToEthHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "rsETH_L2", "baseAsset"));
        return address(new rsETH_L2_CustomPriceFeed(rsEth, rsEthEth, rsEthEthHb, address(nav), baseAsset));
    }

    function _deployEzEthL2() internal returns (address) {
        address ezEth = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "ezEth"));
        address xRenzo = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "xRenzoDeposit"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ezETH_L2", "baseAsset"));
        return address(new ezETH_L2_CustomPriceFeed(ezEth, xRenzo, address(nav), baseAsset));
    }

    function _deploySyrupUsdcL2() internal returns (address) {
        address syrup = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "syrupUsdc"));
        address syrupChainlink =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "syrupUsdcToUsdcChainlink"));
        uint256 syrupHb =
            vm.parseUint(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "syrupUsdcToUsdcHeartbeat"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "syrupUSDC_L2", "baseAsset"));
        return address(new syrupUSDC_L2_CustomPriceFeed(syrup, syrupChainlink, syrupHb, address(nav), baseAsset));
    }

    function _deployEthx() internal returns (address) {
        address ethx = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "ethx"));
        address stakePoolsManager =
            vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "stakePoolsManager"));
        address baseAsset = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, _chainId, "ETHx", "baseAsset"));
        return address(new ETHx_CustomPriceFeed(ethx, stakePoolsManager, address(nav), baseAsset));
    }

    // -----------------------------------------------------------------------
    // Balance adapter deployment
    // -----------------------------------------------------------------------

    /// @dev An enabled adapter that `_deployBalanceAdapter` does not resolve is collected rather than merely
    ///      logged, and the collected set is checked against the declaration in
    ///      `test/integration/undispatched-adapters.json` — see {UndispatchedAdapterGuard} for why a bare
    ///      console line was unsafe (a never-deployed adapter reports 0, which a snapshot refresh then pins as
    ///      the expected NAV).
    function _deployAllBalanceAdapters() internal {
        string[] memory names = ConfigReader.getEnabledAdapters(vm, _chainId, "balanceAdapters");
        string[] memory undispatched = new string[](names.length);
        uint256 undispatchedCount;
        for (uint256 i = 0; i < names.length; i++) {
            string memory n = names[i];
            if (!ConfigReader.isAdapterEnabled(vm, _chainId, "balanceAdapters", n)) {
                continue;
            }
            address adapter = _deployBalanceAdapter(n);
            if (adapter == address(0)) {
                console2.log("[balanceAdapter] SKIP (undispatched; must be declared):", n);
                undispatched[undispatchedCount++] = n;
                continue;
            }
            _deployedBalanceAdapters.push(adapter);
            _deployedBalanceAdapterNames.push(n);
            console2.log("[balanceAdapter]", n, adapter);
        }

        string[] memory skipped = new string[](undispatchedCount);
        for (uint256 i = 0; i < undispatchedCount; i++) {
            skipped[i] = undispatched[i];
        }
        UndispatchedAdapterGuard.check(vm, _chainId, skipped);
    }

    function _deployBalanceAdapter(string memory name) internal returns (address) {
        address navAddr = address(nav);
        if (_equals(name, "AaveV3InstancesMeta")) {
            return _deployAaveV3InstancesMeta(name, navAddr);
        }
        if (_equals(name, "AaveV4SpokesMeta")) {
            return _deployAaveV4SpokesMeta(name, navAddr);
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
        // Wallet-held yield tokens (ADR 0010). DISPATCHED rather than declared in
        // `undispatched-adapters.json`, on the grounds this file already states for SymbioticVaultsMeta: the
        // constructor is a bare `(navAddr)`, so dispatching is cheap, and it permanently removes the hazard
        // the declaration file describes. Here that hazard is narrower than usual — undispatched, each token
        // stays armed on `ERC20DefaultBalanceAdapter` and reports the same `balanceOf`, so `navUsd8dp` would
        // not move — but what a declaration WOULD lose is identity coverage: the harness would never exercise
        // the wallet -> protocol reclassification this PR exists to perform.
        {
            address wy = _deployWalletYieldMeta(name, navAddr);
            if (wy != address(0)) return wy;
        }

        if (_equals(name, "MorphoVaultsMeta")) {
            return _deployMorphoVaultsMeta(name, navAddr);
        }
        if (_equals(name, "SymbioticVaultsMeta")) {
            return _deploySymbioticVaultsMeta(name, navAddr);
        }
        if (_equals(name, "GearboxV3MarketsMeta")) {
            return _deployGearboxV3MarketsMeta(name, navAddr);
        }
        if (_equals(name, "CapStablecoin")) {
            return _deployCapStablecoin(navAddr);
        }
        if (_equals(name, "CapSavings")) {
            return _deployCapSavings(navAddr);
        }
        if (_equals(name, "CurvePoolsMeta")) {
            return _deployCurvePoolsMeta(name, navAddr);
        }
        if (_equals(name, "CurveGaugesMeta")) {
            return _deployCurveGaugesMeta(name, navAddr);
        }
        if (_equals(name, "ConvexCurveLPStakingMeta")) {
            return _deployConvexCurveLPStakingMeta(name, navAddr);
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
        if (_equals(name, "FluidFTokensMeta")) {
            return _deployFluidFTokensMeta(name, navAddr);
        }
        if (_equals(name, "FluidVaultsMeta")) {
            return _deployFluidVaultsMeta(name, navAddr);
        }
        if (_equals(name, "StaderWithdrawalQueue")) {
            return _deployStaderWithdrawalQueue(name, navAddr);
        }
        if (_equals(name, "KelpWithdrawalQueue")) {
            return _deployKelpWithdrawalQueue(name, navAddr);
        }
        if (_equals(name, "StakeWiseV3VaultsMeta")) {
            return _deployStakeWiseV3VaultsMeta(name, navAddr);
        }

        if (_equals(name, "PolygonStakingMeta")) {
            return _deployPolygonStakingMeta(name, navAddr);
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
        return address(new CompoundV3CometsMetaBalanceAdapter(compoundRewards, rewardToken, navAddr));
    }

    function _deployMorphoVaultsMeta(string memory, address navAddr) internal returns (address) {
        return address(new MorphoVaultsMetaBalanceAdapter(navAddr));
    }

    /// @dev One member of the wallet-held yield-token family, or address(0) if `name` is not one. Returning
    ///      zero for a non-member is what lets the caller keep a single delegation instead of seventeen
    ///      branches; it cannot be confused with a failed deploy, because `new` reverts rather than
    ///      returning zero.
    function _deployWalletYieldMeta(string memory name, address navAddr) internal returns (address) {
        if (_equals(name, "AaveSavingsWalletMeta")) return address(new AaveSavingsWalletMetaBalanceAdapter(navAddr));
        if (_equals(name, "AnkrStakedEthWalletMeta")) {
            return address(new AnkrStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "CoinbaseStakedEthWalletMeta")) {
            return address(new CoinbaseStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "EthenaSavingsWalletMeta")) {
            return address(new EthenaSavingsWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "EtherFiStakedEthWalletMeta")) {
            return address(new EtherFiStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "KelpRestakedEthWalletMeta")) {
            return address(new KelpRestakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "LidoStakedEthWalletMeta")) {
            return address(new LidoStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "LiquidCollectiveStakedEthWalletMeta")) {
            return address(new LiquidCollectiveStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "MapleSavingsWalletMeta")) return address(new MapleSavingsWalletMetaBalanceAdapter(navAddr));
        if (_equals(name, "NexusMutualVaultsWalletMeta")) {
            return address(new NexusMutualVaultsWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "RenzoRestakedEthWalletMeta")) {
            return address(new RenzoRestakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "ReserveBasketsWalletMeta")) {
            return address(new ReserveBasketsWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "RocketPoolStakedEthWalletMeta")) {
            return address(new RocketPoolStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "SkySavingsWalletMeta")) return address(new SkySavingsWalletMetaBalanceAdapter(navAddr));
        if (_equals(name, "SparkSavingsWalletMeta")) return address(new SparkSavingsWalletMetaBalanceAdapter(navAddr));
        if (_equals(name, "StaderStakedEthWalletMeta")) {
            return address(new StaderStakedEthWalletMetaBalanceAdapter(navAddr));
        }
        if (_equals(name, "StakeWiseV3OsTokenWalletMeta")) {
            return address(new StakeWiseV3OsTokenWalletMetaBalanceAdapter(navAddr));
        }
        return address(0);
    }

    /// @dev Dispatched rather than declared in `undispatched-adapters.json`. No fixture holds a Symbiotic
    ///      position today, so an exemption would be defensible on the same grounds as EulerVaultsMeta —
    ///      but the constructor is a bare `(navAddr)`, so dispatching costs three lines and permanently
    ///      removes the hazard that file describes (a skipped meta-adapter reports 0, is indistinguishable
    ///      from "holds nothing", and a snapshot refresh in that state PINS the under-report). The KPK Safe
    ///      holds a real, material LiquidLane position, so this would become live the moment such an
    ///      account is added as a fixture.
    function _deploySymbioticVaultsMeta(string memory, address navAddr) internal returns (address) {
        return address(new SymbioticVaultsMetaBalanceAdapter(navAddr));
    }

    function _deployBalancerV3PoolsMeta(string memory, address navAddr) internal returns (address) {
        return address(new BalancerV3PoolsMetaBalanceAdapter(navAddr));
    }

    function _deployBalancerV3GaugesMeta(string memory name, address navAddr) internal returns (address) {
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        return address(new BalancerV3GaugesMetaBalanceAdapter(balancerMinter, navAddr));
    }

    function _deployBalancerV2PoolsMeta(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        return address(new BalancerV2PoolsMetaBalanceAdapter(vault, navAddr));
    }

    function _deployBalancerV2GaugesMeta(string memory name, address navAddr) internal returns (address) {
        address vault = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vault"));
        address balancerMinter =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "balancerMinter"));
        return address(new BalancerV2GaugesMetaBalanceAdapter(vault, balancerMinter, navAddr));
    }

    function _deployMorphoMarketsMeta(string memory name, address navAddr) internal returns (address) {
        address morpho = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "morpho"));
        return address(new MorphoMarketsMetaBalanceAdapter(morpho, navAddr));
    }

    function _deployAaveV3InstancesMeta(string memory, address navAddr) internal returns (address) {
        return address(new AaveV3InstancesMetaBalanceAdapter(navAddr));
    }

    /// @dev Meta-adapter: the Spoke set comes from `_configureMetaInstances` (nav-config `instances`); reserves
    ///      inside a Spoke are enumerated on-chain by numeric id, so nothing else needs seeding.
    function _deployAaveV4SpokesMeta(string memory, address navAddr) internal returns (address) {
        return address(new AaveV4SpokesMetaBalanceAdapter(navAddr));
    }

    function _deployGearboxV3MarketsMeta(string memory, address navAddr) internal returns (address) {
        return address(new GearboxV3MarketsMetaBalanceAdapter(navAddr));
    }

    function _deployCapStablecoin(address navAddr) internal returns (address) {
        address cUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "CapStablecoin", "cUsd"));
        address usdc =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "CapStablecoin", "usdc"));
        return address(new CapStablecoinBalanceAdapter(cUsd, usdc, navAddr));
    }

    function _deployCapSavings(address navAddr) internal returns (address) {
        address cUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "CapSavings", "cUsd"));
        address stcUsd =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "CapSavings", "stcUsd"));
        address usdc =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", "CapSavings", "usdc"));
        return address(new CapSavingsBalanceAdapter(cUsd, stcUsd, usdc, navAddr));
    }

    function _deployCurvePoolsMeta(string memory, address navAddr) internal returns (address) {
        return address(new CurvePoolsMetaBalanceAdapter(navAddr));
    }

    function _deployCurveGaugesMeta(string memory name, address navAddr) internal returns (address) {
        address minter = vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "minter"));
        address crvToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "crvToken"));
        return address(new CurveGaugesMetaBalanceAdapter(minter, crvToken, navAddr));
    }

    function _deployConvexCurveLPStakingMeta(string memory name, address navAddr) internal returns (address) {
        address booster =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "booster"));
        address cvxToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "cvxToken"));
        return address(new ConvexCurveLPStakingMetaBalanceAdapter(booster, cvxToken, navAddr));
    }

    function _deployAaveV3SafetyModule(string memory, address navAddr) internal returns (address) {
        return address(new AaveV3SafetyModuleBalanceAdapter(navAddr));
    }

    function _deployAaveUmbrella(string memory name, address navAddr) internal returns (address) {
        address rewardsController =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "rewardsController"));
        return address(new AaveUmbrellaBalanceAdapter(rewardsController, navAddr));
    }

    function _deployFluidFTokensMeta(string memory, address navAddr) internal returns (address) {
        return address(new FluidFTokensMetaBalanceAdapter(navAddr));
    }

    function _deployFluidVaultsMeta(string memory name, address navAddr) internal returns (address) {
        address vaultResolver =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "vaultResolver"));
        return address(new FluidVaultsMetaBalanceAdapter(vaultResolver, navAddr));
    }

    function _deployStaderWithdrawalQueue(string memory name, address navAddr) internal returns (address) {
        address userWithdrawalManager = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "userWithdrawalManager")
        );
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        return address(new StaderWithdrawalQueueBalanceAdapter(userWithdrawalManager, underlyingToken, navAddr));
    }

    function _deployKelpWithdrawalQueue(string memory name, address navAddr) internal returns (address) {
        address withdrawalManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "withdrawalManager"));
        return address(new KelpWithdrawalQueueBalanceAdapter(withdrawalManager, navAddr));
    }

    function _deployStakeWiseV3VaultsMeta(string memory name, address navAddr) internal returns (address) {
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        address osTokenVaultController = vm.parseAddress(
            ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "osTokenVaultController")
        );
        return address(new StakeWiseV3VaultsMetaBalanceAdapter(underlyingToken, osTokenVaultController, navAddr));
    }

    function _deployPolygonStakingMeta(string memory name, address navAddr) internal returns (address) {
        address underlyingToken =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "underlyingToken"));
        return address(new PolygonStakingMetaBalanceAdapter(underlyingToken, navAddr));
    }

    function _deployUniswapV3PoolsMeta(string memory name, address navAddr) internal returns (address) {
        address positionManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionManager"));
        // Meta-adapter: pool set configured via _configureMetaInstances (nav-config instances). NFTs are
        // enumerated on-chain, so no assistant/tokenId seeding is needed.
        return address(new UniswapV3PoolsMetaBalanceAdapter(positionManager, navAddr));
    }

    function _deployPancakeSwapV3PoolsMeta(string memory name, address navAddr) internal returns (address) {
        address positionManager =
            vm.parseAddress(ConfigReader.readAdapterParam(vm, _chainId, "balanceAdapters", name, "positionManager"));
        return address(new PancakeSwapV3PoolsMetaBalanceAdapter(positionManager, navAddr));
    }

    function _deployUniswapV2PoolsMeta(string memory name, address navAddr) internal returns (address) {
        if (_equals(name, "PancakeSwapV2PoolsMeta")) {
            return address(new PancakeSwapV2PoolsMetaBalanceAdapter(navAddr));
        }
        return address(new UniswapV2PoolsMetaBalanceAdapter(navAddr));
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
                // over any prod address because ICustomPriceFeed's ERC165 id changed (old deployments fail the check).
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
                try nav.addOrModifyPriceFeed(asset, adapter, pt, hb) {
                    console2.log("[asset/addFeed]", symbol, asset);
                } catch (bytes memory err) {
                    console2.log("[asset/addFeed]", symbol, "FAILED");
                    console2.logBytes(err);
                }
            }
        }

        if (registered) _wireDivergence(symbol, asset);
    }

    /// @notice Wires an asset's divergence/peg tolerances and monitor feeds (mirrors production RegisterAssets).
    ///         setDivergenceTolerance MUST precede addMonitorFeed. Custom monitors resolve to the in-test ephemeral
    ///         deployment; other types use the static config address.
    function _wireDivergence(string memory symbol, address asset) internal {
        uint256 divTol = ConfigReader.readAssetDivergenceToleranceBps(vm, _chainId, symbol);
        uint256 pegTol = ConfigReader.readAssetPegToleranceBps(vm, _chainId, symbol);
        uint256 monCount = ConfigReader.assetMonitorFeedCount(vm, _chainId, symbol);

        if (monCount > 0 && divTol > 0) {
            try nav.setDivergenceTolerance(asset, uint32(divTol)) {} catch {}
        }
        if (pegTol > 0) {
            try nav.setPegTolerance(asset, uint32(pegTol)) {} catch {}
        }

        for (uint256 i = 0; i < monCount; i++) {
            (IPrices.PriceType pt, bool validType) = ConfigReader.readAssetMonitorFeedPriceType(vm, _chainId, symbol, i);
            if (!validType) continue;

            address adapter;
            if (pt == IPrices.PriceType.Custom) {
                adapter = _ephemeralPriceFeeds[ConfigReader.readAssetMonitorFeedName(vm, _chainId, symbol, i)];
            } else {
                string memory fa = ConfigReader.readAssetMonitorFeedAddress(vm, _chainId, symbol, i);
                if (bytes(fa).length > 0) adapter = vm.parseAddress(fa);
            }
            if (adapter == address(0)) continue;

            uint256 hb = vm.parseUint(ConfigReader.readAssetMonitorFeedHeartbeat(vm, _chainId, symbol, i));
            try nav.addMonitorFeed(asset, adapter, pt, hb) {
                console2.log("[asset/addMonitor]", symbol, adapter);
            } catch (bytes memory err) {
                console2.log("[asset/addMonitor]", symbol, "FAILED");
                console2.logBytes(err);
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
            bool isPlain = ConfigReader.isAdapterEnabled(vm, _chainId, "navBalanceAdapters", name);

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

    /// @notice Marks the entire locally-deployed NAV stack persistent so it survives
    ///         vm.rollFork sweeps (backtest harness). Covers proxy, etched libraries,
    ///         every balance adapter, and every ephemeral price feed.
    function _makeStackPersistent() internal {
        address[] memory stack = _persistentStackAddresses();
        for (uint256 i = 0; i < stack.length; i++) {
            vm.makePersistent(stack[i]);
        }
    }

    /// @notice Every locally-deployed or etched address the NAV read path touches, i.e. exactly the
    ///         set that must survive a `vm.rollFork`. Kept as one enumerable list rather than a
    ///         sequence of `makePersistent` calls so a caller can re-assert code presence after a
    ///         roll (see `NavBacktest._assertStackPersistent`) against the same source of truth —
    ///         otherwise an address added here but forgotten there reverts every read and the
    ///         backtest records it as protocol instability.
    function _persistentStackAddresses() internal view returns (address[] memory stack) {
        uint256 fixedCount = 5;
        stack = new address[](fixedCount + _deployedBalanceAdapters.length + _deployedPriceFeedAddresses.length);
        stack[0] = address(nav);
        stack[1] = Upgrades.getImplementationAddress(address(nav));
        stack[2] = nav.erc20DefaultBalanceAdapter(); // deployed inside initialize, not in _deployedBalanceAdapters
        stack[3] = LibraryPins.PRICE_FEED_LIB;
        stack[4] = LibraryPins.NAV_REGISTRY_LIB;
        uint256 next = fixedCount;
        for (uint256 i = 0; i < _deployedBalanceAdapters.length; i++) {
            stack[next++] = _deployedBalanceAdapters[i];
        }
        for (uint256 i = 0; i < _deployedPriceFeedAddresses.length; i++) {
            stack[next++] = _deployedPriceFeedAddresses[i];
        }
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
    function _buildAccountPositionsJson() internal view returns (string memory out) {
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
    function test_emitSnapshots() public virtual {
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

    /// @notice Writes the per-chain nav-positions snapshot — ONLY when explicitly opted in.
    /// @dev **Gated because the target is a COMMITTED expected-value fixture.** `test_emitSnapshots` is a
    ///      normally-registered test, so before this gate every `forge test` run that touched an integration
    ///      contract rewrote `test/integration/nav-positions-<chainId>.json` in place. All six of those files are
    ///      tracked, so a session that ran the fork suite and then committed silently picked up a snapshot
    ///      mutation it never authored — into a file whose whole purpose is to be a stable reference. The
    ///      failure mode is silent: the run passes, `git status` is dirty afterwards rather than before, and the
    ///      diff looks like a legitimate refresh.
    ///
    ///      ADR 0003 recorded this as "a cheap, harmless side path". The cost analysis was right and the
    ///      harmlessness was not: emitting `SNAPSHOT|…` lines to stdout genuinely is free of side effects, but
    ///      the file write is not, and the two were bundled into one ungated test.
    ///
    ///      Gate rather than remove, because the refresh workflow needs exactly this code path:
    ///      `refresh-integration-snapshot.sh` invokes it via `--match-test test_emitSnapshots` (a `forge script`
    ///      cannot be used — it hangs on Mainnet, see docs/howto/refresh-integration-test-blocks.md). The script
    ///      sets `REFRESH_NAV_POSITIONS=1`; nothing else does, so a normal run now leaves the tree as it found
    ///      it. Follows the existing `PERSIST_DEPLOYMENTS` convention for an opt-in write.
    function _emitNavPositionsForCurrentChain() internal {
        if (!vm.envOr("REFRESH_NAV_POSITIONS", false)) return;
        vm.writeFile(
            string.concat("test/integration/nav-positions-", vm.toString(_chainId), ".json"),
            string.concat(
                '{"chainId":',
                vm.toString(_chainId),
                ',"forkBlock":',
                vm.toString(_forkBlock),
                ',"accounts":',
                _buildAccountPositionsJson(),
                "}"
            )
        );
    }
}
