// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {CapBalanceAdapter} from "src/balances/protocols/CapBalanceAdapter.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
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
    MockBalances mockBalances;
    MockCUsd mockCUsd;
    MockStcUsd mockStcUsd;
    MockUsdc mockUsdc;
    CapBalanceAdapter adapter;

    address alice = makeAddr("alice");

    function setUp() public {
        mockBalances = new MockBalances();
        mockUsdc = new MockUsdc();
        mockCUsd = new MockCUsd(address(mockUsdc));
        mockStcUsd = new MockStcUsd();
        adapter =
            new CapBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(mockUsdc), address(mockBalances));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroCUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapBalanceAdapter(address(0), address(mockStcUsd), address(mockUsdc), address(mockBalances));
    }

    function test_constructor_invalidArgs_zeroStcUsd() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapBalanceAdapter(address(mockCUsd), address(0), address(mockUsdc), address(mockBalances));
    }

    function test_constructor_invalidArgs_zeroUsdc() public {
        vm.expectRevert(InvalidArguments.selector);
        new CapBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(0), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractCUsd() public {
        vm.expectRevert("cUSD must be a contract");
        new CapBalanceAdapter(address(0xdead), address(mockStcUsd), address(mockUsdc), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new CapBalanceAdapter(address(mockCUsd), address(mockStcUsd), address(mockUsdc), address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(adapter.CUSD()), address(mockCUsd));
        assertEq(address(adapter.STCUSD()), address(mockStcUsd));
        assertEq(adapter.USDC(), address(mockUsdc));
        assertEq(address(adapter.NAV_CALCULATOR()), address(mockBalances));
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
        // MockBalances.getRegisteredAssets() returns [] — intersection is empty
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
