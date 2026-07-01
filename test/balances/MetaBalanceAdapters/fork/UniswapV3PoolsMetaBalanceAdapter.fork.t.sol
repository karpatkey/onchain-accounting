// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {
    INonfungiblePositionManager,
    UniswapV3PoolLib
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal pool reads used by the test to INDEPENDENTLY recompute the expected split/fees from the SAME on-chain
///      state the adapter reads (ADR 0017 — the adapter reads `slot0`/`ticks`/`feeGrowthGlobal` directly). The
///      recompute here applies the Uniswap math itself (LiquidityAmounts + the three-way feeGrowthInside formula +
///      tokensOwed) rather than routing through `UniswapV3PoolLib.positionAmounts`, so a bug in the lib's assembly of
///      that math would be caught.
interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick)
        external
        view
        returns (uint128, int128, uint256 fgOut0, uint256 fgOut1, int56, uint160, uint32, bool);
}

/// @title UniswapV3PoolsMetaBalanceForkTest
/// @notice Fork tests for the Uniswap V3 pools meta-adapter against real mainnet contracts — the real WBTC/WETH 0.3%
///         pool and a real NFT holder. The adapter enumerates the holder's NFTs on-chain (the NPM is
///         ERC721Enumerable — no assistant/submit step) and values each position from the pool's live `slot0`
///         (instantaneous on-chain amounts; ADR 0017). The test recomputes the expected amounts off the same `slot0`.
contract UniswapV3PoolsMetaBalanceForkTest is BalanceAdapterTestBase {
    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant POOL = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD; // WBTC/WETH 0.3%
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant HOLDER = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;
    uint256 public constant FORK_BLOCK = 24_987_608;

    UniswapV3PoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(_assets());
        meta = new UniswapV3PoolsMetaBalanceAdapter(NPM, "Uniswap V3", address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = WBTC;
        a[1] = WETH;
    }

    function _poolInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(POOL)));
    }

    function _token(address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(HOLDER, _poolInstance(), token);
        for (uint256 i = 0; i < p.length; i++) {
            sum += p[i].amount;
        }
    }

    function test_balance_perToken() public view {
        uint256 wbtc = _token(WBTC);
        uint256 weth = _token(WETH);
        assertTrue(wbtc > 0 || weth > 0, "holder should have a non-zero position");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _poolInstance(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            // positionId = the pool contract address.
            address pool = abi.decode(p[i].positionId, (address));
            assertEq(pool, POOL, "positionId = the configured pool");
            // NFT id rides in the typed positionInstanceId; the static breadcrumb is positionId-derived.
            string[] memory lbl = meta.positionLabels(p[i].positionId);
            assertEq(lbl.length, 2, "static breadcrumb = [category, pool]");
            assertEq(lbl[0], "AMM Liquidity Pool");
            assertTrue(p[i].positionInstanceId != bytes32(0), "NFT id rides in positionInstanceId");
            assertFalse(p[i].isLocked, "LP liquidity + unclaimed fees are always withdrawable");
        }
    }

    /// @notice Independent ground truth: the adapter reads the pool's live `slot0`/`ticks`/`feeGrowthGlobal` (ADR
    ///         0017). This test recomputes the expected in-range split and FULL unclaimed fees INLINE — applying
    ///         `LiquidityAmounts.getAmountsForLiquidity`, the three-way `feeGrowthInside` formula and the
    ///         `tokensOwed`/accruing-fee assembly itself, NOT by calling `UniswapV3PoolLib.positionAmounts` — so a bug
    ///         in the lib's assembly of that math would be caught here (rather than masked by a self-consistency
    ///         check against the same code path the adapter uses). The recomputed fees include the accruing-since-poke
    ///         component (>= tokensOwed), proving the adapter reports the full unclaimed fee, not settled tokensOwed.
    function test_amountsMatchLiveSlot0Recompute() public view {
        // Aggregate the adapter's WBTC/WETH split (Supplied) and fees (Fees) for the holder's WBTC/WETH 0.3% NFTs.
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(HOLDER, _poolInstance(), address(0));
        uint256 adapterLiqWbtc;
        uint256 adapterLiqWeth;
        uint256 adapterFeeWbtc;
        uint256 adapterFeeWeth;
        for (uint256 i = 0; i < p.length; i++) {
            // Only the WBTC/WETH 0.3% pool legs (positionId == POOL).
            if (abi.decode(p[i].positionId, (address)) != POOL) continue;
            bool isFee = p[i].positionKind == PositionKind.Fees;
            if (p[i].balanceAsset.asset == WBTC) {
                if (isFee) adapterFeeWbtc += p[i].amount;
                else adapterLiqWbtc += p[i].amount;
            } else if (p[i].balanceAsset.asset == WETH) {
                if (isFee) adapterFeeWeth += p[i].amount;
                else adapterLiqWeth += p[i].amount;
            }
        }

        // Recompute the expected amounts INLINE off the same on-chain state, independent of the adapter's library.
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) = _recomputeInline();

        // Pool token0 = WBTC, token1 = WETH (sorted by address). The adapter emits per-token; match accordingly.
        assertEq(adapterLiqWbtc, liq0, "WBTC principal == independent inline recompute");
        assertEq(adapterLiqWeth, liq1, "WETH principal == independent inline recompute");
        assertEq(adapterFeeWbtc, fee0, "WBTC fee == independent inline recompute (feeGrowth + tokensOwed)");
        assertEq(adapterFeeWeth, fee1, "WETH fee == independent inline recompute (feeGrowth + tokensOwed)");
        // The accruing-since-poke component is genuinely valued: the holder has live liquidity in this pool, so the
        // principal split is non-zero.
        assertTrue(liq0 > 0 || liq1 > 0, "holder has in-range principal in the WBTC/WETH pool");
    }

    /// @dev Recompute the holder's aggregate principal + full unclaimed fees across its WBTC/WETH 0.3% NFTs. Kept as a
    ///      thin outer loop (read `slot0` + `balanceOf` once, delegate per-NFT to `_recomputeOne`) so each frame stays
    ///      small — the full inline recompute does not fit in one function (stack-too-deep). The independence
    ///      requirement is satisfied because the principal split + fee math is computed INLINE (here / in
    ///      `_recomputeOne` / `_inlineFees`), never via `UniswapV3PoolLib.positionAmounts`. Loading an NFT's raw fields
    ///      through `UniswapV3PoolLib.readPosition` is just a `positions()` read into a struct — not valuation math.
    function _recomputeInline() internal view returns (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) {
        (uint160 sp, int24 tickCurrent,,,,,) = IPool(POOL).slot0();
        uint256 bal = INonfungiblePositionManager(NPM).balanceOf(HOLDER);
        for (uint256 i = 0; i < bal; i++) {
            uint256 tokenId = INonfungiblePositionManager(NPM).tokenOfOwnerByIndex(HOLDER, i);
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = _recomputeOne(tokenId, sp, tickCurrent);
            liq0 += a0;
            liq1 += a1;
            fee0 += f0;
            fee1 += f1;
        }
    }

    /// @dev INDEPENDENT per-NFT recompute. Loads the raw position fields (a plain `positions()` read), filters to the
    ///      WBTC/WETH 0.3% pool, then computes the principal split via `LiquidityAmounts.getAmountsForLiquidity` and
    ///      the full unclaimed fees via `_inlineFees` — NOT via `UniswapV3PoolLib.positionAmounts`. Matches the lib's
    ///      `liquidity == 0` short-circuit (split 0, fee collapses to settled `tokensOwed`).
    function _recomputeOne(uint256 tokenId, uint160 sp, int24 tickCurrent)
        internal
        view
        returns (uint256 a0, uint256 a1, uint256 f0, uint256 f1)
    {
        UniswapV3PoolLib.Position memory p = UniswapV3PoolLib.readPosition(NPM, tokenId);

        // Only positions in the WBTC/WETH 0.3% pool.
        if (p.token0 != IPool(POOL).token0() || p.token1 != IPool(POOL).token1() || p.fee != IPool(POOL).fee()) {
            return (0, 0, 0, 0);
        }
        // No active liquidity ⇒ no in-range split and no accruing fee; the full fee is the settled tokensOwed.
        if (p.liquidity == 0) {
            return (0, 0, p.tokensOwed0, p.tokensOwed1);
        }

        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sp, TickMath.getSqrtRatioAtTick(p.tickLower), TickMath.getSqrtRatioAtTick(p.tickUpper), p.liquidity
        );
        (f0, f1) = _inlineFees(p, tickCurrent);
    }

    /// @dev INDEPENDENT inline fee recompute for a single in-range position: full unclaimed fee = accruing-since-poke
    ///      (feeGrowthInside − feeGrowthInsideLast) · liquidity + settled tokensOwed. Reads `feeGrowthGlobal` and the
    ///      two tick boundaries' outside-growth directly and applies the three-way `feeGrowthInside` formula under
    ///      `unchecked` (Uniswap fee accounting wraps; v3 whitepaper §6.3). Passing the struct keeps the param count
    ///      low so the frame fits.
    function _inlineFees(UniswapV3PoolLib.Position memory p, int24 tickCurrent)
        internal
        view
        returns (uint256 f0, uint256 f1)
    {
        uint256 fgGlobal0 = IPool(POOL).feeGrowthGlobal0X128();
        uint256 fgGlobal1 = IPool(POOL).feeGrowthGlobal1X128();
        (,, uint256 fgOutLower0, uint256 fgOutLower1,,,,) = IPool(POOL).ticks(p.tickLower);
        (,, uint256 fgOutUpper0, uint256 fgOutUpper1,,,,) = IPool(POOL).ticks(p.tickUpper);

        unchecked {
            uint256 fgInside0;
            uint256 fgInside1;
            if (tickCurrent < p.tickLower) {
                fgInside0 = fgOutLower0 - fgOutUpper0;
                fgInside1 = fgOutLower1 - fgOutUpper1;
            } else if (tickCurrent < p.tickUpper) {
                fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
                fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
            } else {
                fgInside0 = fgOutUpper0 - fgOutLower0;
                fgInside1 = fgOutUpper1 - fgOutLower1;
            }
            f0 = Math.mulDiv(fgInside0 - p.feeGrowthInside0LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed0;
            f1 = Math.mulDiv(fgInside1 - p.feeGrowthInside1LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed1;
        }
    }
}
