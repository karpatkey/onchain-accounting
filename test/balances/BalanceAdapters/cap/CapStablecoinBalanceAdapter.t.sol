// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CapStablecoinBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapStablecoinBalanceAdapter.sol";
import {MockCUsd, MockStcUsd, MockUsdc} from "./CapMocks.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title CapStablecoinBalanceAdapter unit tests (no fork)
/// @dev The cUSD half of what used to be one `CapBalanceAdapter`. The assertions that were about the SPLIT — one
///      shape, one uniform label pair, no trace of the sibling leg — are marked as such, because they are what makes
///      each segment safely overridable through `AssetKindRegistry.setAdapterLabels`.
contract CapStablecoinBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockCUsd mockCUsd;
    MockStcUsd mockStcUsd;
    MockUsdc mockUsdc;
    CapStablecoinBalanceAdapter adapter;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        mockUsdc = new MockUsdc();
        mockCUsd = new MockCUsd(address(mockUsdc));
        mockStcUsd = new MockStcUsd();
        nav.registerAsset(address(mockUsdc), 6, "USDC");
        adapter = new CapStablecoinBalanceAdapter(address(mockCUsd), address(mockUsdc), address(nav));
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructor_invalidArgs_zeroCUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapStablecoinBalanceAdapter(address(0), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_zeroUsdc() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapStablecoinBalanceAdapter(address(mockCUsd), address(0), address(nav));
    }

    function test_constructor_invalidArgs_zeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapStablecoinBalanceAdapter(address(mockCUsd), address(mockUsdc), address(0));
    }

    function test_constructor_invalidArgs_nonContractCUsd() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "cUSD"));
        new CapStablecoinBalanceAdapter(address(0xdead), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_nonContractUsdc() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "USDC"));
        new CapStablecoinBalanceAdapter(address(mockCUsd), address(0xdead), address(nav));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new CapStablecoinBalanceAdapter(address(mockCUsd), address(mockUsdc), address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(adapter.CUSD()), address(mockCUsd));
        assertEq(adapter.UNDERLYING_TOKEN(), address(mockUsdc));
        assertEq(address(adapter.NAV_CALCULATOR()), address(nav));
    }

    // ============================================
    // Interface compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionEnumerable).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_protocolName_namesTheProtocolNotTheLeg() public view {
        assertEq(adapter.protocolName(), "Cap", "both leg adapters must name the PROTOCOL, not their product");
    }

    // ============================================
    // Labels — the whole point of the split
    // ============================================

    /// @dev **The property the split exists to create.** Every positionId this adapter can emit resolves to the SAME
    ///      two literals, so a per-adapter `setAdapterLabels` override addresses a constant at each index. The
    ///      pre-split adapter returned `["Savings","stcUSD"]` for one positionId and `["Stablecoin","cUSD"]` for
    ///      another, so one override necessarily rewrote both legs.
    function test_positionLabels_areUniformAcrossEveryShapeThisAdapterEmits() public view {
        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1, "one leg, one shape");
        for (uint256 i; i < ids.length; ++i) {
            string[] memory labels = adapter.positionLabels(ids[i]);
            assertEq(labels.length, 2);
            assertEq(labels[0], "Stablecoin");
            assertEq(labels[1], "cUSD");
        }
    }

    /// @dev The sibling's token is a FOREIGN coordinate to this adapter and must take the `[]` exit — not the
    ///      sibling's labels. An implementation that kept the old two-branch body would answer `["Savings","stcUSD"]`
    ///      here and re-create the very per-position variance the split removed.
    function test_positionLabels_siblingLegToken_returnsEmpty() public view {
        assertEq(adapter.positionLabels(abi.encode(address(mockStcUsd))).length, 0);
    }

    /// @dev Configuration-view probe. This adapter derives its breadcrumb from the positionId, so the empty probe
    ///      answers `[]`; {IPositionEnumerable}'s ERC-165 bit is what marks that as deliberate rather than broken.
    function test_positionLabels_emptyProbe_returnsEmpty() public view {
        assertEq(adapter.positionLabels("").length, 0);
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0);
    }

    /// @dev The dirty-word guard, carried over unchanged from the pre-split adapter. `dirtyCUsd`'s low 160 bits ARE
    ///      `CUSD`, so an implementation that masked instead of rejecting would label a foreign coordinate as a real
    ///      Cap leg. Only the `raw >> 160` check gives `[]`.
    function test_positionLabels_dirty32ByteWord_returnsEmptyRatherThanReverting() public view {
        assertEq(adapter.positionLabels(abi.encode(type(uint256).max)).length, 0);

        uint256 dirtyCUsd = uint256(uint160(address(mockCUsd))) | (uint256(1) << 160);
        assertEq(adapter.positionLabels(abi.encode(dirtyCUsd)).length, 0);

        uint256 dirtyCUsdHigh = uint256(uint160(address(mockCUsd))) | (uint256(1) << 255);
        assertEq(adapter.positionLabels(abi.encode(dirtyCUsdHigh)).length, 0);

        // The clean word still resolves.
        assertEq(adapter.positionLabels(abi.encode(address(mockCUsd))).length, 2);
    }

    /// @dev The `== 32` boundary. `abi.decode` ignores trailing bytes, so a `>= 32` guard would label a foreign
    ///      multi-word coordinate whose first word is `CUSD` as a real Cap leg.
    function test_positionLabels_overlongPositionId_returnsEmpty() public view {
        assertEq(adapter.positionLabels(abi.encode(address(mockCUsd), uint256(42))).length, 0);
        assertEq(adapter.positionLabels(abi.encodePacked(abi.encode(address(mockCUsd)), hex"01")).length, 0);

        assertEq(adapter.positionLabels(abi.encode(address(mockCUsd))).length, 2);
    }

    // ============================================
    // IPositionEnumerable
    // ============================================

    function test_positionIds_advertisesOnlyItsOwnLeg() public view {
        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], abi.encode(address(mockCUsd)));
    }

    /// @dev The join guarantee: the advertised bytes must be byte-identical to what `getAdapterPositions` emits.
    function test_positionIds_matchTheEmittedPositionIdExactly() public {
        mockCUsd.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].positionId, adapter.positionIds()[0]);
    }

    /// @dev Shapes describe what the adapter CAN report, not what anyone holds.
    function test_positionIds_areAccountIndependent() public view {
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(adapter.positionIds().length, 1);
    }

    // ============================================
    // Balance getters
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockUsdc));
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_zeroAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_cUsdHolding() public {
        mockCUsd.setBalance(alice, 100e18);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 100e18);
        assertFalse(isDebt);
    }

    /// @dev **The behaviour change the split DOES make, pinned rather than glossed.** The pre-split adapter's
    ///      aggregate getter returned cUSD + stcUSD from one contract. Each adapter now reports its own leg only, so
    ///      stcUSD held by the same account is invisible here — and the sum across the two registered adapters is
    ///      what reproduces the old figure.
    function test_getAdapterBalanceForAsset_ignoresTheSiblingLeg() public {
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 100e18, "this adapter reports the cUSD leg and nothing else");
    }

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
    // getAdapterPositions
    // ============================================

    function test_getAdapterPositions_unknownAccount_returnsEmpty() public view {
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
    }

    function test_getAdapterPositions_zeroAccount_returnsEmpty() public view {
        assertEq(adapter.getAdapterPositions(address(0), address(0)).length, 0);
    }

    function test_getAdapterPositions_usdcUnregistered_returnsEmpty() public {
        nav.unregisterAssetHelper(address(mockUsdc));
        mockCUsd.setBalance(alice, 100e18);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
    }

    function test_getAdapterPositions_assetFilterMismatch_returnsEmpty() public {
        mockCUsd.setBalance(alice, 100e18);
        assertEq(adapter.getAdapterPositions(alice, address(0xdead)).length, 0);
        assertEq(adapter.getAdapterPositions(alice, address(mockUsdc)).length, 1);
    }

    /// @dev The full emitted shape: identity, kind and amount. `positionKind` and the three taxonomy levels are
    ///      unchanged from the pre-split adapter's cUSD leg, which is why the integration snapshot — keyed on
    ///      protocolId + positionId + positionKind — is byte-identical across the split.
    function test_getAdapterPositions_emitsTheCUsdLeg() public {
        mockCUsd.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(mockUsdc));
        assertEq(positions[0].balanceAdapter, address(adapter), "balanceAdapter is always address(this)");
        assertEq(positions[0].amount, 100e18);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].positionId, abi.encode(address(mockCUsd)));
        assertTrue(positions[0].positionKind == PositionKind.Supplied, "held cUSD is Supplied");
        assertFalse(positions[0].isLocked);
        assertEq(positions[0].positionInstanceId, bytes32(0));
    }
}
