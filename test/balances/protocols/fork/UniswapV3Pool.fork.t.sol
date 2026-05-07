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
        assertEq(positions[0].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\"}");
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].protocol, "Uniswap V3");
        assertFalse(positions[0].isDebt);

        assertEq(positions[1].underlyingAsset.asset, WBTC);
        assertEq(
            positions[1].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\",\"type\":\"fees\"}"
        );

        assertEq(positions[2].underlyingAsset.asset, WETH);
        assertEq(
            positions[2].positionDetail, "{\"protocol\":\"Uniswap V3\",\"pool\":\"WBTC/WETH 0.3%\",\"type\":\"fees\"}"
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
