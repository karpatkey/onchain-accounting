// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {Test} from "forge-std/Test.sol";
import {CapBalanceAdapter} from "src/balances/BalanceAdapters/CapBalanceAdapter.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
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
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
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
    ///      Cap has NO on-chain signal marking that [] as "by design". It advertises exactly the same interface
    ///      set as every positionId-independent adapter — {IBalanceAdapter, IPositionDescribable, IERC165} from
    ///      BalanceAdapterBase — and unlike the assisted family it carries no `IAssistedBalanceAdapter` marker.
    ///      So a configuration view cannot tell "Cap has per-position shapes" from "Cap is broken", and cannot
    ///      list its two shapes at all. That indistinguishability is exactly what motivates the deferred
    ///      `IPositionEnumerable`; Cap is the adapter that needs it.
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
