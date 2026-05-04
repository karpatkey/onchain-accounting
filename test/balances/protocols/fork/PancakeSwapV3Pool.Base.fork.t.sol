// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {PancakeSwapV3PoolBalanceOracle} from "src/balances/protocols/pancakeswap/PancakeSwapV3Pool.sol";
import {LiquidityAmounts} from "src/balances/protocols/uniswap/lib/LiquidityAmounts.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Local NPM interface — keeps the test independent of the adapter file's internal layout.
interface IPancakeNPMFork {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
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
        );
}

interface IPancakeV3PoolFork {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @title PancakeSwapV3PoolBalanceOracle fork tests — WETH/COW 0.25% pool on Base
/// @notice Tests against the real PancakeSwap V3 WETH/COW 0.25% pool on Base. The test account
///         `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669` holds NFT tokenId 936925 in this pool;
///         at the pinned block the position has `liquidity == 0` and `tokensOwed == 0` (closed
///         and collected). This validates:
///           - the canonical PancakeSwap V3 NPM (`0x46A1...4364`) is reachable on Base,
///           - the pool's `slot0`/`fee` reads match what the adapter cached at construction,
///           - empty NFT handling: `getOracleBalances` returns no entries, balances are zero.
///
///         A second test injects a synthetic in-range position (via `vm.mockCall` over the NPM)
///         while keeping the real pool's live `slot0`/`feeGrowthGlobal*X128`/`ticks` — this
///         exercises `LiquidityAmounts.getAmountsForLiquidity` against live pool prices.
///
///         Requires `BSC_URL`/`BASE_URL` env or `ALCHEMY_API_KEY` fallback.
contract PancakeSwapV3PoolBalanceOracleForkTest_Base_WETH_COW is BalanceAdapterTestBase {
    // PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2 address — same on every
    // chain PancakeSwap deploys to).
    address public constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;

    // WETH/COW 0.25% pool on Base (resolved via `factory.getPool(WETH, COW, 2500)`).
    address public constant POOL = 0xfe5291Ac7Ac2b81a40c0ba6980308212037828aF;

    // Pool tokens (token0 = WETH, token1 = COW on Base).
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address public constant BASE_COW = 0xc694a91e6b071bF030A18BD3053A7fE09B6DaE69;

    // Test account that holds NFT 936925 in this pool (position currently has liquidity = 0).
    address public constant TEST_HOLDER = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;
    uint256 public constant TEST_TOKEN_ID = 936925;

    // PancakeSwap V3's 0.25% tier uses fee = 2500 (Uniswap V3 has no analogous tier).
    uint24 public constant POOL_FEE = 2500;

    // Pinned block — close to head but not the very tip (RPC-stability margin).
    uint256 public constant FORK_BLOCK = 45_520_000;

    PancakeSwapV3PoolBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        address[] memory assets = new address[](2);
        assets[0] = BASE_WETH;
        assets[1] = BASE_COW;
        balances = _deployBalancesForOracle(assets);
        oracle = new PancakeSwapV3PoolBalanceOracle(POOL, NPM, "PancakeSwap V3", "WETH/COW 0.25%", address(balances));
    }

    // ============================================
    // Interface compliance + immutables
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_immutables() public view {
        assertEq(oracle.POOL(), POOL);
        assertEq(oracle.POSITION_MANAGER(), NPM);
        assertEq(oracle.TOKEN0(), BASE_WETH);
        assertEq(oracle.TOKEN1(), BASE_COW);
        assertEq(oracle.FEE(), POOL_FEE);
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], BASE_WETH);
        assertEq(assets[1], BASE_COW);
    }

    // ============================================
    // Real holder — closed position (liquidity = 0, tokensOwed = 0) → adapter returns zero
    // ============================================

    function test_realHolder_holdsExactlyOneNft() public view {
        assertEq(IPancakeNPMFork(NPM).balanceOf(TEST_HOLDER), 1, "test holder should hold exactly 1 PCS V3 NFT");
        assertEq(IPancakeNPMFork(NPM).tokenOfOwnerByIndex(TEST_HOLDER, 0), TEST_TOKEN_ID);
    }

    function test_realHolder_nftIsInThisPool() public view {
        // Sanity: the NFT's `(token0, token1, fee)` match this pool, so the adapter would *not*
        // skip it during iteration. The closed-position math then yields zero amounts.
        (,, address t0, address t1, uint24 f,,, uint128 liquidity,,, uint128 owed0, uint128 owed1) =
            IPancakeNPMFork(NPM).positions(TEST_TOKEN_ID);
        assertEq(t0, BASE_WETH);
        assertEq(t1, BASE_COW);
        assertEq(f, POOL_FEE);
        assertEq(liquidity, 0, "expected closed position");
        assertEq(owed0, 0);
        assertEq(owed1, 0);
    }

    function test_realHolder_closedPosition_returnsZero() public view {
        (uint256 wethAmount,) = oracle.getOracleBalanceForAsset(TEST_HOLDER, BASE_WETH);
        (uint256 cowAmount,) = oracle.getOracleBalanceForAsset(TEST_HOLDER, BASE_COW);
        assertEq(wethAmount, 0, "closed position must report zero WETH");
        assertEq(cowAmount, 0, "closed position must report zero COW");
    }

    function test_realHolder_getOracleBalances_emptyForClosedPosition() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oracle.getOracleBalances(TEST_HOLDER);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_realHolder_getOraclePositions_emptyForClosedPosition() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_HOLDER, address(0));
        assertEq(positions.length, 0);
    }

    function test_unsupportedAsset_returnsZero() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_HOLDER, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_unknownAccount_emptyResults() public {
        address unknown = makeAddr("unknown");
        (uint256 a0,) = oracle.getOracleBalanceForAsset(unknown, BASE_WETH);
        (uint256 a1,) = oracle.getOracleBalanceForAsset(unknown, BASE_COW);
        assertEq(a0, 0);
        assertEq(a1, 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(unknown, address(0));
        assertEq(positions.length, 0);
    }

    // ============================================
    // Synthetic in-range position over the real pool — exercises liquidity → amount math
    // against live `slot0`/`feeGrowthGlobal`/`ticks`.
    // ============================================

    /// @notice Mock the NPM to return a single in-range position for `synthOwner`, then assert
    ///         the adapter's amounts match the `LiquidityAmounts` library applied to the real
    ///         pool's `sqrtPriceX96`. Range chosen as ±1000 ticks around the live tick (rounded
    ///         to the 0.25% tier's spacing of 50) so the position is guaranteed in-range.
    function test_syntheticInRangePosition_matchesLiquidityAmounts() public {
        address synthOwner = makeAddr("synthOwner");

        // Read live pool snapshot.
        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = IPancakeV3PoolFork(POOL).slot0();
        int24 tickLower = ((tickCurrent - 1000) / 50) * 50; // round to spacing-50
        int24 tickUpper = ((tickCurrent + 1000) / 50) * 50;
        if (tickLower == tickUpper) tickUpper += 50;
        uint128 liquidity = 1e18;

        // Mock NPM so synthOwner appears to hold one matching NFT.
        uint256 syntheticTokenId = 0xdeadbeef;
        vm.mockCall(NPM, abi.encodeCall(IPancakeNPMFork.balanceOf, (synthOwner)), abi.encode(uint256(1)));
        vm.mockCall(
            NPM, abi.encodeCall(IPancakeNPMFork.tokenOfOwnerByIndex, (synthOwner, 0)), abi.encode(syntheticTokenId)
        );
        vm.mockCall(
            NPM,
            abi.encodeCall(IPancakeNPMFork.positions, (syntheticTokenId)),
            abi.encode(
                uint96(0), // nonce
                address(0), // operator
                BASE_WETH,
                BASE_COW,
                POOL_FEE,
                tickLower,
                tickUpper,
                liquidity,
                uint256(0), // fgInside0Last
                uint256(0), // fgInside1Last
                uint128(0), // tokensOwed0
                uint128(0) // tokensOwed1
            )
        );

        // Expected amounts: derived from LiquidityAmounts against the live sqrtPriceX96.
        (uint256 expected0, uint256 expected1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );

        (uint256 amount0,) = oracle.getOracleBalanceForAsset(synthOwner, BASE_WETH);
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(synthOwner, BASE_COW);

        // The adapter also adds any `_computeFees` term derived from live `feeGrowthGlobal*` ticks.
        // For a synthetic position with `feeGrowthInsideLast = 0`, the adapter computes
        // `mulDiv(fgInside, L, Q128)` from the real pool's per-tick `feeGrowthOutside`, which is
        // non-deterministic across blocks. We therefore assert `amount >= expected_principal`
        // (fees only add on top), and assert principal is non-zero.
        assertGe(amount0, expected0, "WETH amount must include at least the principal");
        assertGe(amount1, expected1, "COW amount must include at least the principal");
        assertGt(amount0 + amount1, 0, "in-range position must report non-zero total");
    }

    /// @notice Foreign-pool filtering: a synthetic NFT for a *different* fee tier is ignored.
    function test_syntheticForeignPool_isFiltered() public {
        address synthOwner = makeAddr("synthOwner2");
        (, int24 tickCurrent,,,,,) = IPancakeV3PoolFork(POOL).slot0();
        int24 tickLower = ((tickCurrent - 1000) / 50) * 50;
        int24 tickUpper = ((tickCurrent + 1000) / 50) * 50;
        if (tickLower == tickUpper) tickUpper += 50;

        uint256 syntheticTokenId = 0xcafef00d;
        vm.mockCall(NPM, abi.encodeCall(IPancakeNPMFork.balanceOf, (synthOwner)), abi.encode(uint256(1)));
        vm.mockCall(
            NPM, abi.encodeCall(IPancakeNPMFork.tokenOfOwnerByIndex, (synthOwner, 0)), abi.encode(syntheticTokenId)
        );
        vm.mockCall(
            NPM,
            abi.encodeCall(IPancakeNPMFork.positions, (syntheticTokenId)),
            abi.encode(
                uint96(0),
                address(0),
                BASE_WETH,
                BASE_COW,
                uint24(10000), // wrong fee tier (1%) — adapter must filter this out
                tickLower,
                tickUpper,
                uint128(1e18),
                uint256(0),
                uint256(0),
                uint128(123), // tokensOwed should also be ignored when fee-tier mismatches
                uint128(456)
            )
        );

        (uint256 amount0,) = oracle.getOracleBalanceForAsset(synthOwner, BASE_WETH);
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(synthOwner, BASE_COW);
        assertEq(amount0, 0, "foreign-pool NFT must be filtered out -- no WETH");
        assertEq(amount1, 0, "foreign-pool NFT must be filtered out -- no COW");
    }
}
