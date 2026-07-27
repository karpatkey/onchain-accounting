// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {IUniswapV2Pair, IUniswapV2Factory} from "src/balances/MetaBalanceAdapters/uniswap/IUniswapV2.sol";

/// @title UniswapV2PairLib
/// @author KPK
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
        (uint256 pendingMint, bool malformed) = _pendingProtocolMint(
            pair, IUniswapV2Pair(pair).factory(), reserve0, reserve1, totalSupply, numFactor, rootKCoeff, rootKLastCoeff
        );
        // A factory we cannot read COHERENTLY leaves the dilution term unknowable, and an unknown dilution can
        // only be resolved downward — see {_pendingProtocolMint} on why its own fail-open resolves upward.
        // Reporting nothing for the pair under-reports; guessing "no protocol fee" would over-report.
        if (malformed) return (token0, token1, 0, 0);
        uint256 effectiveSupply = totalSupply + pendingMint;

        amount0 = reserve0 == 0 ? 0 : (balance * uint256(reserve0)) / effectiveSupply;
        amount1 = reserve1 == 0 ? 0 : (balance * uint256(reserve1)) / effectiveSupply;
    }

    /// @notice Computes the LP the V2 pair would mint to `feeTo` on the next mint/burn, per V2's `_mintFee`:
    ///         `liquidity = ts·(√k − √kLast)·numFactor / (rootKCoeff·√k + rootKLastCoeff·√kLast)`. Uniswap uses
    ///         `(1, 5, 1)`; PancakeSwap V2 uses `(8, 17, 8)` (a different protocol-fee fraction). Returns 0 when
    ///         `feeTo` is unset, `kLast == 0`, or `√k <= √kLast`. `feeTo()`/`kLast()` are read defensively via
    ///         staticcall (forks omitting them are treated as "no protocol fee").
    /// @dev **This is the one fail-open branch in this file whose failure direction is UPWARD**, and it is the
    ///      reason `feeTo()` is read through {StaticCallLib.probeWord} rather than {StaticCallLib.safeAddr}.
    ///      Returning 0 collapses `effectiveSupply` from `totalSupply + pendingMint` to plain `totalSupply`,
    ///      making the caller's reserve share LARGER — an over-report, the direction adapters are required never
    ///      to take. Every other probe failure in this file drops a leg and under-reports.
    ///
    ///      Two distinct failures reach that branch, and they must NOT be conflated:
    ///
    ///      - **The call fails** (`!ok`) — a fork that genuinely omits `feeTo()`. "No protocol fee" is the
    ///        correct reading, and it is why this fail-open exists at all. The gas stipend does not meaningfully
    ///        widen this: on the canonical factory and pair, `feeTo()`/`kLast()` are single `SLOAD`s behind
    ///        public getters (~2.2k gas, measured ~2.7k against mainnet), more than an order of magnitude under
    ///        the stipend, and {pairAmounts} first makes six UNGUARDED high-level calls that would revert the
    ///        instance long before the frame could starve a 2.7k read.
    ///      - **The call SUCCEEDS but the word is not a valid address** (dirty bits above 160). That is a
    ///        malformed factory, not a fee-less fork, and reading it as "no protocol fee" is exactly the
    ///        over-report. It needs separating because {StaticCallLib.safeAddr} masks such a word rather than
    ///        rejecting it: a word like `type(uint96).max << 160` masks to `address(0)` and lands silently in
    ///        the `feeTo == address(0)` clause. Before the masking change it hit `abi.decode`'s validator and
    ///        reverted, which the meta-adapter's per-instance `try`/`catch` turned into a drop — the SAFE
    ///        direction. Masking is right for every other reader in the sweep, and wrong here, so this call site
    ///        checks the upper bits itself and reports `malformed` so the caller can drop the pair instead.
    /// @return pendingMint The LP that would be minted to `feeTo` on the next mint/burn; 0 when there is no fee.
    /// @return malformed True when the factory answered with something that is not an address, meaning the
    ///         dilution is unknowable and the caller must report nothing rather than assume no fee.
    function _pendingProtocolMint(
        address pair,
        address factory,
        uint112 reserve0,
        uint112 reserve1,
        uint256 totalSupply,
        uint256 numFactor,
        uint256 rootKCoeff,
        uint256 rootKLastCoeff
    ) private view returns (uint256 pendingMint, bool malformed) {
        (bool feeToOk, bool feeToHasWord, uint256 feeToWord) =
            StaticCallLib.probeWord(factory, abi.encodeCall(IUniswapV2Factory.feeTo, ()));
        if (feeToHasWord && feeToWord >> 160 != 0) return (0, true);

        address feeTo = address(uint160(feeToWord));
        if (!feeToOk || feeTo == address(0)) return (0, false);

        (bool kLastOk, uint256 kLast) = _safeCallUint(pair, abi.encodeCall(IUniswapV2Pair.kLast, ()));
        if (!kLastOk || kLast == 0) return (0, false);

        uint256 rootK = Math.sqrt(uint256(reserve0) * uint256(reserve1));
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) return (0, false);

        uint256 numerator = totalSupply * (rootK - rootKLast) * numFactor;
        uint256 denominator = rootK * rootKCoeff + rootKLast * rootKLastCoeff;
        return (numerator / denominator, false);
    }

    function _safeCallUint(address target, bytes memory data) private view returns (bool success, uint256 result) {
        return StaticCallLib.safeUint(target, data);
    }
}
