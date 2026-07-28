// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CurvePoolsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {
    ConvexCurveLPStakingMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol";
import {
    BalancerV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockCurveToken} from "test/balances/MetaBalanceAdapters/CurveMocks.sol";

/// @notice A pool-shaped contract whose `coins()` never returns.
/// @dev The hostile coordinate the label paths have to survive. It answers the shape a real Curve pool answers,
///      so the reader reaches it the same way, and then loops — which without a ceiling means it takes 63/64 of
///      whatever frame called in.
contract Mock_BurningCoinsPool {
    address public immutable COIN0;

    constructor(address coin0) {
        COIN0 = coin0;
    }

    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        // `coins(uint256)` and everything else: burn. Hashing one word grows no memory, so this spends the
        // stipend steadily instead of out-of-gassing early on memory expansion.
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice A token whose `symbol()` never returns, reached from an otherwise-honest pool.
/// @dev The second reachability shape, and the more realistic one: the governed coordinate is fine, but a token
///      inside it is attacker-chosen. `LabelLib` already caps each symbol read at 100k, so this exists to show
///      the leaf-level ceiling composes with that rather than replacing it.
contract Mock_BurningSymbolToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function symbol() external pure returns (string memory) {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice A Convex rewarder answering `pid()`, so the adapter's bounded pid read succeeds and the walk goes on.
contract Mock_ConvexRewarder {
    function pid() external pure returns (uint256) {
        return 0;
    }
}

/// @notice A Booster whose `poolInfo` hands back a burning LP token.
/// @dev Needed because the adapter's own `pid()` read is already bounded: stopping there is what made an earlier
///      version of this test pass without exercising anything. The unbounded work is further along, in
///      `CurvePoolLib.getPool(lpToken)`, so the walk has to actually get there.
contract Mock_ConvexBooster {
    address private immutable LP;

    constructor(address lp) {
        LP = lp;
    }

    function poolInfo(uint256) external view returns (address, address, address, address, address, bool) {
        return (LP, address(0), address(0), address(0), address(0), false);
    }
}

/// @notice An honest pool with `n` coins, for measuring what a legitimate leaf actually costs.
contract Mock_WideCurvePool {
    address[] public coinList;

    constructor(address[] memory coins_) {
        for (uint256 i; i < coins_.length; i++) {
            coinList.push(coins_[i]);
        }
    }

    function coins(uint256 i) external view returns (address) {
        if (i >= coinList.length) revert("out of range");
        return coinList[i];
    }

    function lp_token() external view returns (address) {
        return address(this);
    }
}

/// @notice Calls `positionLabels` from a fresh frame under an explicit budget, reporting cost and outcome.
/// @dev Measuring against a forge test frame's ~1e9 gas would be meaningless: an unbounded burn takes 63/64 of
///      whatever it is given, so the number only means something relative to a budget the test chose.
contract LabelHarness {
    function labelCost(address adapter, bytes memory pid, uint256 budget)
        external
        view
        returns (bool ok, uint256 used, uint256 segments)
    {
        uint256 before = gasleft();
        (bool success, bytes memory ret) =
            adapter.staticcall{gas: budget}(abi.encodeWithSignature("positionLabels(bytes)", pid));
        used = before - gasleft();
        ok = success;
        if (success) {
            string[] memory out = abi.decode(ret, (string[]));
            segments = out.length;
        }
    }
}

/// @title Meta-adapter label gas bounds
/// @author KPK
/// @notice Pins that deriving a `positionLabels` leaf cannot spend the budget of whatever called in.
/// @dev Every leaf in this family reads the chain through addresses reached from a governed coordinate — pool
///      coins, gauge LP tokens, ERC20 symbols. Those reads were unbounded: the `try this.<leaf>()` boundary
///      forwards 63/64 of the frame, and the Curve readers underneath carry no stipend of their own, so a single
///      hostile coordinate could consume a whole read for a display string.
///
///      Impact is liveness, not correctness — nothing over-reports — which is why the degraded answer asserted
///      here is the category alone, the same answer an unreadable symbol has always produced.
contract MetaLabelGasBoundsTest is Test {
    Mock_NAVCalculator internal nav;
    LabelHarness internal harness;
    MockCurveToken internal usdc;

    /// @dev Budget handed to a label read under test. Far above any honest leaf, far below what an unbounded
    ///      burn would take from it.
    uint256 internal constant BUDGET = 30_000_000;

    /// @dev Ceiling for one bounded leaf: the 500k stipend plus the read's own overhead. An unbounded leaf takes
    ///      63/64 of {BUDGET}, i.e. ~29.5M, so the two are three orders of magnitude apart and the assertion
    ///      discriminates without being tight.
    uint256 internal constant BOUNDED_CEILING = 2_000_000;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        harness = new LabelHarness();
        usdc = new MockCurveToken("USDC", 6);
        nav.registerAsset(address(usdc), 6, "USDC");
    }

    // ---------------------------------------------------------------------------------------------------------
    // The Curve trio — bounded by promoting the leaf helper to an external self-call
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A pool whose `coins()` loops must cost the reader its stipend, not its whole budget.
    /// @dev Remove `{gas: LABEL_LEAF_GAS}` from `CurvePoolsMetaBalanceAdapter.positionLabels` and this fails:
    ///      `CurvePoolLib`'s staticcalls carry no stipend of their own, so the burn runs to 63/64 of BUDGET.
    function test_curvePools_hostileCoordinate_isBounded() public {
        CurvePoolsMetaBalanceAdapter meta = new CurvePoolsMetaBalanceAdapter(address(nav));
        Mock_BurningCoinsPool hostile = new Mock_BurningCoinsPool(address(usdc));

        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(meta), abi.encode(address(hostile)), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile coordinate");
        assertEq(segments, 1, "the leaf is dropped, the category survives");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    /// @notice Same for the gauge adapter, which reaches the pool one hop further along.
    function test_curveGauges_hostileCoordinate_isBounded() public {
        CurveGaugesMetaBalanceAdapter meta =
            new CurveGaugesMetaBalanceAdapter(address(usdc), address(usdc), address(nav));
        Mock_BurningCoinsPool hostile = new Mock_BurningCoinsPool(address(usdc));

        (bool ok, uint256 used,) = harness.labelCost(address(meta), abi.encode(address(hostile)), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile coordinate");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    /// @notice And Convex, which reaches `CurvePoolLib` through its own helper rather than the shared name.
    /// @dev The member a list of the affected paths misses: its `_lpTokenOf` is already bounded, which makes the
    ///      adapter look safe until you follow what happens after.
    function test_convex_hostileCoordinate_isBounded() public {
        Mock_BurningCoinsPool burningLp = new Mock_BurningCoinsPool(address(usdc));
        Mock_ConvexBooster booster = new Mock_ConvexBooster(address(burningLp));
        Mock_ConvexRewarder rewarder = new Mock_ConvexRewarder();
        ConvexCurveLPStakingMetaBalanceAdapter meta =
            new ConvexCurveLPStakingMetaBalanceAdapter(address(booster), address(usdc), address(nav));

        (bool ok, uint256 used,) = harness.labelCost(address(meta), abi.encode(address(rewarder)), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile coordinate");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    // ---------------------------------------------------------------------------------------------------------
    // The self-call family — bounded by adding the stipend to a boundary that already existed
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A Balancer pool coordinate that loops must be bounded the same way.
    /// @dev These six already routed their leaf through `try this.<helper>()`; the boundary existed and simply
    ///      forwarded everything. Drop the `{gas:}` and this returns to ~63/64 of BUDGET.
    function test_balancerV2Pools_hostileCoordinate_isBounded() public {
        Mock_BurningCoinsPool hostileVault = new Mock_BurningCoinsPool(address(usdc));
        BalancerV2PoolsMetaBalanceAdapter meta =
            new BalancerV2PoolsMetaBalanceAdapter(address(hostileVault), address(nav));

        (bool ok, uint256 used,) = harness.labelCost(address(meta), abi.encode(bytes32(uint256(1))), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile vault");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Reachability through an honest coordinate
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A governed pool that is itself fine but holds an attacker-chosen token with a looping `symbol()`.
    /// @dev The realistic shape: the MANAGER vetted the pool, not every token inside it. `LabelLib` caps each
    ///      symbol read at 100k, so this also shows the two ceilings compose — the leaf bound is the backstop
    ///      for however many such reads a leaf makes.
    function test_honestPool_withHostileToken_isBounded() public {
        CurvePoolsMetaBalanceAdapter meta = new CurvePoolsMetaBalanceAdapter(address(nav));
        address[] memory coins = new address[](2);
        coins[0] = address(usdc);
        coins[1] = address(new Mock_BurningSymbolToken());
        Mock_WideCurvePool pool = new Mock_WideCurvePool(coins);

        (bool ok, uint256 used,) = harness.labelCost(address(meta), abi.encode(address(pool)), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile token");
        assertLt(used, BOUNDED_CEILING, "one hostile token must not spend the caller's budget");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Calibration — the ceiling must clear what an honest leaf costs
    // ---------------------------------------------------------------------------------------------------------

    /// @notice The widest legitimate leaf must resolve fully, and with room under the stipend.
    /// @dev The bound is only safe if it cannot drop a real label. `CurvePoolLib` reads up to 8 coins and takes
    ///      a symbol for each, which is the widest leaf this family produces; this drives exactly that and
    ///      asserts both that every coin made it into the string and that the cost leaves margin.
    function test_widestHonestLeaf_resolvesWithMargin() public {
        CurvePoolsMetaBalanceAdapter meta = new CurvePoolsMetaBalanceAdapter(address(nav));
        address[] memory coins = new address[](8);
        for (uint256 i; i < 8; i++) {
            MockCurveToken t = new MockCurveToken("TOKENNAME", 18);
            nav.registerAsset(address(t), 18, "TOKENNAME");
            coins[i] = address(t);
        }
        Mock_WideCurvePool pool = new Mock_WideCurvePool(coins);

        (bool ok, uint256 used, uint256 segments) = harness.labelCost(address(meta), abi.encode(address(pool)), BUDGET);

        assertTrue(ok, "an honest 8-coin pool must label successfully");
        assertEq(segments, 2, "category plus a full leaf - the leaf must NOT have been dropped");
        emit log_named_uint("8-coin honest leaf gas", used);
        // The stipend is 500k; an honest widest leaf must sit well inside it or the bound is unsafe.
        assertLt(used, 400_000, "the widest honest leaf must fit inside the stipend with margin");
    }
}
