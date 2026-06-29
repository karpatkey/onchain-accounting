// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidityAmounts
/// @notice Provides functions for computing liquidity amounts from token amounts and prices
/// @dev Adapted from Uniswap v3-periphery. Source:
///      https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/LiquidityAmounts.sol
///      Ported to Solidity ^0.8 by:
///        - replacing Uniswap's `FullMath.mulDiv` with OpenZeppelin's `Math.mulDiv` (mathematically
///          identical 512-bit semantics; both compute floor(a*b/d) and revert on division-by-zero
///          or uint256 overflow).
///        - inlining the `FixedPoint96` constants needed by the helpers (`RESOLUTION`, used by
///          `getAmount0ForLiquidity`; `Q96`, used by `getAmount1ForLiquidity`) so the adapter only
///          depends on this single file.
///      Only the three pure-math helpers required by the Uniswap V3 balance adapter are included
///      (`getAmount0ForLiquidity`, `getAmount1ForLiquidity`, `getAmountsForLiquidity`).
library LiquidityAmounts {
    /// @dev FixedPoint96 RESOLUTION (= 96), used as the left-shift in `getAmount0ForLiquidity`.
    uint8 internal constant RESOLUTION = 96;
    /// @dev FixedPoint96 Q96 (= 2^96), used as the divisor in `getAmount1ForLiquidity`.
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return
            Math.mulDiv(uint256(liquidity) << RESOLUTION, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    /// @notice Computes the token0 and token1 value for a given amount of liquidity, the current
    ///         pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }
}
