// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";

/// @notice Minimal Uniswap V3 pool interface (only the views this adapter needs).
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
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
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}

/// @notice Minimal NPM interface (ERC721Enumerable surface + `ownerOf` + `factory` + `positions`).
interface INonfungiblePositionManager {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function factory() external view returns (address);
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

/// @title UniswapV3PoolLib
/// @author KPK
/// @notice Shared read math for the Uniswap V3 assisted adapter (and PancakeSwap V3 fork). Provides per-position
///         read helpers — `readPosition` (load an NFT's fields from the NPM), `positionAmounts` (split a single
///         position's liquidity into token amounts and compute its full unclaimed fees) and the underlying fee math —
///         that the assisted adapter calls once per cached tokenId.
/// @dev Holds the per-position valuation math so the adapter (and the PancakeSwap V3 subclass) stay leg-for-leg
///      identical (parity fork-tested). The `slot0` read is intentionally NOT done here — the caller passes
///      `(sqrtPriceX96, tickCurrent)` so a fork with a divergent `slot0()` ABI (PancakeSwap V3's `uint32
///      feeProtocol`) can override that single read in the adapter without duplicating this math.
///
///      Licensing: imports the GPL-2.0-or-later Uniswap math (`lib/{TickMath,LiquidityAmounts,FixedPoint128}`),
///      so this library — and any adapter linking it — is a combined work under GPL-2.0-or-later. See
///      `docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md`.
library UniswapV3PoolLib {
    /// @dev In-memory snapshot of the NFT-position fields we use.
    struct Position {
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

    /// @notice Principal split + unclaimed fees for a SINGLE position `p` in `pool`, valued at the pool's current
    ///         `(sqrtPriceX96, tickCurrent)` (read by the caller from `slot0`). The assisted per-NFT adapter calls
    ///         this once per cached tokenId.
    /// @return liq0 token0 derivable from in-range liquidity.
    /// @return liq1 token1 derivable from in-range liquidity.
    /// @return fee0 token0 unclaimed fees (settled `tokensOwed0` + accruing-since-poke).
    /// @return fee1 token1 unclaimed fees (settled `tokensOwed1` + accruing-since-poke).
    function positionAmounts(address pool, Position memory p, uint160 sqrtPriceX96, int24 tickCurrent)
        internal
        view
        returns (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1)
    {
        // No active liquidity ⇒ the in-range split is 0 and the accruing-fee term (`feeGrowthInside·liquidity`) is
        // 0, so unclaimed fees collapse to the already-loaded settled `tokensOwed`. Skip the four
        // `ticks()`/`feeGrowthGlobal` reads entirely (closed / empty positions are common in a cache).
        if (p.liquidity == 0) {
            return (0, 0, p.tokensOwed0, p.tokensOwed1);
        }
        (liq0, liq1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(p.tickLower),
            TickMath.getSqrtRatioAtTick(p.tickUpper),
            p.liquidity
        );
        (fee0, fee1) = _computeFees(
            pool, p, tickCurrent, IUniswapV3Pool(pool).feeGrowthGlobal0X128(), IUniswapV3Pool(pool).feeGrowthGlobal1X128()
        );
    }

    /// @notice Computes unclaimed fees for a single position. Mirrors PositionValue._fees / _getFeeGrowthInside.
    /// @dev Subtractions intentionally wrap (`unchecked`), matching Uniswap's internal fee accounting (v3
    ///      whitepaper §6.3).
    function _computeFees(address pool, Position memory p, int24 tickCurrent, uint256 fgGlobal0, uint256 fgGlobal1)
        private
        view
        returns (uint256 f0, uint256 f1)
    {
        (uint256 fgOutLower0, uint256 fgOutLower1) = _ticksFeeGrowthOutside(pool, p.tickLower);
        (uint256 fgOutUpper0, uint256 fgOutUpper1) = _ticksFeeGrowthOutside(pool, p.tickUpper);

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

    /// @notice Reads `(feeGrowthOutside0X128, feeGrowthOutside1X128)` from the pool's tick state.
    function _ticksFeeGrowthOutside(address pool, int24 tick) private view returns (uint256 fgOut0, uint256 fgOut1) {
        (,, uint256 _fgOut0, uint256 _fgOut1,,,,) = IUniswapV3Pool(pool).ticks(tick);
        return (_fgOut0, _fgOut1);
    }

    /// @notice Reads a single NFT position from the NPM and returns the subset we use.
    function readPosition(address positionManager, uint256 tokenId) internal view returns (Position memory p) {
        (
            ,,
            address token0_,
            address token1_,
            uint24 fee_,
            int24 tickLower_,
            int24 tickUpper_,
            uint128 liquidity_,
            uint256 fgInside0Last_,
            uint256 fgInside1Last_,
            uint128 tokensOwed0_,
            uint128 tokensOwed1_
        ) = INonfungiblePositionManager(positionManager).positions(tokenId);
        p = Position({
            token0: token0_,
            token1: token1_,
            fee: fee_,
            tickLower: tickLower_,
            tickUpper: tickUpper_,
            liquidity: liquidity_,
            feeGrowthInside0LastX128: fgInside0Last_,
            feeGrowthInside1LastX128: fgInside1Last_,
            tokensOwed0: tokensOwed0_,
            tokensOwed1: tokensOwed1_
        });
    }
}
