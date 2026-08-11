// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CapSavingsBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapSavingsBalanceAdapter.sol";
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

/// @title CapSavingsBalanceAdapter unit tests (no fork)
/// @dev The stcUSD half of what used to be one `CapBalanceAdapter`. Sibling of
///      `CapStablecoinBalanceAdapter.t.sol`; the last section pins the properties that only make sense across the
///      PAIR (identical protocol identity, disjoint shapes, and per-leg amounts summing to the pre-split total).
contract CapSavingsBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockCUsd mockCUsd;
    MockStcUsd mockStcUsd;
    MockUsdc mockUsdc;
    CapSavingsBalanceAdapter adapter;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        mockUsdc = new MockUsdc();
        mockCUsd = new MockCUsd(address(mockUsdc));
        mockStcUsd = new MockStcUsd();
        nav.registerAsset(address(mockUsdc), 6, "USDC");
        adapter = new CapSavingsBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(mockUsdc), address(nav));
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructor_invalidArgs_zeroCUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapSavingsBalanceAdapter(address(0), address(mockStcUsd), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_zeroStcUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapSavingsBalanceAdapter(address(mockCUsd), address(0), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_zeroUsdc() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapSavingsBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(0), address(nav));
    }

    function test_constructor_invalidArgs_nonContractStcUsd() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "stcUSD"));
        new CapSavingsBalanceAdapter(address(mockCUsd), address(0xdead), address(mockUsdc), address(nav));
    }

    function test_constructor_invalidArgs_nonContractCUsd() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "cUSD"));
        new CapSavingsBalanceAdapter(address(0xdead), address(mockStcUsd), address(mockUsdc), address(nav));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(adapter.CUSD()), address(mockCUsd));
        assertEq(address(adapter.STCUSD()), address(mockStcUsd));
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
        assertEq(adapter.protocolName(), "Cap");
    }

    // ============================================
    // Labels — the whole point of the split
    // ============================================

    /// @dev The uniformity property: every shape this adapter emits carries the same two literals, so a per-adapter
    ///      override addresses a constant at each index.
    function test_positionLabels_areUniformAcrossEveryShapeThisAdapterEmits() public view {
        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1, "one leg, one shape");
        for (uint256 i; i < ids.length; ++i) {
            string[] memory labels = adapter.positionLabels(ids[i]);
            assertEq(labels.length, 2);
            assertEq(labels[0], "Savings");
            assertEq(labels[1], "stcUSD");
        }
    }

    /// @dev cUSD is this adapter's burn-quote oracle but NOT its leg token, so its address is a foreign coordinate
    ///      here. An implementation that kept the pre-split two-branch body would answer `["Stablecoin","cUSD"]`.
    function test_positionLabels_siblingLegToken_returnsEmpty() public view {
        assertEq(adapter.positionLabels(abi.encode(address(mockCUsd))).length, 0);
    }

    function test_positionLabels_emptyProbe_returnsEmpty() public view {
        assertEq(adapter.positionLabels("").length, 0);
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0);
    }

    function test_positionLabels_dirty32ByteWord_returnsEmptyRatherThanReverting() public view {
        assertEq(adapter.positionLabels(abi.encode(type(uint256).max)).length, 0);

        uint256 dirtyStcUsd = uint256(uint160(address(mockStcUsd))) | (uint256(1) << 160);
        assertEq(adapter.positionLabels(abi.encode(dirtyStcUsd)).length, 0);

        assertEq(adapter.positionLabels(abi.encode(address(mockStcUsd))).length, 2);
    }

    function test_positionLabels_overlongPositionId_returnsEmpty() public view {
        assertEq(adapter.positionLabels(abi.encode(address(mockStcUsd), uint256(1))).length, 0);
        assertEq(adapter.positionLabels(abi.encode(address(mockStcUsd))).length, 2);
    }

    // ============================================
    // IPositionEnumerable
    // ============================================

    function test_positionIds_advertisesOnlyItsOwnLeg() public view {
        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], abi.encode(address(mockStcUsd)));
    }

    function test_positionIds_matchTheEmittedPositionIdExactly() public {
        mockStcUsd.setBalance(alice, 50e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].positionId, adapter.positionIds()[0]);
    }

    function test_positionIds_areAccountIndependent() public view {
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(adapter.positionIds().length, 1);
    }

    // ============================================
    // Balance getters & valuation
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockUsdc));
    }

    function test_getAdapterBalanceForAsset_stcUsdHolding() public {
        mockStcUsd.setBalance(alice, 200e18);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 200e18);
        assertFalse(isDebt);
    }

    /// @dev The two-hop quote: shares -> cUSD at the vault rate -> USDC at the burn quote. A rate other than 1:1 is
    ///      what distinguishes this leg's valuation from the stablecoin leg's single hop.
    function test_getAdapterBalanceForAsset_appliesTheVaultRate() public {
        mockStcUsd.setRate(1.5e18);
        mockStcUsd.setBalance(alice, 200e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 300e18, "200 shares at 1.5 cUSD/share -> 300 cUSD -> 300 USDC");
    }

    /// @dev The intermediate-zero path: a non-zero share balance that converts to zero cUSD must short-circuit before
    ///      the burn quote. Remove the `if (shares == 0)`/zero-amount guards and this still returns 0 with the 1:1
    ///      mock, which is why the rate is driven to 0 here instead.
    function test_getAdapterBalanceForAsset_sharesWorthZeroAssets_returnsZero() public {
        mockStcUsd.setRate(0);
        mockStcUsd.setBalance(alice, 200e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0, "and no position is emitted");
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_ignoresTheSiblingLeg() public {
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(amount, 50e18, "this adapter reports the stcUSD leg and nothing else");
    }

    function test_getAdapterBalances_withPosition() public {
        mockStcUsd.setBalance(alice, 300e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockUsdc));
        assertEq(amounts[0], 300e18);
        assertFalse(isDebt[0]);
    }

    function test_getAdapterBalances_unknownAccount() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
    }

    // ============================================
    // getAdapterPositions
    // ============================================

    function test_getAdapterPositions_usdcUnregistered_returnsEmpty() public {
        nav.unregisterAssetHelper(address(mockUsdc));
        mockStcUsd.setBalance(alice, 50e18);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
    }

    function test_getAdapterPositions_assetFilterMismatch_returnsEmpty() public {
        mockStcUsd.setBalance(alice, 50e18);
        assertEq(adapter.getAdapterPositions(alice, address(0xdead)).length, 0);
        assertEq(adapter.getAdapterPositions(alice, address(mockUsdc)).length, 1);
    }

    function test_getAdapterPositions_emitsTheStcUsdLeg() public {
        mockStcUsd.setBalance(alice, 50e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(mockUsdc));
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, 50e18);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].positionId, abi.encode(address(mockStcUsd)));
        assertTrue(positions[0].positionKind == PositionKind.Staking, "staked stcUSD is Staking");
        assertFalse(positions[0].isLocked);
        assertEq(positions[0].positionInstanceId, bytes32(0));
    }

    // ============================================
    // Cross-leg properties (only assertable over the PAIR)
    // ============================================

    /// @dev **The split must not change the total.** The pre-split adapter reported cUSD + stcUSD from one contract;
    ///      the pair must report the same sum, because both bottom out in the same `_usdcForCUsd` burn quote. This is
    ///      what makes the split a display change rather than an accounting one.
    function test_pair_sumsToThePreSplitTotal() public {
        CapStablecoinBalanceAdapter stablecoin =
            new CapStablecoinBalanceAdapter(address(mockCUsd), address(mockUsdc), address(nav));
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);

        (uint256 stableAmount,) = stablecoin.getAdapterBalanceForAsset(alice, address(mockUsdc));
        (uint256 savingsAmount,) = adapter.getAdapterBalanceForAsset(alice, address(mockUsdc));
        assertEq(stableAmount + savingsAmount, 150e18, "the pre-split combined figure, split across two adapters");
    }

    /// @dev The pair must share ONE protocol identity and expose DISJOINT shapes: same brand/id/subId and same
    ///      `protocolName`, different positionId and different `positionKind`. A second name or a second subId would
    ///      manufacture a phantom sibling protocol out of what is one product.
    function test_pair_sharesOneIdentityAndHasDisjointShapes() public {
        CapStablecoinBalanceAdapter stablecoin =
            new CapStablecoinBalanceAdapter(address(mockCUsd), address(mockUsdc), address(nav));
        mockCUsd.setBalance(alice, 100e18);
        mockStcUsd.setBalance(alice, 50e18);

        INAVCalculator.PositionBalance[] memory a = stablecoin.getAdapterPositions(alice, address(0));
        INAVCalculator.PositionBalance[] memory b = adapter.getAdapterPositions(alice, address(0));
        assertEq(a.length, 1);
        assertEq(b.length, 1);

        assertEq(stablecoin.protocolName(), adapter.protocolName(), "one protocol, one display name");
        assertEq(a[0].protocolBrand, b[0].protocolBrand, "same brand");
        assertEq(a[0].protocolId, b[0].protocolId, "same protocolId");
        assertEq(a[0].protocolSubId, b[0].protocolSubId, "same protocolSubId: one positionId decode schema");

        assertTrue(keccak256(a[0].positionId) != keccak256(b[0].positionId), "the legs are told apart by positionId...");
        assertTrue(a[0].positionKind != b[0].positionKind, "...and by positionKind");
    }
}
