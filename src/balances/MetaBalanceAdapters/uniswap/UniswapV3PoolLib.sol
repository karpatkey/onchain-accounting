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

/// @notice Minimal NPM interface (ERC721Enumerable surface + `ownerOf` + `positions`).
interface INonfungiblePositionManager {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
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
/// @notice Shared read math for the Uniswap V3 meta-adapter (and PancakeSwap V3 fork). Given a pool, the
///         NonfungiblePositionManager, an account, and a pool `slot0` snapshot, it scans the account's NFT
///         positions in that pool and aggregates principal (liquidity → token amounts) and unclaimed fees.
/// @dev Contains the per-pool aggregation logic so the meta-adapter is
///      leg-for-leg identical (parity fork-tested). The `slot0` read is intentionally NOT done here — the caller
///      passes `(sqrtPriceX96, tickCurrent)` so a fork with a divergent `slot0()` ABI (PancakeSwap V3's `uint32
///      feeProtocol`) can override that single read in the adapter without duplicating this math.
///
///      Licensing: imports the GPL-2.0-or-later Uniswap math (`lib/{TickMath,LiquidityAmounts,FixedPoint128}`),
///      so this library — and any adapter linking it — is a combined work under GPL-2.0-or-later. See
///      `docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md`.
library UniswapV3PoolLib {
    /// @notice Bounded iteration limit for position discovery (matches the per-instance adapter).
    uint256 internal constant MAX_POSITIONS = 256;

    /// @notice Reconstructs the Uniswap V3 `sqrtPriceX96` implied by two external oracle prices, so LP valuation
    ///         never reads the manipulable pool `slot0`. The encoded price is token1/token0 in *raw* units:
    ///         `price = (p0 · 10^(dec1+pdec1)) / (p1 · 10^(dec0+pdec0))`, and `sqrtPriceX96 = sqrt(price) · 2^96`.
    /// @dev Computed as `mulDiv(sqrt(numerator), 2^96, sqrt(denominator))` — the two-sqrt split keeps both the
    ///      intermediate operands and the result inside uint256 (a single `price · 2^192` would overflow for
    ///      high-price pools). Truncation is ~1 ulp on operands ~1e22, i.e. ~1e-22 relative — far below the
    ///      oracle-vs-spot gap. Result is clamped to the valid sqrt range so `LiquidityAmounts`/`TickMath`
    ///      consumers never see an out-of-range input. Callers must pass strictly-positive prices.
    ///
    ///      Overflow: the shared power of ten in `numerator`/`denominator` is cancelled first, so the surviving
    ///      `10 ** e` exponent is only the *difference* `|(dec1+pdec1) - (dec0+pdec0)|`. For real registered
    ///      assets (ERC20 decimals ≤ 18, validated 8-dp USD feeds) that difference is ≤ ~36 and the
    ///      `price · 10^e` products sit well inside uint256, so this does not revert. A pathological asset config
    ///      (e.g. a >60-decimal token) could still overflow `10 ** e`; that is not reachable for validated assets,
    ///      and is in any case fail-safe — the caller invokes this inside the meta-adapter's per-instance
    ///      try/catch, so an overflow drops only that one pool's leg rather than the whole read.
    /// @param price0 Oracle price of token0 (must be > 0). @param priceDecimals0 Its decimals. @param tokenDecimals0 token0 ERC20 decimals.
    /// @param price1 Oracle price of token1 (must be > 0). @param priceDecimals1 Its decimals. @param tokenDecimals1 token1 ERC20 decimals.
    function sqrtPriceX96FromOraclePrices(
        uint256 price0,
        uint8 priceDecimals0,
        uint8 tokenDecimals0,
        uint256 price1,
        uint8 priceDecimals1,
        uint8 tokenDecimals1
    ) internal pure returns (uint160 sqrtPriceX96) {
        uint256 eNum = uint256(tokenDecimals1) + uint256(priceDecimals1);
        uint256 eDen = uint256(tokenDecimals0) + uint256(priceDecimals0);
        // Cancel the shared power of ten so only the net exponent difference is materialised (keeps `10 ** e`
        // and the `price · 10^e` products bounded for realistic asset configs — see overflow note above).
        uint256 common = eNum < eDen ? eNum : eDen;
        uint256 numerator = price0 * (10 ** (eNum - common));
        uint256 denominator = price1 * (10 ** (eDen - common));
        uint256 s = Math.mulDiv(Math.sqrt(numerator), 1 << 96, Math.sqrt(denominator));
        if (s < TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO;
        if (s > TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO;
        return uint160(s);
    }

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

    /// @notice Aggregates principal + fees for `account` across all of its NFTs in `pool`.
    /// @param pool The Uniswap V3 pool.
    /// @param positionManager The NonfungiblePositionManager.
    /// @param account The account whose NFTs are scanned.
    /// @param sqrtPriceX96 Pool current `sqrtPriceX96` (read by the caller via its `_slot0` hook).
    /// @param tickCurrent Pool current tick (read by the caller via its `_slot0` hook).
    /// @return liq0 Total token0 derivable from in-range liquidity.
    /// @return liq1 Total token1 derivable from in-range liquidity.
    /// @return fee0 Total unclaimed token0 fees (settled `tokensOwed0` + accruing).
    /// @return fee1 Total unclaimed token1 fees (settled `tokensOwed1` + accruing).
    function accountAggregates(
        address pool,
        address positionManager,
        address account,
        uint160 sqrtPriceX96,
        int24 tickCurrent
    ) internal view returns (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) {
        if (account == address(0)) return (0, 0, 0, 0);

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        uint24 fee = IUniswapV3Pool(pool).fee();

        uint256 fgGlobal0 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 fgGlobal1 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();

        uint256 nftBalance = INonfungiblePositionManager(positionManager).balanceOf(account);
        uint256 max = nftBalance > MAX_POSITIONS ? MAX_POSITIONS : nftBalance;

        for (uint256 i = 0; i < max; i++) {
            uint256 tokenId = INonfungiblePositionManager(positionManager).tokenOfOwnerByIndex(account, i);
            Position memory p = _readPosition(positionManager, tokenId);

            // Filter: only positions in *this* pool.
            if (p.token0 != token0 || p.token1 != token1 || p.fee != fee) continue;

            if (p.liquidity > 0) {
                (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(p.tickLower),
                    TickMath.getSqrtRatioAtTick(p.tickUpper),
                    p.liquidity
                );
                liq0 += a0;
                liq1 += a1;
            }

            (uint256 f0, uint256 f1) = _computeFees(pool, p, tickCurrent, fgGlobal0, fgGlobal1);
            fee0 += f0;
            fee1 += f1;
        }
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
    function _readPosition(address positionManager, uint256 tokenId) private view returns (Position memory p) {
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
