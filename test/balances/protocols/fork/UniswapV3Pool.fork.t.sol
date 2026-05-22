// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {UniswapV3PoolBalanceOracle} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title UniswapV3PoolBalanceOracle fork tests — WBTC/WETH 0.3% pool
/// @notice Tests against the real Uniswap V3 WBTC/WETH 0.3% pool on Ethereum mainnet,
///         using a real karpatkey safe (the same one exercised by ConvexBalanceOracleForkTest)
///         that holds two NFT positions in this pool plus two NFTs in unrelated pools.
///
///         At the pinned fork block both WBTC/WETH positions are out-of-range *above*
///         (current tick > tickUpper), so all principal liquidity sits in WETH (token1) and
///         WBTC (token0) principal is zero. Fees may still be non-zero for both tokens because
///         fee growth was accumulating while the positions were previously in range.
contract UniswapV3PoolBalanceOracleForkTest_WBTC_WETH is BalanceAdapterTestBase {
    // Uniswap V3 NonfungiblePositionManager (canonical mainnet/OP/Arb/Polygon address).
    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    // WBTC/WETH 0.3% pool.
    address public constant POOL = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;

    // Pool tokens (token0 = WBTC, token1 = WETH).
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // karpatkey Safe with 4 UniV3 NFTs at the fork block:
    //   - 2 in WBTC/WETH 0.3% (tokenId 400900: liquidity=0; tokenId 405543: liquidity>0, above range)
    //   - 1 in SAFE/WETH 0.3% (different pool, must be filtered out)
    //   - 1 in SAFE/WETH 1%   (different pool, must be filtered out)
    address public constant SAFE_HOLDER = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;

    // Fork block matching the integration test snapshot for chain 1.
    uint256 public constant FORK_BLOCK = 24_987_608;

    // Captured baselines — at FORK_BLOCK both WBTC/WETH NFTs are above-range (tickCurrent
    // > tickUpper), so all WBTC value is unclaimed fees, and WETH is principal + fees.
    // Values are deterministic for a pinned block. Captured by running the test once and
    // pasting the on-fork values here as a regression baseline.
    uint256 public constant EXPECTED_WBTC_TOTAL = 116; // satoshis — pure fee accrual
    uint256 public constant EXPECTED_WETH_TOTAL = 674_169_489_016_119; // principal + fees

    UniswapV3PoolBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        address[] memory assets = new address[](2);
        assets[0] = WBTC;
        assets[1] = WETH;
        balances = _deployBalancesForOracle(assets);
        oracle = new UniswapV3PoolBalanceOracle(
            POOL,
            NPM,
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
    }

    // ============================================
    // Interface Compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_immutables() public view {
        assertEq(oracle.POOL(), POOL);
        assertEq(oracle.POSITION_MANAGER(), NPM);
        assertEq(oracle.TOKEN0(), WBTC);
        assertEq(oracle.TOKEN1(), WETH);
        assertEq(oracle.FEE(), 3000);
    }

    // ============================================
    // underlyingAssetsSupported
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], WBTC);
        assertEq(assets[1], WETH);
    }

    // ============================================
    // Real position tests
    // ============================================

    function test_getOracleBalanceForAsset_wbtc_outOfRangeAbove_isFeesOnly() public view {
        // Above range -> no token0 principal. Total is just unclaimed fees.
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE_HOLDER, WBTC);
        assertEq(amount, EXPECTED_WBTC_TOTAL, "WBTC total (fees-only) regression");
    }

    function test_getOracleBalanceForAsset_weth_outOfRangeAbove_principalPlusFees() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE_HOLDER, WETH);
        assertEq(amount, EXPECTED_WETH_TOTAL, "WETH total (principal + fees) regression");
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(SAFE_HOLDER, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    // ============================================
    // getOracleBalances
    // ============================================

    function test_getOracleBalances_returnsBothTokens() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oracle.getOracleBalances(SAFE_HOLDER);
        // Both tokens present (token0 has tiny fees, token1 has principal+fees).
        assertEq(assets.length, 2);
        assertEq(assets[0], WBTC);
        assertEq(assets[1], WETH);
        assertGt(amounts[0], 0, "WBTC has small fees");
        assertGt(amounts[1], 0, "WETH has principal+fees");
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    // ============================================
    // getOraclePositions — split entries
    // ============================================

    function test_getOraclePositions_splitsLiquidityAndFees() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE_HOLDER, address(0));
        // Above-range: no token0 liquidity. Expected entries:
        //   token1 liquidity, token0 fees, token1 fees
        // (3 entries — no token0 liquidity)
        assertEq(positions.length, 3, "expect 3 entries: t1 liq + t0 fees + t1 fees");

        // Order from adapter: t0_liq, t1_liq, t0_fees, t1_fees with zeros dropped.
        // So with t0_liq = 0: positions = [t1_liq, t0_fees, t1_fees].
        assertEq(positions[0].underlyingAsset.asset, WETH);
        assertEq(
            positions[0].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\",\"type\":\"Supply\"}"
        );
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].protocol, "Uniswap V3");
        assertFalse(positions[0].isDebt);

        assertEq(positions[1].underlyingAsset.asset, WBTC);
        assertEq(
            positions[1].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\",\"type\":\"Fees\"}"
        );

        assertEq(positions[2].underlyingAsset.asset, WETH);
        assertEq(
            positions[2].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\",\"type\":\"Fees\"}"
        );
    }

    // ============================================
    // Foreign-pool filtering
    // ============================================

    function test_skipsForeignPoolNfts() public view {
        // Holder has 2 NFTs in OTHER pools (SAFE/WETH 0.3% and SAFE/WETH 1%). The adapter must
        // ignore them. Sanity-check by asserting WBTC fees are *small* (only from this pool's
        // tokenId 405543), not contaminated by foreign-pool fees.
        (uint256 amountWbtc,) = oracle.getOracleBalanceForAsset(SAFE_HOLDER, WBTC);
        assertLt(amountWbtc, 1e6, "WBTC fees must be small (proves foreign pools were filtered out)");
    }

    // ============================================
    // Asset filter
    // ============================================

    function test_getOraclePositions_assetFilter_weth() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE_HOLDER, WETH);
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, WETH);
        }
        assertEq(positions.length, 2, "expect WETH liq + WETH fees");
    }

    function test_getOraclePositions_assetFilter_wbtc() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE_HOLDER, WBTC);
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, WBTC);
        }
        assertEq(positions.length, 1, "expect only WBTC fees (no WBTC liquidity above range)");
    }

    // ============================================
    // Unknown account
    // ============================================

    function test_unknownAccount_emptyResults() public {
        address unknown = makeAddr("unknown");
        (uint256 a0,) = oracle.getOracleBalanceForAsset(unknown, WBTC);
        (uint256 a1,) = oracle.getOracleBalanceForAsset(unknown, WETH);
        assertEq(a0, 0);
        assertEq(a1, 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(unknown, address(0));
        assertEq(positions.length, 0);
    }
}

/// @title UniswapV3PoolBalanceOracle fork tests — multi-holder spectrum coverage
/// @notice Exercises every math branch of the adapter against real mainnet holders at a single
///         pinned fork block, hitting the gaps left by the WBTC/WETH single-holder case above:
///
///           - Holder A (`ACCOUNT_12`) has 4 NFTs across 2 registered pools, covering
///             above-range principal + fee delta (USDC/WETH 0.05% NFT #1231724) and
///             below-range principal + fee delta (WETH/USDT 0.3% NFT #1276763), plus
///             closed-position filtering (`liquidity = 0`) in the same pools.
///
///           - Holder B (`0xa1097367…`) is a heavy LP manager with 33 NFTs total. Its
///             active NFT #1287303 sits in-range in WETH/USDT 0.3% with non-zero
///             `tokensOwed` on both tokens — hitting in-range principal, in-range fee
///             delta, and the settled-`tokensOwed` add in a single position. The other 32
///             NFTs (18 closed in our pools, 14 in foreign pools) exercise the
///             `(token0, token1, fee)` filter and the bounded iteration loop at scale.
///
///         Pinned at mainnet block 25,151,872 — the dev anvil's mainnet pin at the time
///         of test writing, matching `script/development/test/uniswapV3/README.md`.
///         All assertions are strict equality (delta = 0). Re-derivable independently by
///         re-running the Uniswap v3-periphery `PositionValue` math over the pool state
///         at this block.
contract UniswapV3PoolBalanceOracleForkTest_MultiHolder_LP is BalanceAdapterTestBase {
    // Canonical mainnet NonfungiblePositionManager (also OP/Arb/Polygon).
    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    // Cherry-picked holders.
    address public constant ACCOUNT_12 = 0x8d27DEB2405717d649346502F52B959AAB4eb3af;
    address public constant HOLDER_B = 0xa1097367be4C8bbdEf3D881E3c24E6260Afef36E;

    // Registered mainnet pools per script/config/chains/1.json.
    address public constant POOL_USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address public constant POOL_WETH_USDT_3000 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;
    address public constant POOL_WBTC_WETH_3000 = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;

    // Fork block — dev-anvil pin per `script/development/test/uniswapV3/README.md`.
    uint256 public constant FORK_BLOCK = 25_151_872;

    // ---------------------------------------------------------------------------
    // Strict-equality baselines (observed at FORK_BLOCK)
    // ---------------------------------------------------------------------------
    // ACCOUNT_12 — USDC/WETH 0.05% — NFT #1231724 above-range, NFT #1204560 closed.
    // Above-range principal allocates entirely to token1 (WETH); fees on both tokens
    // happen to round to 0 at this block (the position's `feeGrowthInsideLast` is very
    // close to the current global, so the delta * L / 2^128 truncates).
    uint256 public constant EXPECTED_ACCT12_USDC_WETH_USDC = 0;
    uint256 public constant EXPECTED_ACCT12_USDC_WETH_WETH = 207_115_068_443_336_551;

    // ACCOUNT_12 — WETH/USDT 0.3% — NFT #1276763 below-range, NFT #1258127 closed.
    // Below-range principal allocates entirely to token0 (WETH). Both tokens have
    // small accrued-fee deltas (no settled tokensOwed, but feeGrowthInsideLast vs the
    // current global produces non-zero amounts).
    uint256 public constant EXPECTED_ACCT12_WETH_USDT_WETH = 125_889_614_410_826_179;
    uint256 public constant EXPECTED_ACCT12_WETH_USDT_USDT = 740_253;

    // HOLDER_B — WETH/USDT 0.3% — NFT #1287303 in-range with `tokensOwed > 0` on both
    // tokens, plus 18 closed NFTs in the same pool and 14 NFTs in *other* pools that
    // must be filtered out. Totals = principal (both tokens) + fee delta + tokensOwed.
    uint256 public constant EXPECTED_B_WETH_USDT_WETH = 14_895_136_734_773_279_820;
    uint256 public constant EXPECTED_B_WETH_USDT_USDT = 914_254_606;

    // ---------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------
    UniswapV3PoolBalanceOracle public oUsdcWeth;
    UniswapV3PoolBalanceOracle public oWethUsdt;
    UniswapV3PoolBalanceOracle public oWbtcWeth;

    function setUp() public override {
        super.setUp();
        _setupOracles();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracles() internal {
        // Single Balances harness registered with the four underlying tokens across the
        // three registered pools.
        address[] memory assets = new address[](4);
        assets[0] = MAINNET_USDC;
        assets[1] = MAINNET_WETH;
        assets[2] = MAINNET_USDT;
        assets[3] = MAINNET_WBTC;
        balances = _deployBalancesForOracle(assets);

        // positionId follows the canonical schema from
        // script/config/adapter-identities.json: `<pool address>` (lower-cased hex).
        // Likewise positionDetail uses the `protocol/product/name` schema; the adapter
        // appends `"type":"Supply"` / `"type":"Fees"` via `PositionType.withType(...)`.
        oUsdcWeth = new UniswapV3PoolBalanceOracle(
            POOL_USDC_WETH_500,
            NPM,
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"USDC/WETH 0.05%\"",
            vm.toString(POOL_USDC_WETH_500),
            address(balances)
        );
        oWethUsdt = new UniswapV3PoolBalanceOracle(
            POOL_WETH_USDT_3000,
            NPM,
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\"",
            vm.toString(POOL_WETH_USDT_3000),
            address(balances)
        );
        oWbtcWeth = new UniswapV3PoolBalanceOracle(
            POOL_WBTC_WETH_3000,
            NPM,
            "Uniswap V3",
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WBTC/WETH 0.3%\"",
            vm.toString(POOL_WBTC_WETH_3000),
            address(balances)
        );
    }

    // ============================================
    // Pre-flight: NFTs present at the pinned block
    // ============================================

    /// @dev If the active NFTs were ever burned or transferred away, the strict-equality
    ///      baselines below would all flip to 0 and the test would silently "pass" the
    ///      empty path. These two pre-flights make that failure mode loud instead.
    function test_preflight_acct12_active_above_and_below_range() public view {
        (uint256 wethUsdcSide,) = oUsdcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);
        (uint256 wethUsdtSide,) = oWethUsdt.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);
        assertGt(wethUsdcSide, 0, "ACCOUNT_12 USDC/WETH above-range WETH must be non-zero");
        assertGt(wethUsdtSide, 0, "ACCOUNT_12 WETH/USDT below-range WETH must be non-zero");
    }

    function test_preflight_holderB_inRange_withTokensOwedBothSides() public view {
        (uint256 weth,) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_WETH);
        (uint256 usdt,) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_USDT);
        assertGt(weth, 0, "HOLDER_B in-range WETH must be non-zero");
        assertGt(usdt, 0, "HOLDER_B in-range USDT must be non-zero (tokensOwed + fees)");
    }

    // ============================================
    // Strict equality: getOracleBalanceForAsset
    // ============================================

    function test_acct12_USDC_WETH_aboveRange_USDC_strictEq() public view {
        (uint256 a, bool isDebt) = oUsdcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_USDC);
        assertEq(a, EXPECTED_ACCT12_USDC_WETH_USDC, "above-range: no token0 principal");
        assertFalse(isDebt);
    }

    function test_acct12_USDC_WETH_aboveRange_WETH_strictEq() public view {
        (uint256 a, bool isDebt) = oUsdcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);
        assertEq(a, EXPECTED_ACCT12_USDC_WETH_WETH, "above-range: principal allocates entirely to token1");
        assertFalse(isDebt);
    }

    function test_acct12_WETH_USDT_belowRange_WETH_strictEq() public view {
        (uint256 a, bool isDebt) = oWethUsdt.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);
        assertEq(a, EXPECTED_ACCT12_WETH_USDT_WETH, "below-range: principal allocates entirely to token0 (WETH)");
        assertFalse(isDebt);
    }

    function test_acct12_WETH_USDT_belowRange_USDT_strictEq() public view {
        (uint256 a, bool isDebt) = oWethUsdt.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_USDT);
        assertEq(a, EXPECTED_ACCT12_WETH_USDT_USDT, "below-range: token1 is fee accrual only");
        assertFalse(isDebt);
    }

    function test_holderB_WETH_USDT_inRange_WETH_strictEq() public view {
        (uint256 a, bool isDebt) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_WETH);
        assertEq(a, EXPECTED_B_WETH_USDT_WETH, "in-range principal + fee delta + tokensOwed0");
        assertFalse(isDebt);
    }

    function test_holderB_WETH_USDT_inRange_USDT_strictEq() public view {
        (uint256 a, bool isDebt) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_USDT);
        assertEq(a, EXPECTED_B_WETH_USDT_USDT, "in-range principal + fee delta + tokensOwed1");
        assertFalse(isDebt);
    }

    // ============================================
    // Empty paths (no exposure)
    // ============================================

    function test_acct12_WBTC_WETH_noExposure() public view {
        (uint256 a0,) = oWbtcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WBTC);
        (uint256 a1,) = oWbtcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function test_holderB_USDC_WETH_onlyClosed() public view {
        // Holder B has only closed (`liquidity = 0`) NFTs in USDC/WETH 0.05%. Filter must
        // drop them — totals must be 0.
        (uint256 a0,) = oUsdcWeth.getOracleBalanceForAsset(HOLDER_B, MAINNET_USDC);
        (uint256 a1,) = oUsdcWeth.getOracleBalanceForAsset(HOLDER_B, MAINNET_WETH);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function test_holderB_WBTC_WETH_onlyClosed() public view {
        (uint256 a0,) = oWbtcWeth.getOracleBalanceForAsset(HOLDER_B, MAINNET_WBTC);
        (uint256 a1,) = oWbtcWeth.getOracleBalanceForAsset(HOLDER_B, MAINNET_WETH);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    // ============================================
    // Strict equality: getOracleBalances aggregate
    // ============================================

    function test_acct12_USDC_WETH_aggregate() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oUsdcWeth.getOracleBalances(ACCOUNT_12);
        assertEq(assets.length, 1, "above-range with no fee accrual: WETH only");
        assertEq(assets[0], MAINNET_WETH);
        assertEq(amounts[0], EXPECTED_ACCT12_USDC_WETH_WETH);
        assertFalse(isDebt[0]);
    }

    function test_acct12_WETH_USDT_aggregate() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oWethUsdt.getOracleBalances(ACCOUNT_12);
        assertEq(assets.length, 2, "WETH principal+fees + USDT fees-only");
        assertEq(assets[0], MAINNET_WETH);
        assertEq(amounts[0], EXPECTED_ACCT12_WETH_USDT_WETH);
        assertEq(assets[1], MAINNET_USDT);
        assertEq(amounts[1], EXPECTED_ACCT12_WETH_USDT_USDT);
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    function test_holderB_WETH_USDT_aggregate() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            oWethUsdt.getOracleBalances(HOLDER_B);
        assertEq(assets.length, 2);
        assertEq(assets[0], MAINNET_WETH);
        assertEq(amounts[0], EXPECTED_B_WETH_USDT_WETH);
        assertEq(assets[1], MAINNET_USDT);
        assertEq(amounts[1], EXPECTED_B_WETH_USDT_USDT);
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    // ============================================
    // getOraclePositions structural breakdown
    // ============================================

    /// @dev Above-range with no accrued fees → 1 entry: WETH (token1) Supply.
    function test_acct12_USDC_WETH_positions_aboveRange_oneEntry() public view {
        INAVCalculator.PositionBalance[] memory p = oUsdcWeth.getOraclePositions(ACCOUNT_12, address(0));
        assertEq(p.length, 1, "above-range with zero accrued fees: only token1 Supply");
        assertEq(p[0].underlyingAsset.asset, MAINNET_WETH);
        assertEq(p[0].amount, EXPECTED_ACCT12_USDC_WETH_WETH);
        assertEq(
            p[0].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"USDC/WETH 0.05%\",\"type\":\"Supply\"}"
        );
        assertEq(p[0].protocol, "Uniswap V3");
        assertEq(p[0].balanceOracle, address(oUsdcWeth));
        assertEq(p[0].positionId, vm.toString(POOL_USDC_WETH_500));
        assertFalse(p[0].isDebt);
    }

    /// @dev Below-range with fee accrual on both tokens → 3 entries:
    ///      WETH (token0) Supply, WETH (token0) Fees, USDT (token1) Fees.
    ///      USDT has no Supply leg because below-range principal is token0-only.
    function test_acct12_WETH_USDT_positions_belowRange_threeEntries() public view {
        INAVCalculator.PositionBalance[] memory p = oWethUsdt.getOraclePositions(ACCOUNT_12, address(0));
        assertEq(p.length, 3, "below-range: token0 Supply + token0 Fees + token1 Fees");
        // Adapter emits in order: t0 Supply, t1 Supply, t0 Fees, t1 Fees with zeros dropped.
        assertEq(p[0].underlyingAsset.asset, MAINNET_WETH);
        assertEq(
            p[0].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Supply\"}"
        );
        assertEq(p[1].underlyingAsset.asset, MAINNET_WETH);
        assertEq(
            p[1].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Fees\"}"
        );
        assertEq(p[2].underlyingAsset.asset, MAINNET_USDT);
        assertEq(
            p[2].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Fees\"}"
        );
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].protocol, "Uniswap V3");
            assertEq(p[i].balanceOracle, address(oWethUsdt));
            assertEq(p[i].positionId, vm.toString(POOL_WETH_USDT_3000));
            assertFalse(p[i].isDebt);
        }
    }

    /// @dev In-range with `tokensOwed > 0` on both tokens → all 4 entries:
    ///      WETH Supply, USDT Supply, WETH Fees, USDT Fees.
    function test_holderB_WETH_USDT_positions_inRange_fourEntries() public view {
        INAVCalculator.PositionBalance[] memory p = oWethUsdt.getOraclePositions(HOLDER_B, address(0));
        assertEq(p.length, 4, "in-range with tokensOwed on both: full 4-entry split");
        assertEq(p[0].underlyingAsset.asset, MAINNET_WETH);
        assertEq(
            p[0].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Supply\"}"
        );
        assertEq(p[1].underlyingAsset.asset, MAINNET_USDT);
        assertEq(
            p[1].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Supply\"}"
        );
        assertEq(p[2].underlyingAsset.asset, MAINNET_WETH);
        assertEq(
            p[2].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Fees\"}"
        );
        assertEq(p[3].underlyingAsset.asset, MAINNET_USDT);
        assertEq(
            p[3].positionDetail,
            "{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"WETH/USDT 0.3%\",\"type\":\"Fees\"}"
        );
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].protocol, "Uniswap V3");
            assertEq(p[i].balanceOracle, address(oWethUsdt));
            assertEq(p[i].positionId, vm.toString(POOL_WETH_USDT_3000));
            assertFalse(p[i].isDebt);
        }
        // Aggregate check: per-token sums across legs must equal the adapter's
        // single-call totals (catches any off-by-one in the per-leg split math).
        assertEq(p[0].amount + p[2].amount, EXPECTED_B_WETH_USDT_WETH);
        assertEq(p[1].amount + p[3].amount, EXPECTED_B_WETH_USDT_USDT);
    }

    // ============================================
    // Foreign-pool + closed-position filter at scale
    // ============================================

    /// @dev HOLDER_B owns 33 NFTs total. 14 are in pools OTHER than WETH/USDT 0.3%
    ///      (different `(token0, token1, fee)` tuples) and 18 are closed (`liquidity = 0`)
    ///      same-pool dust. If either filter were buggy, the adapter would over-report.
    ///      This asserts the bounded loop iterated all 33 NFTs (well under
    ///      `_MAX_POSITIONS = 256`) without leakage.
    function test_holderB_foreignAndClosedFilter_atScale() public view {
        (uint256 weth,) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_WETH);
        // The single active NFT contributes ~14.85 WETH. With the filter working, the
        // total is exactly that amount. Without the filter, the result would include
        // contributions from any (token0, token1, fee)-matching same-pool dust or other
        // pool NFTs — bounded above by 150 WETH would catch any meaningful leakage.
        assertLt(weth, 150 ether, "foreign-pool / closed-position filter leaked at scale");
        assertEq(weth, EXPECTED_B_WETH_USDT_WETH, "strict equality with filtering applied");
    }

    // ============================================
    // Ground-truth cross-check: adapter == NPM.decreaseLiquidity + NPM.collect
    // ============================================
    //
    // These tests run the **canonical Uniswap V3 "what would I receive if I closed the
    // position right now"** operation against each active NFT, then assert the adapter's
    // output equals what the protocol itself would transfer. The simulation is the
    // forked-EVM equivalent of a Tenderly `decreaseLiquidity + collect` simulation:
    // same NPM contract, same forked archive state at the same block — no possibility
    // of derivation drift between the adapter's math and the protocol's settlement math.
    //
    // Per NFT we do:
    //
    //   1. `vm.prank(holder)` to impersonate the position owner.
    //   2. `NPM.decreaseLiquidity({tokenId, liquidity: <full>, ...})` — returns the
    //      principal amounts the protocol would withdraw at the current price, AND
    //      internally credits `tokensOwed*` with accrued fees + principal.
    //   3. `NPM.collect({tokenId, recipient: holder, amount0Max: max, amount1Max: max})`
    //      — returns the total transferable: principal + previously-settled `tokensOwed`
    //      + just-accrued fees.
    //
    // The adapter's `getOracleBalanceForAsset` is supposed to return exactly that
    // collect-return value: principal + all fees + settled `tokensOwed`. So strict
    // equality holds iff the adapter's math matches the protocol's settlement math.

    /// @dev NFT-tuple wrapper so the helpers can stay terse.
    struct NftCase {
        address holder;
        uint256 tokenId;
        UniswapV3PoolBalanceOracle adapter;
        address token0;
        address token1;
    }

    function _simulateDecreaseAndCollect(NftCase memory c) internal returns (uint256 g0, uint256 g1) {
        // 1. decreaseLiquidity at the full position liquidity. This pulls principal into
        //    `tokensOwed*` on the NPM and zeros out `liquidity`.
        // Read the current liquidity from the NFT (same value the adapter sees).
        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManagerMutating(NPM).positions(c.tokenId);

        vm.startPrank(c.holder);
        if (liq > 0) {
            INonfungiblePositionManagerMutating.DecreaseLiquidityParams memory dParams =
                INonfungiblePositionManagerMutating.DecreaseLiquidityParams({
                    tokenId: c.tokenId, liquidity: liq, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                });
            INonfungiblePositionManagerMutating(NPM).decreaseLiquidity(dParams);
        }

        // 2. collect everything (principal + fees + tokensOwed) to the holder.
        INonfungiblePositionManagerMutating.CollectParams memory cParams =
            INonfungiblePositionManagerMutating.CollectParams({
                tokenId: c.tokenId, recipient: c.holder, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            });
        (uint128 a0, uint128 a1) = INonfungiblePositionManagerMutating(NPM).collect(cParams);
        vm.stopPrank();

        g0 = uint256(a0);
        g1 = uint256(a1);
    }

    function test_groundTruth_acct12_USDC_WETH_NFT1231724() public {
        // Adapter's view of ACCOUNT_12 across this pool BEFORE we mutate the NFT.
        (uint256 adapterToken0,) = oUsdcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_USDC);
        (uint256 adapterToken1,) = oUsdcWeth.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);

        // Ground truth: what NPM would actually pay out on close.
        NftCase memory c = NftCase({
            holder: ACCOUNT_12, tokenId: 1_231_724, adapter: oUsdcWeth, token0: MAINNET_USDC, token1: MAINNET_WETH
        });
        (uint256 g0, uint256 g1) = _simulateDecreaseAndCollect(c);

        // ACCOUNT_12 has one other NFT in this pool (#1204560, closed `liquidity=0`)
        // that contributes 0 to both the adapter total and the collect total. So the
        // adapter total for this holder equals the collect output of #1231724.
        assertEq(adapterToken0, g0, "adapter token0 != NPM.collect token0 (USDC)");
        assertEq(adapterToken1, g1, "adapter token1 != NPM.collect token1 (WETH)");
    }

    function test_groundTruth_acct12_WETH_USDT_NFT1276763() public {
        (uint256 adapterToken0,) = oWethUsdt.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_WETH);
        (uint256 adapterToken1,) = oWethUsdt.getOracleBalanceForAsset(ACCOUNT_12, MAINNET_USDT);

        NftCase memory c = NftCase({
            holder: ACCOUNT_12, tokenId: 1_276_763, adapter: oWethUsdt, token0: MAINNET_WETH, token1: MAINNET_USDT
        });
        (uint256 g0, uint256 g1) = _simulateDecreaseAndCollect(c);

        // ACCOUNT_12 has one other NFT in this pool (#1258127, closed) — same logic.
        assertEq(adapterToken0, g0, "adapter token0 != NPM.collect token0 (WETH)");
        assertEq(adapterToken1, g1, "adapter token1 != NPM.collect token1 (USDT)");
    }

    function test_groundTruth_holderB_WETH_USDT_NFT1287303() public {
        (uint256 adapterToken0,) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_WETH);
        (uint256 adapterToken1,) = oWethUsdt.getOracleBalanceForAsset(HOLDER_B, MAINNET_USDT);

        NftCase memory c = NftCase({
            holder: HOLDER_B, tokenId: 1_287_303, adapter: oWethUsdt, token0: MAINNET_WETH, token1: MAINNET_USDT
        });
        (uint256 g0, uint256 g1) = _simulateDecreaseAndCollect(c);

        // HOLDER_B has 18 other NFTs in this pool, all closed (`liquidity = 0`,
        // `tokensOwed = 0`). They contribute 0 to the adapter total. The 14 NFTs in
        // foreign pools are also dropped by the adapter's `(token0,token1,fee)` filter.
        // So the adapter total for this holder equals the collect output of #1287303.
        assertEq(adapterToken0, g0, "adapter token0 != NPM.collect token0 (WETH)");
        assertEq(adapterToken1, g1, "adapter token1 != NPM.collect token1 (USDT)");
    }
}

/// @notice Minimal NPM mutating interface — used only by the ground-truth simulator
///         below, NOT by the adapter itself (the adapter is read-only).
interface INonfungiblePositionManagerMutating {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
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
        );
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external returns (uint128 amount0, uint128 amount1);
}
