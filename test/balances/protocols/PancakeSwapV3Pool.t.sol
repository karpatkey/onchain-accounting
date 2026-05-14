// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {PancakeSwapV3PoolBalanceOracle} from "src/balances/protocols/pancakeswap/PancakeSwapV3Pool.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

// =====================================================================
// Mocks
// =====================================================================

/// @notice Minimal PancakeSwap V3 pool mock — `slot0` returns `uint32 feeProtocol` (PCS-specific
///         ABI), the rest mirrors a Uniswap V3 pool. The wrapper's job is to read this layout
///         correctly; the parent's full math is exercised by `UniswapV3Pool.t.sol`, so this
///         suite only validates the override + construction.
contract MockPancakeV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    uint32 internal _feeProtocol;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_, uint32 feeProtocol_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
        _feeProtocol = feeProtocol_;
    }

    /// @dev Note the `uint32` in slot 6: this is the divergence the wrapper exists to handle.
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (_sqrtPriceX96, _tick, 0, 0, 0, _feeProtocol, false);
    }

    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
}

/// @notice Minimal NPM mock with no NFTs (only `balanceOf` is consulted by `_getAccountAggregates`
///         when an account has zero positions, which is all we exercise here).
contract MockEmptyNPM {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function tokenOfOwnerByIndex(address, uint256) external pure returns (uint256) {
        revert("not used");
    }

    function positions(uint256)
        external
        pure
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        revert("not used");
    }
}

/// @notice Minimal NAVCalculator mock — only `getRegisteredAssets()` is consumed.
contract MockNAVCalculatorWithRegistry {
    INAVCalculator.Asset[] internal _assets;

    function setAssets(INAVCalculator.Asset[] memory a) external {
        delete _assets;
        for (uint256 i = 0; i < a.length; i++) {
            _assets.push(a[i]);
        }
    }

    function getRegisteredAssets() external view returns (INAVCalculator.Asset[] memory) {
        return _assets;
    }
}

/// @notice Minimal ERC20-like mock so `address.code.length > 0` checks pass.
contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }
}

// =====================================================================
// Tests
// =====================================================================

/// @notice Wrapper-level tests for `PancakeSwapV3PoolBalanceOracle`.
/// @dev The full math/behaviour suite is in `test/balances/protocols/UniswapV3Pool.t.sol` —
///      everything except the `slot0` read flows through the parent unchanged. This file only
///      validates: (1) the constructor delegates correctly, (2) `supportsInterface` is wired,
///      and (3) the `_slot0` override decodes a `uint32 feeProtocol` ABI without reverting.
contract PancakeSwapV3PoolBalanceOracleTest is Test {
    MockPancakeV3Pool internal pool;
    MockEmptyNPM internal npm;
    MockNAVCalculatorWithRegistry internal nav;
    MockToken internal token0;
    MockToken internal token1;
    PancakeSwapV3PoolBalanceOracle internal oracle;

    address internal alice = makeAddr("alice");

    // PancakeSwap V3 0.25% tier (no Uniswap V3 analogue): fee=2500, tickSpacing=50.
    uint24 internal constant POOL_FEE = 2500;
    int24 internal constant POOL_TICK_SPACING = 50;

    function setUp() public {
        token0 = new MockToken("T0", 18);
        token1 = new MockToken("T1", 6);
        pool = new MockPancakeV3Pool(address(token0), address(token1), POOL_FEE, POOL_TICK_SPACING);
        npm = new MockEmptyNPM();
        nav = new MockNAVCalculatorWithRegistry();

        INAVCalculator.Asset[] memory a = new INAVCalculator.Asset[](2);
        a[0] = INAVCalculator.Asset({asset: address(token0), symbol: "T0", decimals: 18});
        a[1] = INAVCalculator.Asset({asset: address(token1), symbol: "T1", decimals: 6});
        nav.setAssets(a);

        oracle = new PancakeSwapV3PoolBalanceOracle(
            address(pool),
            address(npm),
            "PancakeSwap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    // ============================================
    // Construction (parent constructor runs through token0/token1/fee/tickSpacing)
    // ============================================

    function test_constructor_storesImmutables() public view {
        assertEq(oracle.POOL(), address(pool));
        assertEq(oracle.POSITION_MANAGER(), address(npm));
        assertEq(oracle.TOKEN0(), address(token0));
        assertEq(oracle.TOKEN1(), address(token1));
        assertEq(oracle.FEE(), POOL_FEE);
        assertEq(oracle.TICK_SPACING(), POOL_TICK_SPACING);
        assertEq(address(oracle.NAV_CALCULATOR()), address(nav));
    }

    function test_constructor_reverts_zeroPool() public {
        vm.expectRevert(InvalidArguments.selector);
        new PancakeSwapV3PoolBalanceOracle(
            address(0),
            address(npm),
            "PancakeSwap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function test_constructor_reverts_zeroPositionManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new PancakeSwapV3PoolBalanceOracle(
            address(pool),
            address(0),
            "PancakeSwap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function test_constructor_reverts_zeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new PancakeSwapV3PoolBalanceOracle(
            address(pool),
            address(npm),
            "PancakeSwap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(0)
        );
    }

    function test_constructor_reverts_eoaPool() public {
        vm.expectRevert("Pool must be a contract");
        new PancakeSwapV3PoolBalanceOracle(
            address(0xdead),
            address(npm),
            "PancakeSwap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    // ============================================
    // ERC165 (delegates to parent)
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ============================================
    // _slot0 override — the whole reason this wrapper exists
    // ============================================

    /// @notice Drives `slot0` with `feeProtocol = 0x0C800000` (the value seen on the live PCS V3
    ///         WETH/COW pool on Base). A `uint8` decode would revert on this — proving the
    ///         override correctly reads the wider `uint32` ABI.
    function test_slot0_override_decodesUint32FeeProtocol() public {
        uint32 livePcsFeeProtocol = 0x0C800000;
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0, livePcsFeeProtocol);

        // `getOracleBalanceForAsset` calls `_slot0` internally via `_getAccountAggregates`. With
        // an empty NPM (alice owns no NFTs), the call must return `(0, false)` cleanly — *without*
        // the strict-decode revert that the parent's `uint8` ABI would trigger on this value.
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(token0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    /// @notice Symmetric: `feeProtocol = 0` (Uniswap-style) also works through the override.
    function test_slot0_override_decodesZeroFeeProtocol() public {
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0, 0);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(token1));
        assertEq(amount, 0);
    }
}
