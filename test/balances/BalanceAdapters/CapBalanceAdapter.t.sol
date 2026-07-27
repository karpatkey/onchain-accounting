// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {Test} from "forge-std/Test.sol";
import {CapBalanceAdapter} from "src/balances/BalanceAdapters/CapBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock for the cUSD token (ERC20 + burn-quote)
contract MockCUsd {
    address private _usdc;
    mapping(address => uint256) public balanceOf;

    constructor(address usdc_) {
        _usdc = usdc_;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    /// @notice Returns amountIn as amountOut (1:1, no fee) for unit test simplicity
    function getBurnAmount(address, uint256 amountIn) external pure returns (uint256 amountOut, uint256 fee) {
        return (amountIn, 0);
    }
}

/// @notice Minimal mock for the stcUSD token (ERC4626-like — convertToAssets 1:1)
contract MockStcUsd {
    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity in unit tests
    }
}

/// @notice Minimal USDC mock
contract MockUsdc {
    string public symbol = "USDC";
    uint8 public decimals = 6;
}

/// @title CapBalanceAdapter unit tests (no fork)
contract CapBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockCUsd mockCUsd;
    MockStcUsd mockStcUsd;
    MockUsdc mockUsdc;
    CapBalanceAdapter adapter;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        mockUsdc = new MockUsdc();
        mockCUsd = new MockCUsd(address(mockUsdc));
        mockStcUsd = new MockStcUsd();
        nav.registerAsset(address(mockUsdc), 6, "USDC");
        adapter = new CapBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(mockUsdc), address(nav));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroCUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapBalanceAdapter(address(0), address(mockStcUsd), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_zeroStcUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapBalanceAdapter(address(mockCUsd), address(0), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_zeroUsdc() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(0), address(nav));
    }

    function test_constructor_invalidArgs_nonContractCUsd() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "cUSD"));
        new CapBalanceAdapter(address(0xdead), address(mockStcUsd), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new CapBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(mockUsdc), address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(adapter.CUSD()), address(mockCUsd));
        assertEq(address(adapter.STCUSD()), address(mockStcUsd));
        assertEq(adapter.USDC(), address(mockUsdc));
        assertEq(address(adapter.NAV_CALCULATOR()), address(nav));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// @dev The ERC165 bit is the whole point of the interface being optional: a configuration view uses it to
    ///      decide whether to call `positionIds()` at all. Asserted separately from the base set because it is
    ///      contributed by Cap's own `super`-chaining override, not by {BalanceAdapterBase}.
    function test_supportsInterface_advertisesPositionEnumerable() public view {
        assertTrue(adapter.supportsInterface(type(IPositionEnumerable).interfaceId));
    }

    // ============================================
    // IPositionEnumerable
    // ============================================

    /// @dev Cap's two shapes, reported account-independently — this is what a configuration view could not get
    ///      before, because Cap derives its breadcrumb per positionId and so answers `positionLabels("")` with [].
    ///      Asserted as a SET: {IPositionEnumerable} disclaims ordering, so pinning "index 0 is cUSD" would
    ///      assert more than the interface promises and fail a reordered-but-correct implementation.
    function test_positionIds_returnsBothShapes() public view {
        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 2, "Cap has exactly two shapes");
        assertTrue(_contains(ids, abi.encode(address(mockCUsd))), "the cUSD shape is advertised");
        assertTrue(_contains(ids, abi.encode(address(mockStcUsd))), "the stcUSD shape is advertised");
    }

    /// @dev Each enumerated shape must resolve to its breadcrumb — the pairing a configuration view renders.
    ///      Together with the probe returning [] (asserted elsewhere in this file) this is the before/after:
    ///      the labels always existed, they were simply unreachable without already knowing a positionId.
    ///      Driven off the token addresses rather than off `ids[0]`/`ids[1]` so it stays order-independent.
    function test_positionIds_eachShapeResolvesItsLabels() public view {
        string[] memory cusd = adapter.positionLabels(abi.encode(address(mockCUsd)));
        assertEq(cusd.length, 2);
        assertEq(cusd[0], "Stablecoin");
        assertEq(cusd[1], "cUSD");

        string[] memory stcusd = adapter.positionLabels(abi.encode(address(mockStcUsd)));
        assertEq(stcusd.length, 2);
        assertEq(stcusd[0], "Savings");
        assertEq(stcusd[1], "stcUSD");
    }

    /// @dev **The load-bearing assertion of the whole interface.** {IPositionEnumerable} requires each returned id
    ///      to be byte-identical to the `PositionBalance.positionId` the adapter emits for that shape, because
    ///      that is what lets a consumer JOIN the configuration view against real positions. An implementation
    ///      that returned ids which merely *label* correctly while differing from the emitted bytes would satisfy
    ///      every other test in this file and still silently break that join — which is exactly the trap
    ///      `AaveV3InstancesMetaBalanceAdapter` sits in (its instance coordinate is a DataProvider, but it emits
    ///      the resolved Pool; both label identically, so only a byte comparison catches it).
    ///
    ///      The join is by VALUE, not by index — see `test_positionIds_joinIsByValueNotByIndex` for why an
    ///      index-wise comparison would be wrong here even though both arrays happen to line up when, as below,
    ///      every leg is funded.
    function test_positionIds_matchTheEmittedPositionIdsExactly() public {
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 2, "both legs must be live for this comparison to be meaningful");

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, positions.length, "one advertised shape per emitted leg");
        // Both directions: every emitted positionId is advertised, and every advertised shape was emitted.
        for (uint256 i; i < positions.length; ++i) {
            assertTrue(_contains(ids, positions[i].positionId), "emitted positionId must be an advertised shape");
        }
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(_emits(positions, ids[i]), "advertised shape must be an emitted positionId");
        }
    }

    /// @dev **Why the join above is by value.** `getAdapterPositions` compacts out any leg with a zero balance,
    ///      so the emitted array is not index-aligned with `positionIds()`. With only stcUSD funded, the single
    ///      emitted position pairs with the SECOND advertised shape — an index-wise assertion would compare it
    ///      against the cUSD shape and fail on a perfectly correct implementation.
    ///
    ///      This is the trap a consumer (or the next adapter author copying this file) would otherwise fall into,
    ///      and it is exactly what {IPositionEnumerable}'s "ordering is not significant" clause is protecting.
    function test_positionIds_joinIsByValueNotByIndex() public {
        mockStcUsd.setBalance(alice, 50e18);
        // cUSD deliberately left at zero.

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1, "only the funded leg is emitted");

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 2, "both shapes are still advertised");

        // The value join holds...
        assertTrue(_contains(ids, positions[0].positionId), "emitted positionId is an advertised shape");
        assertEq(positions[0].positionId, abi.encode(address(mockStcUsd)), "and it is the stcUSD shape");
        // ...while zipping the two arrays is impossible: they are different lengths. Stated this way rather than
        // as `ids[0] != positions[0].positionId`, which would itself assume an enumeration order.
        assertTrue(ids.length != positions.length, "advertised and emitted arrays are not index-alignable");
    }

    /// @dev Shapes describe what the adapter CAN report, not what anyone holds: with no balances at all,
    ///      `getAdapterPositions` emits nothing while `positionIds()` still advertises both shapes. A
    ///      configuration view must render the same rows whether or not an account is funded.
    function test_positionIds_areAccountIndependent() public view {
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0, "no balances -> no positions");
        assertEq(adapter.positionIds().length, 2, "shapes are advertised regardless");
    }

    /// @dev Set membership over `bytes`, compared by hash — the join {IPositionEnumerable} specifies. Used
    ///      instead of index-wise `assertEq` because the interface disclaims ordering.
    function _contains(bytes[] memory haystack, bytes memory needle) private pure returns (bool) {
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(haystack[i]) == keccak256(needle)) return true;
        }
        return false;
    }

    /// @dev The reverse direction: is `needle` among the positionIds actually emitted?
    function _emits(INAVCalculator.PositionBalance[] memory positions, bytes memory needle)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < positions.length; ++i) {
            if (keccak256(positions[i].positionId) == keccak256(needle)) return true;
        }
        return false;
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockUsdc));
    }

    // ============================================
    // getAdapterBalanceForAsset Tests
    // ============================================

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_unknownAccount() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_cUsdOnly() public {
        // 100 cUSD (1:1 mock), no stcUSD
        mockCUsd.setBalance(alice, 100e18);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 100e18);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_stcUsdOnly() public {
        // 200 stcUSD (1:1 mock → 200 cUSD → 200 USDC)
        mockStcUsd.setBalance(alice, 200e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 200e18);
    }

    function test_getAdapterBalanceForAsset_bothPositions() public {
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 150e18); // combined: 100 cUSD + 50 stcUSD → 150 USDC (1:1 mock)
    }

    // ============================================
    // getAdapterBalances Tests
    // ============================================

    function test_getAdapterBalances_unknownAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterBalances_withPosition() public {
        mockCUsd.setBalance(alice, 300e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockUsdc));
        assertEq(amounts[0], 300e18);
        assertFalse(isDebt[0]);
    }

    // ============================================
    // getAdapterPositions Tests
    // ============================================

    function test_getAdapterPositions_unknownAccount_returnsEmpty() public view {
        // USDC is registered, but alice holds no cUSD/stcUSD, so no legs are emitted
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_usdcUnregistered_returnsEmpty() public {
        // If USDC is not registered the whole position is skipped, regardless of holdings
        nav.unregisterAssetHelper(address(mockUsdc));
        mockCUsd.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_cUsdLeg_labels() public {
        mockCUsd.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);

        assertEq(positions[0].positionId, abi.encode(address(mockCUsd)));
        string[] memory labels = adapter.positionLabels(positions[0].positionId);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Stablecoin");
        assertEq(labels[1], "cUSD");
    }

    function test_getAdapterPositions_stcUsdLeg_labels() public {
        mockStcUsd.setBalance(alice, 50e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);

        assertEq(positions[0].positionId, abi.encode(address(mockStcUsd)));
        string[] memory labels = adapter.positionLabels(positions[0].positionId);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Savings");
        assertEq(labels[1], "stcUSD");
    }

    function test_getAdapterPositions_bothLegs_labels() public {
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 2);

        // Leg 0 = cUSD (Stablecoin), leg 1 = stcUSD (Savings) — emission order in the adapter
        string[] memory labels0 = adapter.positionLabels(positions[0].positionId);
        string[] memory labels1 = adapter.positionLabels(positions[1].positionId);
        assertEq(labels0[0], "Stablecoin");
        assertEq(labels0[1], "cUSD");
        assertEq(labels1[0], "Savings");
        assertEq(labels1[1], "stcUSD");
    }

    /// @dev Configuration-view probe. Unlike the positionId-independent adapters, Cap derives the breadcrumb from
    ///      the positionId and has TWO shapes (cUSD and stcUSD), so `positionLabels("")` returns [] rather than
    ///      guessing one of them. The shapes are still reachable against real positionIds (asserted above).
    ///
    ///      An empty probe is NOT self-describing: on its own it cannot be told apart from a broken adapter,
    ///      because nothing else in the base interface set — {IBalanceAdapter, IPositionDescribable, IERC165} —
    ///      marks the [] as "by design", and the `IAssistedBalanceAdapter` marker does not discriminate either
    ///      (it means "coordinates are fed externally", and two of the three assisted adapters answer this same
    ///      probe with a constant non-empty breadcrumb).
    ///
    ///      That indistinguishability is what {IPositionEnumerable} closes, and Cap now implements it: the ERC-165
    ///      bit is the signal that this [] was a real answer, and `positionIds()` lists the two shapes the probe
    ///      cannot. See the IPositionEnumerable section above.
    function test_positionLabels_emptyProbe_returnsEmptyForAMultiShapeAdapter() public view {
        assertEq(adapter.positionLabels("").length, 0);
        // Sub-32-byte input hits the `positionId.length < 32` guard, so it returns [] without reaching the decode.
        // This does NOT establish general malformed-input safety: a 32-byte word with dirty high bits reaches
        // `abi.decode(..., (address))` and reverts (asserted below).
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0);
    }

    /// @dev Documents a real limit of the length guard rather than asserting the adapter is malformed-input-safe.
    ///      `positionLabels` is reached from NAVCalculator's verbose reads via a fail-open staticcall, and the
    ///      positionIds Cap itself emits are always clean 32-byte addresses, so this is not reachable on the NAV
    ///      path. It IS reachable for a configuration view that probes with an arbitrary 32-byte word (e.g. a
    ///      bytes32 market/pool id copied from another adapter), which gets `execution reverted`, not [].
    ///      Widening the guard is a production-code change and deliberately out of scope for this tests-only PR.
    function test_positionLabels_dirty32ByteWord_revertsRatherThanReturningEmpty() public {
        vm.expectRevert();
        adapter.positionLabels(abi.encode(type(uint256).max));
    }
}
