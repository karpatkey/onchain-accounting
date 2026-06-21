// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";

/// @notice Minimal Uniswap V2 pair interface.
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function kLast() external view returns (uint256);
}

/// @notice Minimal Uniswap V2 factory interface.
interface IUniswapV2Factory {
    function feeTo() external view returns (address);
}

/// @title UniswapV2PairLib
/// @author kpk
/// @notice Shared read math for the Uniswap V2 meta-adapter (and PancakeSwap V2 fork). Given a pair and an
///         account, returns the LP holder's dilution-adjusted pro-rata share of both reserves.
/// @dev Contains the pair balance calculation logic so the
///      meta-adapter is leg-for-leg identical (parity fork-tested). The dilution term mirrors V2's internal
///      `_mintFee` (the LP that would be minted to `feeTo` on the next mint/burn), so the reported amount
///      matches what an LP would actually receive on `burn`.
library UniswapV2PairLib {
    /// @notice Returns the pair's tokens and the account's dilution-adjusted share of each reserve.
    /// @return token0 The pair's token0.
    /// @return token1 The pair's token1.
    /// @return amount0 The account's share of reserve0 (0 if no LP balance / empty pair).
    /// @return amount1 The account's share of reserve1.
    /// @notice Uniswap V2 `_mintFee` dilution coefficients: `liquidity = ts·(√k−√kLast)·1 / (5·√k + 1·√kLast)`
    ///         (feeTo captures 1/6 of the fee growth). Byte-compatible forks that preserve these constants
    ///         (SushiSwap) reuse them; forks with a different protocol-fee fraction (PancakeSwap V2) pass their own.
    function pairAmounts(address pair, address account)
        internal
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        return pairAmounts(pair, account, 1, 5, 1);
    }

    /// @notice As {pairAmounts}, but with explicit `_mintFee` dilution coefficients so forks whose protocol-fee
    ///         fraction differs from Uniswap's report the correct burn-equivalent reserve share.
    /// @param numFactor Numerator multiplier on `(√k − √kLast)`.
    /// @param rootKCoeff Coefficient on `√k` in the denominator.
    /// @param rootKLastCoeff Coefficient on `√kLast` in the denominator.
    function pairAmounts(address pair, address account, uint256 numFactor, uint256 rootKCoeff, uint256 rootKLastCoeff)
        internal
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        token0 = IUniswapV2Pair(pair).token0();
        token1 = IUniswapV2Pair(pair).token1();

        if (account == address(0)) return (token0, token1, 0, 0);

        uint256 balance = IUniswapV2Pair(pair).balanceOf(account);
        if (balance == 0) return (token0, token1, 0, 0);

        uint256 totalSupply = IUniswapV2Pair(pair).totalSupply();
        if (totalSupply == 0) return (token0, token1, 0, 0);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        uint256 effectiveSupply = totalSupply
            + _pendingProtocolMint(
                pair,
                IUniswapV2Pair(pair).factory(),
                reserve0,
                reserve1,
                totalSupply,
                numFactor,
                rootKCoeff,
                rootKLastCoeff
            );

        amount0 = reserve0 == 0 ? 0 : (balance * uint256(reserve0)) / effectiveSupply;
        amount1 = reserve1 == 0 ? 0 : (balance * uint256(reserve1)) / effectiveSupply;
    }

    /// @notice Computes the LP the V2 pair would mint to `feeTo` on the next mint/burn, per V2's `_mintFee`:
    ///         `liquidity = ts·(√k − √kLast)·numFactor / (rootKCoeff·√k + rootKLastCoeff·√kLast)`. Uniswap uses
    ///         `(1, 5, 1)`; PancakeSwap V2 uses `(8, 17, 8)` (a different protocol-fee fraction). Returns 0 when
    ///         `feeTo` is unset, `kLast == 0`, or `√k <= √kLast`. `feeTo()`/`kLast()` are read defensively via
    ///         staticcall (forks omitting them are treated as "no protocol fee").
    function _pendingProtocolMint(
        address pair,
        address factory,
        uint112 reserve0,
        uint112 reserve1,
        uint256 totalSupply,
        uint256 numFactor,
        uint256 rootKCoeff,
        uint256 rootKLastCoeff
    ) private view returns (uint256) {
        (bool feeToOk, address feeTo) = _safeCallAddress(factory, abi.encodeCall(IUniswapV2Factory.feeTo, ()));
        if (!feeToOk || feeTo == address(0)) return 0;

        (bool kLastOk, uint256 kLast) = _safeCallUint(pair, abi.encodeCall(IUniswapV2Pair.kLast, ()));
        if (!kLastOk || kLast == 0) return 0;

        uint256 rootK = Math.sqrt(uint256(reserve0) * uint256(reserve1));
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return 0;

        uint256 numerator = totalSupply * (rootK - rootKLast) * numFactor;
        uint256 denominator = rootK * rootKCoeff + rootKLast * rootKLastCoeff;
        return numerator / denominator;
    }

    function _safeCallUint(address target, bytes memory data) private view returns (bool success, uint256 result) {
        return StaticCallLib.safeUint(target, data);
    }

    function _safeCallAddress(address target, bytes memory data) private view returns (bool success, address result) {
        return StaticCallLib.safeAddr(target, data);
    }
}
