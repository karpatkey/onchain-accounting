// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IRealizabilitySource} from "src/prices/IRealizabilitySource.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC4626RealizabilitySource} from "src/prices/realizability/ERC4626RealizabilitySource.sol";
import {LidoRealizabilitySource} from "src/prices/realizability/LidoRealizabilitySource.sol";
import {StaderRealizabilitySource} from "src/prices/realizability/StaderRealizabilitySource.sol";

/// @dev Settable realizability source pinned to an asset (for framework/signal tests).
contract MockRealizabilitySource is IRealizabilitySource {
    address public asset;
    bool public enabled;
    uint256 public eta;
    bool public healthy;
    bool public doRevert;

    constructor(address asset_, bool enabled_, uint256 eta_, bool healthy_) {
        asset = asset_;
        enabled = enabled_;
        eta = eta_;
        healthy = healthy_;
    }

    function set(bool e, uint256 t, bool h) external {
        enabled = e;
        eta = t;
        healthy = h;
    }

    function setRevert(bool r) external {
        doRevert = r;
    }

    function underlyingAssetSupported() external view returns (address) {
        return asset;
    }

    function realizability() external view returns (bool, uint256, bool) {
        require(!doRevert, "boom");
        return (enabled, eta, healthy);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IRealizabilitySource).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev Minimal ERC4626 stub for the source test.
contract MockVault4626 {
    uint256 public rate = 1e18;
    uint256 public totalAssets = 1_000e18;

    function set(uint256 rate_, uint256 assets_) external {
        rate = rate_;
        totalAssets = assets_;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }

    // ERC20 surface probed by OracleArgumentChecks.assertERC20Address (the share token is an ERC20).
    function totalSupply() external pure returns (uint256) {
        return 1_000e18;
    }
}

/// @dev Minimal Lido withdrawal-queue stub.
contract MockLidoQueue {
    bool public bunker;
    bool public paused;

    function set(bool b, bool p) external {
        bunker = b;
        paused = p;
    }

    function isBunkerModeActive() external view returns (bool) {
        return bunker;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }
}

/// @dev Minimal Stader UserWithdrawalManager stub.
contract MockStaderManager {
    uint256 public nextRequestId;
    uint256 public nextRequestIdToFinalize;

    function set(uint256 head, uint256 finalize) external {
        nextRequestId = head;
        nextRequestIdToFinalize = finalize;
    }
}

/// @title Realizability signal tests
/// @notice Framework (source vs scalar vs unconfigured), the unrealizable flag logic, full signal parity
///         (getRealizability / getPriceData / NAV / Position / healthCheck / latestPrice), and two concrete sources.
contract RealizabilityTest is SuperTest {
    MockRealizabilitySource src;

    function setUp() public {
        setupAll();
        src = new MockRealizabilitySource(address(weth), true, 1 days, true);
    }

    function _wire(uint32 limit) internal {
        vm.startPrank(navCalculatorManager);
        nav.setRealizabilityLimit(address(weth), limit);
        nav.setRealizabilitySource(address(weth), address(src));
        vm.stopPrank();
    }

    // ---- resolution + flag logic ----

    function test_unconfigured_notUnrealizable() public view {
        (,,,, bool unrealizable, bool configured) = nav.getRealizability(address(weth));
        assertFalse(configured);
        assertFalse(unrealizable);
    }

    function test_source_withinLimit_realizable() public {
        _wire(7 days); // 1 day ETA < 7 day limit
        (bool en, uint256 eta,, uint256 limit, bool unrealizable, bool configured) = nav.getRealizability(address(weth));
        assertTrue(configured);
        assertTrue(en);
        assertEq(eta, 1 days);
        assertEq(limit, 7 days);
        assertFalse(unrealizable);
    }

    function test_source_overLimit_unrealizable() public {
        _wire(1 hours); // 1 day ETA > 1 hour limit
        (,,,, bool unrealizable,) = nav.getRealizability(address(weth));
        assertTrue(unrealizable);
    }

    function test_source_disabled_unrealizable() public {
        _wire(7 days);
        src.set(false, 0, true); // withdrawals disabled
        (,,,, bool unrealizable,) = nav.getRealizability(address(weth));
        assertTrue(unrealizable);
    }

    function test_source_unhealthy_unrealizable() public {
        _wire(7 days);
        src.set(true, 0, false); // unhealthy (e.g. bunker)
        (,,,, bool unrealizable,) = nav.getRealizability(address(weth));
        assertTrue(unrealizable);
    }

    function test_sourceReverts_fallsBackToScalar() public {
        _wire(7 days);
        src.setRevert(true);
        vm.prank(navCalculatorManager);
        nav.setRealizabilityScalar(address(weth), false, 0, true); // scalar says disabled
        (,,,, bool unrealizable, bool configured) = nav.getRealizability(address(weth));
        assertTrue(configured, "reverting source falls back to scalar");
        assertTrue(unrealizable);
    }

    function test_sourceReverts_noScalar_failsClosed() public {
        _wire(7 days); // source only, no scalar
        src.setRevert(true);
        (bool en,,,, bool unrealizable, bool configured) = nav.getRealizability(address(weth));
        assertTrue(configured, "a reverting configured source is not treated as unconfigured");
        assertFalse(en);
        assertTrue(unrealizable, "source revert with no scalar must fail CLOSED (unrealizable)");
    }

    function test_scalarOnly() public {
        vm.startPrank(navCalculatorManager);
        nav.setRealizabilityLimit(address(weth), 1 hours);
        nav.setRealizabilityScalar(address(weth), true, 1 days, true); // 1 day > 1 hour
        vm.stopPrank();
        (,,,, bool unrealizable, bool configured) = nav.getRealizability(address(weth));
        assertTrue(configured);
        assertTrue(unrealizable);
    }

    // ---- signal parity ----

    function test_signalParity_getPriceData_and_latestPrice() public {
        _wire(1 hours); // over-limit -> unrealizable
        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(address(weth));
        assertTrue(pd.unrealizable);
        assertFalse(pd.stale, "price still usable");
        (,,,, bool unrealizable) = nav.latestPrice(address(weth));
        assertTrue(unrealizable);
    }

    function test_signalParity_nav_position_healthCheck() public {
        _wire(1 hours);
        weth.mint(address(safe), 1 ether);

        INAVCalculator.NAV memory r = nav.getAccountNav(address(safe), address(0));
        bool inNav;
        for (uint256 i = 0; i < r.unrealizablePriceAssets.length; i++) {
            if (r.unrealizablePriceAssets[i].asset == address(weth)) inNav = true;
        }
        assertTrue(inNav, "NAV.unrealizablePriceAssets contains weth");

        INAVCalculator.Position[] memory ps = nav.getAccountPositions(address(safe), address(0));
        bool posFlagged;
        for (uint256 i = 0; i < ps.length; i++) {
            if (ps[i].balanceAsset.asset == address(weth)) posFlagged = ps[i].unrealizable;
        }
        assertTrue(posFlagged, "Position.unrealizable set");

        (,,, address[] memory unrealizable) = nav.healthCheck();
        bool inHc;
        for (uint256 i = 0; i < unrealizable.length; i++) {
            if (unrealizable[i] == address(weth)) inHc = true;
        }
        assertTrue(inHc, "healthCheck reports weth unrealizable");
    }

    // ---- validation ----

    function test_setSource_rejectsWrongAsset() public {
        MockRealizabilitySource wrong = new MockRealizabilitySource(address(usdc), true, 0, true);
        vm.prank(navCalculatorManager);
        vm.expectRevert(abi.encodeWithSelector(IPrices.InvalidRealizabilitySource.selector, address(weth), address(wrong)));
        nav.setRealizabilitySource(address(weth), address(wrong));
    }

    function test_clearSource() public {
        _wire(7 days);
        vm.prank(navCalculatorManager);
        nav.setRealizabilitySource(address(weth), address(0));
        (,,,,, bool configured) = nav.getRealizability(address(weth));
        assertFalse(configured, "source cleared, no scalar -> unconfigured");
    }

    // ---- concrete sources ----

    function test_erc4626Source() public {
        MockVault4626 vault = new MockVault4626();
        ERC4626RealizabilitySource s = new ERC4626RealizabilitySource(address(vault), 0);
        (bool en, uint256 eta, bool h) = s.realizability();
        assertTrue(en);
        assertEq(eta, 0);
        assertTrue(h);
        vault.set(1e18, 0); // no assets -> not realizable
        (en,,) = s.realizability();
        assertFalse(en);
    }

    function test_staderSource_queueStates() public {
        MockStaderManager m = new MockStaderManager();
        StaderRealizabilitySource s =
            new StaderRealizabilitySource(address(weth), address(m), 2 days, 10 days, 1000);

        m.set(100, 90); // coherent, shallow queue (pending 10)
        (bool en, uint256 eta, bool h) = s.realizability();
        assertTrue(en);
        assertEq(eta, 2 days);
        assertTrue(h);

        m.set(5000, 90); // coherent, congested (pending 4910 > 1000)
        (, eta,) = s.realizability();
        assertEq(eta, 10 days);

        m.set(50, 100); // incoherent (finalize > head) → disabled, must NOT underflow-revert
        (en,,) = s.realizability();
        assertFalse(en, "incoherent queue -> withdrawals disabled");
    }

    function test_lidoSource_bunkerAndPause() public {
        MockLidoQueue q = new MockLidoQueue();
        LidoRealizabilitySource s = new LidoRealizabilitySource(address(weth), address(q), 3 days, 30 days);
        (bool en, uint256 eta, bool h) = s.realizability();
        assertTrue(en);
        assertEq(eta, 3 days);
        assertTrue(h);

        q.set(true, false); // bunker
        (en, eta, h) = s.realizability();
        assertTrue(en);
        assertEq(eta, 30 days);
        assertFalse(h, "bunker -> unhealthy");

        q.set(false, true); // paused
        (en,,) = s.realizability();
        assertFalse(en, "paused -> withdrawals disabled");
    }
}
