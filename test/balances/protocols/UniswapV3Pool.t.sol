// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UniswapV3PoolBalanceOracle} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/protocols/uniswap/lib/LiquidityAmounts.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

// =====================================================================
// Mocks
// =====================================================================

/// @notice Minimal Uniswap V3 pool mock — exposes the views the adapter reads.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    struct TickInfo {
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    mapping(int24 => TickInfo) internal _ticks;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
    }

    function setFeeGrowthGlobal(uint256 fg0, uint256 fg1) external {
        feeGrowthGlobal0X128 = fg0;
        feeGrowthGlobal1X128 = fg1;
    }

    function setTickFeeGrowth(int24 tick, uint256 fgOut0, uint256 fgOut1) external {
        _ticks[tick] = TickInfo(fgOut0, fgOut1);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (_sqrtPriceX96, _tick, 0, 0, 0, 0, false);
    }

    function ticks(int24 tick) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        TickInfo memory info = _ticks[tick];
        return (0, 0, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128, 0, 0, 0, false);
    }
}

/// @notice Minimal NonfungiblePositionManager mock — ERC721Enumerable surface + positions().
contract MockPositionManager {
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => PositionData) internal _positions;
    mapping(address => uint256[]) internal _ownerTokens;

    function mint(address owner, uint256 tokenId, PositionData memory data) external {
        _positions[tokenId] = data;
        _ownerTokens[owner].push(tokenId);
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _ownerTokens[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        return _ownerTokens[owner][index];
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        PositionData memory p = _positions[tokenId];
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            p.feeGrowthInside0LastX128,
            p.feeGrowthInside1LastX128,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }
}

/// @notice Minimal NAVCalculator mock — only `getRegisteredAssets()` is consumed by the adapter.
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

contract UniswapV3PoolBalanceOracleTest is Test {
    MockUniswapV3Pool internal pool;
    MockPositionManager internal npm;
    MockNAVCalculatorWithRegistry internal nav;
    MockToken internal token0;
    MockToken internal token1;
    UniswapV3PoolBalanceOracle internal oracle;

    address internal alice = makeAddr("alice");

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant POOL_TICK_SPACING = 10;

    function setUp() public {
        token0 = new MockToken("T0", 18);
        token1 = new MockToken("T1", 6);
        pool = new MockUniswapV3Pool(address(token0), address(token1), POOL_FEE, POOL_TICK_SPACING);
        npm = new MockPositionManager();
        nav = new MockNAVCalculatorWithRegistry();
        _registerBothTokens();
        oracle = new UniswapV3PoolBalanceOracle(
            address(pool),
            address(npm),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function _registerBothTokens() internal {
        INAVCalculator.Asset[] memory a = new INAVCalculator.Asset[](2);
        a[0] = INAVCalculator.Asset({asset: address(token0), symbol: "T0", decimals: 18});
        a[1] = INAVCalculator.Asset({asset: address(token1), symbol: "T1", decimals: 6});
        nav.setAssets(a);
    }

    function _registerOnly(address asset, string memory symbol, uint8 decimals) internal {
        INAVCalculator.Asset[] memory a = new INAVCalculator.Asset[](1);
        a[0] = INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});
        nav.setAssets(a);
    }

    /// @dev Minimal helper to build a position and mint it.
    function _mintPosition(
        address owner,
        uint256 tokenId,
        address t0,
        address t1,
        uint24 feeTier,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal {
        npm.mint(
            owner,
            tokenId,
            MockPositionManager.PositionData({
                token0: t0,
                token1: t1,
                fee: feeTier,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: tokensOwed0,
                tokensOwed1: tokensOwed1
            })
        );
    }

    // ============================================
    // Constructor Tests
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
        new UniswapV3PoolBalanceOracle(
            address(0),
            address(npm),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function test_constructor_reverts_zeroPositionManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new UniswapV3PoolBalanceOracle(
            address(pool),
            address(0),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function test_constructor_reverts_zeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new UniswapV3PoolBalanceOracle(
            address(pool),
            address(npm),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(0)
        );
    }

    function test_constructor_reverts_eoaPool() public {
        vm.expectRevert("Pool must be a contract");
        new UniswapV3PoolBalanceOracle(
            address(0xdead),
            address(npm),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function test_constructor_reverts_eoaPositionManager() public {
        vm.expectRevert("PositionManager must be a contract");
        new UniswapV3PoolBalanceOracle(
            address(pool),
            address(0xdead),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(nav)
        );
    }

    function test_constructor_reverts_eoaNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new UniswapV3PoolBalanceOracle(
            address(pool),
            address(npm),
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"",
            "0x0000000000000000000000000000000000000001",
            address(0xdead)
        );
    }

    // ============================================
    // ERC165
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(token0));
        assertEq(assets[1], address(token1));
    }

    // ============================================
    // getOracleBalanceForAsset
    // ============================================

    function test_getOracleBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), address(token0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0x1234));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_outOfRangeAbove_allToken1() public {
        // tickCurrent > tickUpper: position fully out of range, all liquidity in token1.
        int24 tickLower = -100;
        int24 tickUpper = 100;
        int24 tickCurrent = 200;
        uint128 liquidity = 1_000_000;

        pool.setSlot0(TickMath.getSqrtRatioAtTick(tickCurrent), tickCurrent);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, tickLower, tickUpper, liquidity, 0, 0);

        (uint256 amount0,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(alice, address(token1));

        assertEq(amount0, 0, "above range: no token0");
        // amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtB, L)
        uint256 expected1 = LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
        assertEq(amount1, expected1, "above range: amount1 matches LiquidityAmounts");
        assertGt(amount1, 0, "above range: amount1 should be non-zero");
    }

    function test_getOracleBalanceForAsset_outOfRangeBelow_allToken0() public {
        // tickCurrent < tickLower: position fully out of range, all liquidity in token0.
        int24 tickLower = -100;
        int24 tickUpper = 100;
        int24 tickCurrent = -200;
        uint128 liquidity = 1_000_000;

        pool.setSlot0(TickMath.getSqrtRatioAtTick(tickCurrent), tickCurrent);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, tickLower, tickUpper, liquidity, 0, 0);

        (uint256 amount0,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(alice, address(token1));

        uint256 expected0 = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
        assertEq(amount0, expected0, "below range: amount0 matches LiquidityAmounts");
        assertEq(amount1, 0, "below range: no token1");
        assertGt(amount0, 0, "below range: amount0 should be non-zero");
    }

    function test_getOracleBalanceForAsset_zeroLiquidity_returnsTokensOwed() public {
        // Closed-but-uncollected position: liquidity=0, tokensOwed != 0.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, -100, 100, 0, 42, 1337);

        (uint256 amount0,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(alice, address(token1));
        assertEq(amount0, 42);
        assertEq(amount1, 1337);
    }

    // ============================================
    // getOracleBalances
    // ============================================

    function test_getOracleBalances_zeroAccount_emptyArrays() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_dropsZeroToken0() public {
        // Above range -> all in token1, zero token0 -> only one entry in result.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(200), 200);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, -100, 100, 1_000_000, 0, 0);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(token1));
        assertGt(amounts[0], 0);
        assertFalse(isDebt[0]);
    }

    function test_getOracleBalances_unknownAccount_emptyArrays() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    // ============================================
    // getOraclePositions
    // ============================================

    function test_getOraclePositions_zeroAccount_returnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }

    function test_getOraclePositions_splits4Entries_outOfRangeWithFees() public {
        // Use out-of-range above (all liq in token1) plus tokensOwed on both -> 3 entries
        // (token1 liq, token0 fees, token1 fees). Then for 4 entries, also need token0 liq:
        // use a separate NFT below range to get token0 liq. Total: token0 liq, token1 liq,
        // token0 fees, token1 fees.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);

        // NFT 1: above range -> all token1 liq, plus token1 fees
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, -200, -100, 1_000_000, 0, 7777);
        // NFT 2: below range -> all token0 liq, plus token0 fees
        _mintPosition(alice, 2, address(token0), address(token1), POOL_FEE, 100, 200, 1_000_000, 4444, 0);

        // Set the pool tick exactly at 0 so:
        //   - NFT 1's range (-200..-100): tickCurrent (0) > tickUpper (-100) -> above -> token1 only
        //   - NFT 2's range (100..200):  tickCurrent (0) < tickLower (100)  -> below -> token0 only
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 4, "expect 4 split entries");

        // Order: token0 liq, token1 liq, token0 fees, token1 fees
        assertEq(positions[0].underlyingAsset.asset, address(token0));
        assertEq(positions[0].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"}");
        assertGt(positions[0].amount, 0);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].protocol, "Uniswap V3");

        assertEq(positions[1].underlyingAsset.asset, address(token1));
        assertEq(positions[1].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\"}");
        assertGt(positions[1].amount, 0);

        assertEq(positions[2].underlyingAsset.asset, address(token0));
        assertEq(
            positions[2].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\",\"type\":\"fees\"}"
        );
        assertEq(positions[2].amount, 4444);

        assertEq(positions[3].underlyingAsset.asset, address(token1));
        assertEq(
            positions[3].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"T0/T1 0.05%\",\"type\":\"fees\"}"
        );
        assertEq(positions[3].amount, 7777);
    }

    function test_getOraclePositions_filtersUnregisteredAsset() public {
        // Register only token0 -> only token0 entries should appear.
        _registerOnly(address(token0), "T0", 18);

        // Out-of-range below -> all token0 liq, plus token0 fees only.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(-200), -200);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, -100, 100, 1_000_000, 100, 200);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 2, "only token0 entries expected");
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, address(token0));
        }
    }

    function test_getOraclePositions_assetFilter_token1Only() public {
        // Two NFTs spanning both tokens' liquidity, filter -> token1 only.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, -200, -100, 1_000_000, 5, 6);
        _mintPosition(alice, 2, address(token0), address(token1), POOL_FEE, 100, 200, 1_000_000, 7, 8);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(token1));
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, address(token1), "only token1 entries");
        }
        assertGt(positions.length, 0);
    }

    function test_getOraclePositions_skipsForeignPoolNfts() public {
        // NFT for a different fee tier -> filtered out by adapter.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        _mintPosition(
            alice,
            1,
            address(token0),
            address(token1),
            3000,
            /* not POOL_FEE */
            -100,
            100,
            1_000_000,
            11,
            22
        );

        (uint256 amount0,) = oracle.getOracleBalanceForAsset(alice, address(token0));
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(alice, address(token1));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getOraclePositions_aggregatesMultipleNfts() public {
        // 3 NFTs in our pool, all out-of-range above (all token1) -> single token1 entry summing all.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(200), 200);
        _mintPosition(alice, 1, address(token0), address(token1), POOL_FEE, -100, 100, 1_000_000, 0, 10);
        _mintPosition(alice, 2, address(token0), address(token1), POOL_FEE, -100, 100, 2_000_000, 0, 20);
        _mintPosition(alice, 3, address(token0), address(token1), POOL_FEE, -100, 100, 3_000_000, 0, 30);

        (uint256 amountT1,) = oracle.getOracleBalanceForAsset(alice, address(token1));
        // Adapter sums per-NFT (each rounded), so we must mirror that — not pass 6_000_000 in one
        // call (which would give a different rounding).
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-100);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(100);
        uint256 expectedLiqT1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtB, 1_000_000)
            + LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtB, 2_000_000)
            + LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtB, 3_000_000);
        // Aggregated liq + summed tokensOwed (10+20+30=60).
        assertEq(amountT1, expectedLiqT1 + 60, "summed across 3 NFTs");
    }

    function test_getOraclePositions_boundedIteration() public {
        // Mint MAX_POSITIONS + 5 NFTs; only first MAX_POSITIONS counted. We use tokensOwed1 = 1
        // each so the total reflects only the bounded portion.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        uint256 maxPositions = 256;
        for (uint256 i = 0; i < maxPositions + 5; i++) {
            _mintPosition(alice, i + 1, address(token0), address(token1), POOL_FEE, -100, 100, 0, 0, 1);
        }

        (uint256 amountT1,) = oracle.getOracleBalanceForAsset(alice, address(token1));
        assertEq(amountT1, maxPositions, "should process exactly MAX_POSITIONS NFTs");
    }
}
