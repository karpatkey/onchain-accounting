// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {MANAGER, NAV_DECIMALS} from "src/constants.sol";

/// Vigilo PoC (PR #354 / ADR 0029): an OLD (origin/main) NavBaseUsdLib-based feed that is still registered when the
/// NEW PriceFeedLib is live reports a derived asset FRESH while its base is genuinely stale, whenever the L2 sequencer
/// is down / in grace. Old lib: `baseStale = pd.stale && !pd.sequencerDown` relied on a stale selection returning
/// price 0; the new library keeps the stale price, so the old feed's un-fold now launders the staleness away.

interface INavAdmin {
    function initialize(address admin_, address seqFeed, string memory sym) external;
    function grantRole(bytes32 role, address account) external;
    function registerAsset(address asset, address priceFeed, IPrices.PriceType priceType, uint256 hb) external;
    function addOrModifyPriceFeed(address asset, address priceFeed, IPrices.PriceType priceType, uint256 hb) external;
    function setChainlinkL2SequencerUptimeFeed(address f) external;
    function NATIVE_ADDRESS() external view returns (address);
}

contract PocToken is ERC20 {
    constructor(string memory s) ERC20(s, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract PocAgg {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// Sequencer uptime feed: up (answer 0) since `startedAt`. startedAt within the grace period => sequencerDown.
contract PocSeq {
    int256 public answer;
    uint256 public startedAt;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// Faithful copy of origin/main TwoFeedChainlinkPriceFeed._compute + origin/main NavBaseUsdLib.baseUsd (the bytecode
/// of every currently-deployed wstETH_L2 / weETH_L2 / rsETH_L2 / ezETH... feed).
contract OldTwoFeed is ICustomPriceFeed {
    INAVCalculator public immutable NAV;
    address public immutable BASE_ASSET;
    address public immutable UNDERLYING;
    PocAgg public immutable RATE_FEED;
    uint256 public immutable RATE_HEARTBEAT;

    constructor(address nav_, address base_, address und_, PocAgg rate_, uint256 hb_) {
        NAV = INAVCalculator(nav_);
        BASE_ASSET = base_;
        UNDERLYING = und_;
        RATE_FEED = rate_;
        RATE_HEARTBEAT = hb_;
    }

    function _oldBaseUsd() internal view virtual returns (uint256 price8, bool stale, uint256 updatedAt) {
        try NAV.getPriceDataNoDivergence(BASE_ASSET) returns (INAVCalculator.PriceFeedData memory pd) {
            bool baseStale = pd.stale && !pd.sequencerDown; // origin/main
            if (baseStale || pd.price <= 0) return (0, true, pd.updatedAt);
            price8 = uint256(pd.price); // decimals == 8 in this PoC
            return (price8, false, pd.updatedAt);
        } catch {
            return (0, true, 0);
        }
    }

    function _compute() internal view returns (uint256 price, bool stale, uint256 updatedAt) {
        (, int256 rate,, uint256 rateUpdatedAt,) = RATE_FEED.latestRoundData();
        (uint256 base8, bool baseStale, uint256 baseUpdatedAt) = _oldBaseUsd();
        updatedAt = rateUpdatedAt <= baseUpdatedAt ? rateUpdatedAt : baseUpdatedAt;
        if (baseStale || rate <= 0) return (0, true, updatedAt);
        uint256 effRate = rateUpdatedAt > block.timestamp ? block.timestamp : rateUpdatedAt;
        if (block.timestamp - effRate >= RATE_HEARTBEAT) return (0, true, updatedAt);
        price = uint256(rate) * base8 / 1e8;
    }

    function getLatestPrice() external view returns (uint256 price, bool stale) {
        (price, stale,) = _compute();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 p, bool s, uint256 u) = _compute();
        return (0, s ? int256(0) : int256(p), 0, u, 0);
    }

    function governingFeedFreshness() external view returns (uint256, uint256) {
        return (0, 0);
    }

    function underlyingAssetSupported() external view returns (address) {
        return UNDERLYING;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(ICustomPriceFeed).interfaceId || id == 0x01ffc9a7;
    }
}

/// Same feed with the NEW NavBaseUsdLib (this PR) — the control.
contract NewTwoFeed is OldTwoFeed {
    constructor(address nav_, address base_, address und_, PocAgg rate_, uint256 hb_)
        OldTwoFeed(nav_, base_, und_, rate_, hb_)
    {}

    function _oldBaseUsd() internal view override returns (uint256 price8, bool stale, uint256 updatedAt) {
        return NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);
    }
}

contract PR354_OldFeedSequencerDownPoC is Test {
    address admin = address(0xA11CE);
    address mgr = address(0xB0B);
    address safe = address(0x5AFE);
    INAVCalculator nav;
    PocAgg ethUsd;
    PocAgg rateFeed;
    PocSeq seq;
    PocToken weth;
    PocToken wstEth;
    PocToken wstEthNew;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        seq = new PocSeq();
        seq.set(0, block.timestamp - 2 days); // sequencer up, well past grace
        ethUsd = new PocAgg();
        ethUsd.set(4000e8, block.timestamp);
        rateFeed = new PocAgg();
        rateFeed.set(1.2e8, block.timestamp); // wstETH/ETH = 1.2 (8 dec)

        address impl = vm.deployCode("NAVCalculator.sol:NAVCalculator");
        bytes memory init = abi.encodeCall(INavAdmin.initialize, (admin, address(seq), "ETH"));
        nav = INAVCalculator(vm.deployCode("ERC1967Proxy.sol:ERC1967Proxy", abi.encode(impl, init)));
        vm.prank(admin);
        INavAdmin(address(nav)).grantRole(MANAGER, mgr);

        weth = new PocToken("WETH");
        wstEth = new PocToken("wstETH");
        wstEthNew = new PocToken("wstETHn");

        vm.startPrank(mgr);
        INavAdmin(address(nav))
            .addOrModifyPriceFeed(
                INavAdmin(address(nav)).NATIVE_ADDRESS(), address(ethUsd), IPrices.PriceType.Chainlink, 1200
            );
        // Base mainnet-like config: WETH Chainlink hb 1200, wstETH_L2 custom feed hb 86400 (8453.json).
        INavAdmin(address(nav)).registerAsset(address(weth), address(ethUsd), IPrices.PriceType.Chainlink, 1200);
        OldTwoFeed oldFeed = new OldTwoFeed(address(nav), address(weth), address(wstEth), rateFeed, 86400);
        INavAdmin(address(nav)).registerAsset(address(wstEth), address(oldFeed), IPrices.PriceType.Custom, 86400);
        NewTwoFeed newFeed = new NewTwoFeed(address(nav), address(weth), address(wstEthNew), rateFeed, 86400);
        INavAdmin(address(nav)).registerAsset(address(wstEthNew), address(newFeed), IPrices.PriceType.Custom, 86400);
        vm.stopPrank();

        weth.mint(safe, 1e18);
        wstEth.mint(safe, 1e18);
        wstEthNew.mint(safe, 1e18);
    }

    function _has(INAVCalculator.Asset[] memory a, address x) internal pure returns (bool) {
        for (uint256 i; i < a.length; i++) {
            if (a[i].asset == x) return true;
        }
        return false;
    }

    /// Control: sequencer up, ETH/USD stale -> both old and new feeds flag wstETH stale (old one by zeroing).
    function test_control_sequencerUp_oldFeedZeroesAndFlags() public {
        vm.warp(block.timestamp + 1300); // ETH/USD 1300 s old > 1200 s heartbeat
        rateFeed.set(1.2e8, block.timestamp);
        INAVCalculator.NAV memory n = nav.getAccountNav(safe, address(0));
        assertTrue(_has(n.stalePriceAssets, address(weth)), "weth stale");
        assertTrue(_has(n.stalePriceAssets, address(wstEth)), "old feed: wstETH stale (zeroed)");
        assertTrue(_has(n.stalePriceAssets, address(wstEthNew)), "new feed: wstETH stale");
        assertFalse(n.sequencerDown);
    }

    /// Exploit: L2 sequencer in grace after an outage, ETH/USD genuinely stale. The OLD feed under the NEW library
    /// reports wstETH FRESH (healthyFeedCount 1, absent from stalePriceAssets) priced off the stale ETH/USD.
    function test_exploit_oldFeed_newLib_sequencerDown_staleBaseReportedFresh() public {
        vm.warp(block.timestamp + 1300); // ETH/USD now 1300 s old (> 1200 s heartbeat): genuinely stale
        rateFeed.set(1.2e8, block.timestamp); // rate leg fresh
        seq.set(0, block.timestamp - 600); // sequencer back up 10 min ago -> within 1 h grace -> sequencerDown

        INAVCalculator.PriceFeedData memory base = nav.getPriceData(address(weth));
        assertEq(base.healthyFeedCount, 0, "precondition: base has NO fresh feed");
        assertEq(base.price, 4000e8, "new lib keeps the stale base price");

        INAVCalculator.PriceFeedData memory oldPd = nav.getPriceData(address(wstEth));
        INAVCalculator.PriceFeedData memory newPd = nav.getPriceData(address(wstEthNew));
        emit log_named_uint("old-feed wstETH healthyFeedCount", oldPd.healthyFeedCount);
        emit log_named_uint("new-feed wstETH healthyFeedCount", newPd.healthyFeedCount);
        assertEq(oldPd.healthyFeedCount, 1, "BUG: old feed counted FRESH while its base is stale");
        assertEq(newPd.healthyFeedCount, 0, "control: new feed correctly not fresh");
        assertEq(oldPd.price, 4800e8, "priced off the stale base");

        INAVCalculator.NAV memory n = nav.getAccountNav(safe, address(0));
        assertTrue(n.sequencerDown, "only the top-level sequencer flag is set");
        assertTrue(_has(n.stalePriceAssets, address(weth)), "weth listed stale");
        assertTrue(_has(n.stalePriceAssets, address(wstEthNew)), "new-feed wstETH listed stale");
        assertFalse(_has(n.stalePriceAssets, address(wstEth)), "BUG: old-feed wstETH missing from stalePriceAssets");

        (, address[] memory hcStale,) = nav.healthCheck();
        bool listed;
        for (uint256 i; i < hcStale.length; i++) {
            if (hcStale[i] == address(wstEth)) listed = true;
        }
        assertFalse(listed, "BUG: healthCheck omits the old-feed asset too");

        (,, bool lpStale,) = IPrices(address(nav)).latestPrice(address(wstEth));
        assertTrue(lpStale, "latestPrice folds sequencerDown so it is still true here");
    }
}
