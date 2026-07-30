// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CurveGaugesMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockCurveToken,
    MockCurveGauge,
    MockCurveMinter,
    MockCurvePool
} from "test/balances/MetaBalanceAdapters/CurveMocks.sol";

/// @notice Burns every drop of gas forwarded to it.
contract GasBomb {
    fallback() external {
        // solhint-disable-next-line no-empty-blocks
        while (true) {}
    }
}

/// @notice Answers with a huge reply, to charge the CALLER for returndata it does not want.
contract FatReturn {
    fallback(bytes calldata) external returns (bytes memory) {
        return new bytes(640_000);
    }
}

/// @title CurveRegistryGasBoundsTest
/// @notice Pins the gas bounds on `CurvePoolLib`'s Curve-registry resolution path.
/// @dev **Why this file exists.** `getPool`'s registry fallback is the only place in `CurvePoolLib` that calls a
///      contract reached through a pointer a third party can REPOINT: `CURVE_ADDRESS_PROVIDER` is a fixed
///      address, but its `get_registry()` is mutable by the AddressProvider admin, so the contract answering the
///      second hop — and the pool address it names, which is then probed with `coins()` — are not fixed at
///      deploy time.
///
///      A hostile or broken answer there must not be able to make the read UNAVAILABLE, which is a worse outcome
///      than the under-report the fallback exists to fix. `MetaBalanceAdapter`'s per-instance catch deliberately
///      re-raises gas exhaustion instead of substituting empty legs, so one Curve gauge starving its frame makes
///      `getAccountNav` revert for the WHOLE account and starves every adapter after it in a `PriceFeedLib`
///      sweep.
///
///      Each test therefore asserts the semantic property — *the read still completes on a modest budget* —
///      rather than a pinned gas figure, which would be a warm measurement of the wrong thing. All four fail if
///      the bounds are removed: with hand-rolled `target.staticcall(...)` each hop forwards 63/64 of the frame
///      and, destructured as `(bool, bytes memory)`, `returndatacopy`s the entire reply at the caller's expense,
///      so the budgets below are not enough to survive a bomb or a 640 KB answer. Mutation-verified in both
///      directions.
contract CurveRegistryGasBoundsTest is Test {
    address internal constant CURVE_ADDRESS_PROVIDER = 0x0000000022D53366457F9d5E68Ec105046FC4383;
    address internal constant REGISTRY = address(0xEEE9);

    /// @dev The DISCRIMINATING budget, chosen by measuring both directions rather than by looking generous.
    ///      Bounded, these reads cost ~200-305k. Unbounded, a gas bomb pushes them to ~4.92M — because the bomb
    ///      eats 63/64 of the frame and the read then limps to completion on the 1/64 remainder. So an earlier
    ///      draft of this file used 5_000_000 and TWO of these tests passed against deliberately unbounded code:
    ///      they reached the hop without pinning it. At 1_000_000 the 1/64 remainder is far too thin to finish,
    ///      so every test here now fails when its bound is removed. Recorded because the trap is invisible
    ///      without mutating in both directions.
    uint256 internal constant BUDGET = 1_000_000;

    Mock_NAVCalculator nav;
    CurveGaugesMetaBalanceAdapter meta;
    MockCurveMinter minter;
    MockCurveToken crv;
    MockCurveToken orphanLp;
    MockCurveGauge gauge;
    address alice = address(0xA11CE);

    function setUp() public {
        nav = new Mock_NAVCalculator();
        minter = new MockCurveMinter();
        crv = new MockCurveToken("CRV", 18);
        nav.registerAsset(address(crv), 18, "CRV");

        // An LP token answering neither coins() nor minter(), so getPool reaches the registry step.
        orphanLp = new MockCurveToken("orphanLP", 18);
        gauge = new MockCurveGauge(address(orphanLp));
        gauge.setStaked(alice, 100e18);

        meta = new CurveGaugesMetaBalanceAdapter(address(minter), address(crv), address(nav));
    }

    function _ins(address g) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(g)));
    }

    /// @dev Calls the adapter with a CAPPED frame. `ok == false` is the failure this file is about: the read
    ///      became unavailable because a third-party answer ate the budget.
    function _readCompletes(uint256 budget) internal view returns (bool ok) {
        (ok,) = address(meta).staticcall{gas: budget}(
            abi.encodeCall(meta.getAdapterPositionsForInstances, (alice, _ins(address(gauge)), address(0)))
        );
    }

    /// @notice Control: with no AddressProvider deployed the read completes and reports nothing.
    function test_noProvider_readCompletesAndReportsNothing() public view {
        assertTrue(_readCompletes(BUDGET), "clean read must complete");
        INAVCalculator.PositionBalance[] memory pos =
            meta.getAdapterPositionsForInstances(alice, _ins(address(gauge)), address(0));
        // orphanLp is unregistered, so the undecomposable-LP arm emits nothing — but the read SUCCEEDS.
        assertEq(pos.length, 0, "unregistered LP must yield no legs, not a revert");
    }

    /// @notice Hop 1: a gas bomb AT the AddressProvider cannot starve the read.
    function test_gasBombAtProvider_readStillCompletes() public {
        vm.etch(CURVE_ADDRESS_PROVIDER, address(new GasBomb()).code);
        assertTrue(_readCompletes(BUDGET), "unbounded get_registry() hop: a gas bomb made the NAV read revert");
    }

    /// @notice Hop 2: a repointed registry that burns gas cannot starve the read.
    function test_gasBombRegistry_readStillCompletes() public {
        address bomb = address(new GasBomb());
        vm.mockCall(CURVE_ADDRESS_PROVIDER, abi.encodeWithSignature("get_registry()"), abi.encode(bomb));
        assertTrue(_readCompletes(BUDGET), "unbounded get_pool_from_lp_token() hop: a gas bomb starved the read");
    }

    /// @notice Hop 3: the POOL the registry names is probed with `coins()`. A bomb there must not starve either.
    /// @dev This is the hop that made bounding the other two decorative: `_hasCoinMethod` is called on an
    ///      address the registry chose, and it probes twice.
    function test_gasBombPoolFromRegistry_readStillCompletes() public {
        address bomb = address(new GasBomb());
        vm.mockCall(CURVE_ADDRESS_PROVIDER, abi.encodeWithSignature("get_registry()"), abi.encode(REGISTRY));
        vm.mockCall(REGISTRY, abi.encodeWithSignature("get_pool_from_lp_token(address)"), abi.encode(bomb));
        assertTrue(_readCompletes(BUDGET), "unbounded _hasCoinMethod probe: a gas-bomb pool starved the read");
    }

    /// @notice Hop 4: the `get_lp_token` ROUND-TRIP back through the registry must be bounded too.
    /// @dev Added because a mutation proved the other four tests do not cover it. Unbounding
    ///      `_lpTokenFromRegistry` alone left all 38 Curve unit tests green, because every other test in this
    ///      file short-circuits before the round-trip: they hand the registry a gas-bombing POOL, and
    ///      `_hasCoinMethod` (now bounded) rejects it, so `getPool` returns before validating.
    ///
    ///      Reaching the round-trip needs the registry to name a pool that genuinely ANSWERS `coins()`. So the
    ///      registry here is a gas bomb with `get_pool_from_lp_token` mocked over it to return a real
    ///      `MockCurvePool`; `get_lp_token` is deliberately left unmocked and therefore hits the bomb.
    function test_gasBombLpTokenRoundTrip_readStillCompletes() public {
        address[] memory coins = new address[](1);
        coins[0] = address(crv);
        MockCurvePool pool = new MockCurvePool(coins);

        vm.etch(REGISTRY, address(new GasBomb()).code);
        vm.mockCall(CURVE_ADDRESS_PROVIDER, abi.encodeWithSignature("get_registry()"), abi.encode(REGISTRY));
        vm.mockCall(REGISTRY, abi.encodeWithSignature("get_pool_from_lp_token(address)"), abi.encode(address(pool)));

        assertTrue(_readCompletes(BUDGET), "unbounded get_lp_token() round-trip: a gas bomb starved the read");
    }

    /// @notice A 640 KB registry answer must not be copied into the caller's frame.
    /// @dev Separate from the bomb tests because the mechanism differs: this costs the caller memory-expansion
    ///      and copy gas for bytes it discards, rather than burning the callee's stipend.
    function test_fatRegistryReply_isNotCopiedIntoTheFrame() public {
        vm.etch(CURVE_ADDRESS_PROVIDER, address(new FatReturn()).code);
        assertTrue(_readCompletes(1_000_000), "unbounded hop returndatacopy'd a 640 KB reply at caller expense");
    }
}
