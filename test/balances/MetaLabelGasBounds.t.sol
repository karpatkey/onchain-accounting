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
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockCurveToken} from "test/balances/MetaBalanceAdapters/CurveMocks.sol";
import {MockV2Vault} from "test/balances/MetaBalanceAdapters/BalancerV2MetaMocks.sol";
import {MockFluidVaultT1, MockFluidVaultResolver} from "test/balances/MetaBalanceAdapters/FluidVaultMocks.sol";

/// @notice A pool-shaped contract whose `coins()` never returns.
/// @dev The hostile coordinate the label paths have to survive. It answers the shape a real Curve pool answers,
///      so the reader reaches it the same way, and then loops — which without a ceiling means it takes 63/64 of
///      whatever frame called in.
contract Mock_BurningCoinsPool {
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        // `coins(uint256)` and everything else: burn. Hashing one word grows no memory, so this spends the
        // stipend steadily instead of out-of-gassing early on memory expansion.
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @notice A token whose `symbol()` burns a caller-chosen amount of gas before answering, or never answers.
/// @dev The realistic hostile shape: the governed coordinate is fine, but a token inside it is attacker-chosen.
///      `LabelLib` already caps each symbol read at `METADATA_READ_GAS` (100k), so a token that burns forever
///      only ever costs one cap. Burning a *bounded* amount just under that cap is what makes several such
///      tokens add up to something the leaf ceiling has to catch — which is the property under test.
contract Mock_BurningSymbolToken {
    /// @dev 0 means "never return". Anything else is burnt, then a normal symbol is produced.
    uint256 public immutable BURN;

    constructor(uint256 burn) {
        BURN = burn;
    }

    function symbol() external view returns (string memory) {
        uint256 target = BURN;
        uint256 start = gasleft();
        if (target == 0) {
            assembly {
                for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
        }
        while (start - gasleft() < target) {
            assembly {
                mstore(0x00, keccak256(0x00, 0x20))
            }
        }
        return "BURN";
    }
}

/// @notice A Convex rewarder answering `pid()`, so the adapter's bounded pid read succeeds and the walk goes on.
contract Mock_ConvexRewarder {
    function pid() external pure returns (uint256) {
        return 0;
    }
}

/// @notice A Booster whose `poolInfo` hands back a burning LP token.
/// @dev The adapter's own `pid()` read is already bounded, so a probe that stops there exercises nothing. The
///      unbounded work is further along, in `CurvePoolLib.getPool(lpToken)`, so the walk has to reach it.
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
}

/// @notice The `symbol()` implementation behind {Mock_ProxiedToken}, reached by `delegatecall`.
contract Mock_TokenImpl {
    string internal _symbol;

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice An ERC-1967 proxy-shaped ERC20 — the shape most mainnet tokens actually have.
/// @dev Calibrating against a flat mock understates every symbol read, and always in the same direction. A read
///      through a proxy additionally pays a cold implementation-slot SLOAD (2,100) and a cold account access for
///      the implementation (2,600) *inside the callee*, charged against the leaf's stipend. On a wide pool that
///      is a per-token surcharge, so it scales with exactly the axis the ceiling is sized along. USDC, USDT and
///      essentially every wrapped or bridged token on the venues this family reads are upgradeable proxies, so
///      this — not the flat mock — is the shape the ceiling has to clear.
contract Mock_ProxiedToken {
    string internal _symbol;

    constructor(address impl, string memory symbol_) {
        _symbol = symbol_;
        // ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
        assembly {
            sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, impl)
        }
    }

    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        assembly {
            let impl := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
            calldatacopy(0x00, 0x00, calldatasize())
            let ok := delegatecall(gas(), impl, 0x00, calldatasize(), 0x00, 0x00)
            returndatacopy(0x00, 0x00, returndatasize())
            switch ok
            case 0 { revert(0x00, returndatasize()) }
            default { return(0x00, returndatasize()) }
        }
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

    /// @notice As {labelCost}, but also hands back the rendered leaf so a test can assert on its CONTENT.
    /// @dev Segment count alone cannot tell a complete leaf from a truncated one: both answer 2. The property
    ///      that matters is that a starved leaf is ABSENT, never a short list presented as finished.
    function labelLeaf(address adapter, bytes memory pid, uint256 budget)
        external
        view
        returns (bool ok, uint256 segments, string memory leaf)
    {
        (bool success, bytes memory ret) =
            adapter.staticcall{gas: budget}(abi.encodeWithSignature("positionLabels(bytes)", pid));
        ok = success;
        if (success) {
            string[] memory out = abi.decode(ret, (string[]));
            segments = out.length;
            if (out.length > 1) leaf = out[out.length - 1];
        }
    }
}

/// @title Meta-adapter label gas bounds
/// @author KPK
/// @notice Pins that deriving a `positionLabels` leaf cannot spend the budget of whatever called in, and that
///         every leaf a governed coordinate can legitimately produce still fits under that ceiling.
/// @dev Every leaf in this family reads the chain through addresses reached from a governed coordinate — pool
///      coins, gauge LP tokens, ERC20 symbols. Unbounded, the `try this.<leaf>()` boundary forwards 63/64 of the
///      frame and the Curve readers underneath carry no stipend of their own, so a single hostile coordinate can
///      consume a whole read for a display string.
///
///      Impact is liveness, not correctness — nothing over-reports — which is why the degraded answer asserted
///      here is the category alone, the same answer an unreadable symbol has always produced. The reason that
///      still needs care is the converse: a ceiling set too low drops leaves that legitimately render, and the
///      adapters are immutable, so the number cannot be corrected in place.
///
///      **Every figure here is measured COLD.** Forge resets the access list between `setUp` and the test body,
///      so a contract deployed in the body is read WARM — every account and slot already paid for — which
///      understates a real `eth_call` by more than 2x. Anything whose cost is being pinned is therefore built in
///      `setUp`, and the tokens are {Mock_ProxiedToken} rather than flat mocks for the same reason.
contract MetaLabelGasBoundsTest is Test {
    Mock_NAVCalculator internal nav;
    LabelHarness internal harness;
    MockCurveToken internal usdc;
    Mock_TokenImpl internal tokenImpl;

    // Cold fixtures. See the contract docblock for why these cannot be built in the test body.
    Mock_WideCurvePool internal coldPool;
    CurvePoolsMetaBalanceAdapter internal coldCurveMeta;
    Mock_WideCurvePool internal coldProxiedPool;
    CurvePoolsMetaBalanceAdapter internal coldProxiedCurveMeta;

    MockV2Vault internal coldVault33;
    MockV2Vault internal coldVault50;
    BalancerV2PoolsMetaBalanceAdapter internal coldBalancer33;
    BalancerV2PoolsMetaBalanceAdapter internal coldBalancer50;
    bytes32 internal coldPoolId33;
    bytes32 internal coldPoolId50;

    FluidVaultsMetaBalanceAdapter internal coldFluidMeta;
    MockFluidVaultT1 internal coldFluidVault;

    /// @dev Budget handed to a label read under test. Far above any honest leaf, far below what an unbounded
    ///      burn would take from it.
    uint256 internal constant BUDGET = 30_000_000;

    /// @dev Mirrors `MetaBalanceAdapter.LABEL_LEAF_GAS`, which is `internal` and so not reachable from here.
    ///      Keep the two in step: this file is the calibration that justifies that constant's value.
    uint256 internal constant LEAF_GAS = 900_000;

    /// @dev Ceiling for one bounded leaf: the stipend plus the enclosing read's own overhead (pid decode, the
    ///      `_labels` build, the return encode). Deliberately close to {LEAF_GAS} — a loose bound here is what
    ///      let an earlier ceiling of 2M pass while bounding almost nothing.
    uint256 internal constant BOUNDED_CEILING = LEAF_GAS + 150_000;

    /// @dev Mainnet's registered-asset count at the time of writing, from
    ///      `script/config/nav-config/assets-and-price-feeds/1.json`. The Fluid leaf's cost is linear in this.
    uint256 internal constant MAINNET_REGISTERED_ASSETS = 43;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        harness = new LabelHarness();
        tokenImpl = new Mock_TokenImpl();
        usdc = new MockCurveToken("USDC", 6);
        nav.registerAsset(address(usdc), 6, "USDC");

        address[] memory wide = new address[](8);
        for (uint256 i; i < 8; i++) {
            MockCurveToken t = new MockCurveToken("TOKENNAME", 18);
            nav.registerAsset(address(t), 18, "TOKENNAME");
            wide[i] = address(t);
        }
        coldPool = new Mock_WideCurvePool(wide);
        coldCurveMeta = new CurvePoolsMetaBalanceAdapter(address(nav));

        address[] memory wideProxied = new address[](8);
        for (uint256 i; i < 8; i++) {
            wideProxied[i] = address(new Mock_ProxiedToken(address(tokenImpl), "TOKENNAM"));
        }
        coldProxiedPool = new Mock_WideCurvePool(wideProxied);
        coldProxiedCurveMeta = new CurvePoolsMetaBalanceAdapter(address(nav));

        (coldVault33, coldBalancer33, coldPoolId33) = _buildBalancerPool(33);
        (coldVault50, coldBalancer50, coldPoolId50) = _buildBalancerPool(50);

        // Fluid: the leaf fetches the WHOLE registered-asset array, so its cost is linear in the registry, not
        // in anything about Fluid. Pad the registry to mainnet's size so the measurement is the real one.
        while (nav.getRegisteredAssets().length < MAINNET_REGISTERED_ASSETS) {
            Mock_ProxiedToken pad = new Mock_ProxiedToken(address(tokenImpl), "PADPAD");
            nav.registerAsset(address(pad), 18, "PADPAD");
        }
        MockFluidVaultResolver resolver = new MockFluidVaultResolver();
        coldFluidVault = new MockFluidVaultT1();
        address coll = address(new Mock_ProxiedToken(address(tokenImpl), "wstETH"));
        address debt = address(new Mock_ProxiedToken(address(tokenImpl), "USDC"));
        coldFluidVault.setTokens(coll, debt);
        coldFluidVault.setVaultId(4);
        resolver.setVaultType(address(coldFluidVault), 10_000);
        coldFluidMeta = new FluidVaultsMetaBalanceAdapter(address(resolver), address(nav));
    }

    /// @dev A Balancer V2 pool of `n` proxied tokens, registered with the Vault under a poolId whose leading 20
    ///      bytes are the BPT (`BalancerV2PoolLib.bptOf`). Balances are irrelevant to the label path.
    function _buildBalancerPool(uint256 n)
        private
        returns (MockV2Vault vault, BalancerV2PoolsMetaBalanceAdapter meta, bytes32 poolId)
    {
        vault = new MockV2Vault();
        address bpt = address(new Mock_ProxiedToken(address(tokenImpl), "BPT"));
        poolId = bytes32(uint256(uint160(bpt)) << 96);
        address[] memory tokens = new address[](n);
        uint256[] memory balances = new uint256[](n);
        for (uint256 i; i < n; i++) {
            // 8-character symbols: the length the acceptance band is stated at.
            tokens[i] = address(new Mock_ProxiedToken(address(tokenImpl), "TOKENNAM"));
        }
        vault.setPool(poolId, tokens, balances);
        meta = new BalancerV2PoolsMetaBalanceAdapter(address(vault), address(nav));
    }

    // ---------------------------------------------------------------------------------------------------------
    // The Curve trio — bounded by promoting the leaf helper to an external self-call
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A pool whose `coins()` loops must cost the reader its stipend, not its whole budget.
    /// @dev Remove `{gas: LABEL_LEAF_GAS}` from `CurvePoolsMetaBalanceAdapter.positionLabels` and this fails:
    ///      `CurvePoolLib`'s staticcalls carry no stipend of their own, so the burn runs to 63/64 of BUDGET.
    function test_curvePools_hostileCoordinate_isBounded() public {
        CurvePoolsMetaBalanceAdapter meta = new CurvePoolsMetaBalanceAdapter(address(nav));
        Mock_BurningCoinsPool hostile = new Mock_BurningCoinsPool();

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
        Mock_BurningCoinsPool hostile = new Mock_BurningCoinsPool();

        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(meta), abi.encode(address(hostile)), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile coordinate");
        assertEq(segments, 1, "the leaf is dropped, the category survives");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    /// @notice And Convex, which reaches `CurvePoolLib` through its own helper rather than the shared name.
    /// @dev Convex is the member an enumeration of the affected paths misses: its `_lpTokenOf` is already
    ///      bounded, which makes the adapter look safe until you follow what happens after.
    function test_convex_hostileCoordinate_isBounded() public {
        Mock_BurningCoinsPool burningLp = new Mock_BurningCoinsPool();
        Mock_ConvexBooster booster = new Mock_ConvexBooster(address(burningLp));
        Mock_ConvexRewarder rewarder = new Mock_ConvexRewarder();
        ConvexCurveLPStakingMetaBalanceAdapter meta =
            new ConvexCurveLPStakingMetaBalanceAdapter(address(booster), address(usdc), address(nav));

        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(meta), abi.encode(address(rewarder)), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile coordinate");
        assertEq(segments, 2, "Convex degrades to its TWO category segments, not to one");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    // ---------------------------------------------------------------------------------------------------------
    // The self-call family — bounded by adding the stipend to a boundary that already existed
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A Balancer pool coordinate that loops must be bounded the same way.
    /// @dev These already routed their leaf through `try this.<helper>()`; the boundary existed and simply
    ///      forwarded everything. Drop the `{gas:}` and this returns to ~63/64 of BUDGET.
    function test_balancerV2Pools_hostileCoordinate_isBounded() public {
        Mock_BurningCoinsPool hostileVault = new Mock_BurningCoinsPool();
        BalancerV2PoolsMetaBalanceAdapter meta =
            new BalancerV2PoolsMetaBalanceAdapter(address(hostileVault), address(nav));

        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(meta), abi.encode(bytes32(uint256(1))), BUDGET);

        assertTrue(ok, "positionLabels must not revert on a hostile vault");
        assertEq(segments, 1, "the leaf is dropped, the category survives");
        assertLt(used, BOUNDED_CEILING, "a hostile coordinate must not spend the caller's budget");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Reachability through an honest coordinate
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A governed pool that is itself fine, holding 50 tokens whose `symbol()` never returns.
    /// @dev The realistic shape: the MANAGER vetted the pool, not every token inside it. Both the venue and the
    ///      count are load-bearing. `LabelLib` caps each symbol read at `METADATA_READ_GAS` (100k), so what this
    ///      ceiling has to catch is the SUM — and only where the number of reads is unbounded by something else.
    ///      It is not on the Curve path: `CurvePoolLib.MAX_COINS` stops the enumeration at 8, so that leaf is
    ///      already bounded by composition at ~800k and the same test written against a Curve pool passes with
    ///      `{gas: LABEL_LEAF_GAS}` stripped out — asserting nothing. Balancer has no such cap;
    ///      `_joinTokenSymbols` iterates whatever the pool reports, up to the protocol's 50. That sums to ~5M,
    ///      which only the leaf-level bound can catch. This is the test that shows the two bounds COMPOSE:
    ///      `LabelLib` bounds any single read, this bounds however many reads a leaf makes.
    function test_honestPool_withManyExpensiveTokens_isBounded() public {
        MockV2Vault vault = new MockV2Vault();
        address bpt = address(new Mock_ProxiedToken(address(tokenImpl), "BPT"));
        bytes32 poolId = bytes32(uint256(uint160(bpt)) << 96);
        address[] memory tokens = new address[](50);
        uint256[] memory balances = new uint256[](50);
        for (uint256 i; i < 50; i++) {
            tokens[i] = address(new Mock_BurningSymbolToken(0));
        }
        vault.setPool(poolId, tokens, balances);
        BalancerV2PoolsMetaBalanceAdapter meta = new BalancerV2PoolsMetaBalanceAdapter(address(vault), address(nav));

        (bool ok, uint256 used,) = harness.labelCost(address(meta), abi.encode(poolId), BUDGET);

        assertTrue(ok, "positionLabels must not revert");
        assertLt(used, BOUNDED_CEILING, "fifty capped-but-hostile symbol reads must not sum past the leaf ceiling");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Degradation is all-or-nothing — a starved leaf must be ABSENT, never truncated
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Across every budget, the leaf is either complete or missing — never a short list rendered as
    ///         though it were finished.
    /// @dev The hazard this rules out is specific and would be silent: `CurvePoolLib.getCoins` stops enumerating
    ///      at the first `coins(i)` that answers `address(0)`, and a starved raw staticcall answers exactly that.
    ///      Were the enclosing frame to survive that, the adapter would render a 2-coin leaf for an 8-coin pool —
    ///      a confident, complete-looking, WRONG breadcrumb that a consumer joins on. A missing leaf is safe; a
    ///      wrong one is not. The sweep walks the budget across the whole transition so it cannot miss the window
    ///      where the inner call dies on 63/64 while the outer frame lives on the remaining 1/64.
    function test_leafDegradation_isAllOrNothing() public view {
        uint256 complete;
        uint256 absent;
        for (uint256 budget = 20_000; budget <= 400_000; budget += 2_000) {
            (bool ok, uint256 segments, string memory leaf) =
                harness.labelLeaf(address(coldProxiedCurveMeta), abi.encode(address(coldProxiedPool)), budget);
            if (!ok || segments == 0) continue; // budget too small to even return; not a rendering outcome
            if (segments == 1) {
                absent++;
                continue;
            }
            assertEq(_countSlashes(leaf), 7, "an 8-coin pool renders 7 separators or no leaf at all");
            complete++;
        }
        assertGt(absent, 0, "the sweep must cross budgets where the leaf is dropped");
        assertGt(complete, 0, "the sweep must cross budgets where the leaf resolves");
    }

    function _countSlashes(string memory s) private pure returns (uint256 n) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; i++) {
            if (b[i] == "/") n++;
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Acceptance — no leaf that renders without the ceiling may stop rendering with it
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A wide Curve leaf must resolve in full, measured COLD against flat tokens.
    function test_wideCurveLeaf_resolvesCold() public {
        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(coldCurveMeta), abi.encode(address(coldPool)), BUDGET);

        assertTrue(ok, "an honest 8-coin pool must label successfully");
        assertEq(segments, 2, "category plus a full leaf - the leaf must NOT have been dropped");
        emit log_named_uint("cold 8-coin Curve leaf, flat tokens", used);
    }

    /// @notice The same leaf against ERC-1967 tokens — the shape mainnet actually has.
    function test_wideCurveLeaf_proxiedTokens_resolvesCold() public {
        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(coldProxiedCurveMeta), abi.encode(address(coldProxiedPool)), BUDGET);

        assertTrue(ok, "an honest 8-coin pool of proxied tokens must label successfully");
        assertEq(segments, 2, "the leaf must NOT have been dropped");
        emit log_named_uint("cold 8-coin Curve leaf, ERC-1967 tokens", used);
    }

    /// @notice A 33-token Balancer V2 pool must still render its leaf.
    /// @dev Balancer V2 permits up to 50 tokens in a pool and a ManagedPool's token list is MUTABLE after the
    ///      instance is governed, so the widest case is not something registration can screen out. 33 is the
    ///      point at which a 500k ceiling first dropped this leaf against proxied tokens, which is why it is
    ///      pinned separately from 50 — it is the regression this ceiling exists to avoid.
    function test_balancerV2_33Tokens_rendersCold() public {
        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(coldBalancer33), abi.encode(coldPoolId33), BUDGET);

        assertTrue(ok, "a 33-token pool must label successfully");
        assertEq(segments, 2, "the leaf must NOT have been dropped");
        assertLt(used, BOUNDED_CEILING, "and it must still be bounded");
        emit log_named_uint("cold Balancer V2 n=33 leaf, ERC-1967 tokens", used);
    }

    /// @notice And at the protocol maximum of 50 tokens.
    function test_balancerV2_50Tokens_rendersCold() public {
        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(coldBalancer50), abi.encode(coldPoolId50), BUDGET);

        assertTrue(ok, "the widest pool Balancer V2 permits must label successfully");
        assertEq(segments, 2, "the leaf must NOT have been dropped");
        assertLt(used, BOUNDED_CEILING, "and it must still be bounded");
        emit log_named_uint("cold Balancer V2 n=50 leaf, ERC-1967 tokens", used);
    }

    /// @notice Under NAVCalculator's real per-position label budget, a hostile coordinate still returns its
    ///         category rather than being killed outright by the outer cap.
    /// @dev The composition the two ceilings have to satisfy: `LABEL_LEAF_GAS` plus the enclosing read's own
    ///      overhead must fit inside `NAVCalculator._LABEL_READ_GAS`. Were the leaf ceiling raised to meet or
    ///      exceed 63/64 of the outer one, the outer cap would bind first — the inner ceiling would stop
    ///      bounding anything on the verbose path, and a starved label would come back empty instead of
    ///      degraded. This is the upper end of the band the constant can be chosen from.
    function test_hostileLeaf_underNavCalculatorLabelBudget_stillDegrades() public {
        CurvePoolsMetaBalanceAdapter meta = new CurvePoolsMetaBalanceAdapter(address(nav));
        Mock_BurningCoinsPool hostile = new Mock_BurningCoinsPool();

        // `NAVCalculator._LABEL_READ_GAS`, which is `private` there and so restated here.
        (bool ok,, uint256 segments) = harness.labelCost(address(meta), abi.encode(address(hostile)), 1_000_000);

        assertTrue(ok, "the label read must still answer under the outer per-position cap");
        assertEq(segments, 1, "and answer with the category, not nothing at all");
    }

    /// @notice The Fluid leaf must render at mainnet's current registered-asset count, with room to spare.
    /// @dev This is the leaf that binds the ceiling, and it binds for a reason that has nothing to do with
    ///      Fluid: `vaultPairSymbols` pulls the ENTIRE registered-asset array across the call boundary to
    ///      resolve two symbols, so its cost is linear in how many assets happen to be registered protocol-wide.
    ///      Registering an unrelated asset is a routine MANAGER config TX, so the headroom above today's count
    ///      is a budget denominated in future config changes — not a static margin.
    function test_fluidLeaf_atMainnetRegistrySize_rendersCold() public {
        (bool ok, uint256 used, uint256 segments) =
            harness.labelCost(address(coldFluidMeta), abi.encode(address(coldFluidVault)), BUDGET);

        assertTrue(ok, "the Fluid leaf must label successfully at mainnet's registry size");
        assertEq(segments, 2, "the leaf must NOT have been dropped");
        assertLt(used, BOUNDED_CEILING, "and it must still be bounded");
        emit log_named_uint("cold Fluid leaf gas at 43 registered assets", used);
    }
}
