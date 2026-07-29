// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStablePool} from "src/balances/MetaBalanceAdapters/balancer/IBalancerV3.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";

/// @title BalancerV3PoolLib
/// @author KPK
/// @notice Shared pool-share math for the Balancer V3 meta-adapters (pools + gauges). Given a BPT amount, computes
///         the account's share of each underlying pool token, unwrapping ERC4626 pool tokens to their underlying.
/// @dev Internal library (inlined into the adapters). Mirrors the math of the original combined adapter across
///      the split meta-adapters so per-token amounts are consistent (the only difference between the
///      combined adapter and the split is that wallet- and gauge-held BPT are converted separately rather than
///      summed into a single conversion — a ≤1-wei rounding difference per token).
library BalancerV3PoolLib {
    /// @notice Returns the pool's underlying tokens, unwrapping ERC4626 pool tokens to their `asset()`.
    /// @dev Read through {StaticCallLib.safeAddr}, not `abi.decode(data, (address))`. A length check is not a
    ///      range check: the decoder emits a validator that REVERTS when a returned word has dirty bits above
    ///      160, and that revert fires in THIS frame — outside any `try`/`catch` the caller wrapped around the
    ///      instance. A pool token answering `asset()` with a `bytes32`-shaped or padding-careless word therefore
    ///      took down the whole instance. `safeAddr` masks instead, which is the convention every other address
    ///      reader in this sweep already follows (`CurvePoolLib._firstAddress`,
    ///      `AaveV3InstancesMetaBalanceAdapter._marketId`); a masked-to-garbage address simply fails the
    ///      registry lookup downstream and the leg is skipped, which under-reports.
    ///
    ///      The ERC4626 predicate is now "asset() yielded a non-zero address", and {poolBalanceOfIndexed} uses
    ///      the SAME predicate. That matters: the two functions must agree about which pool tokens are wrappers,
    ///      or a token could be reported under its raw identity while its amount was `previewRedeem`-converted.
    ///      They previously used two different tests (`data.length >= 32` here and there), which agreed only by
    ///      luck.
    function poolTokens(IStablePool pool) internal view returns (address[] memory tokens) {
        IStablePool.StablePoolImmutableData memory immutableData = pool.getStablePoolImmutableData();
        tokens = new address[](immutableData.tokens.length);
        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            address currentToken = address(immutableData.tokens[i]);
            address unwrapped = _wrapperAsset(currentToken);
            tokens[i] = unwrapped == address(0) ? currentToken : unwrapped;
        }
    }

    /// @notice `token.asset()` when `token` looks like an ERC4626 wrapper, else `address(0)`.
    /// @dev The single ERC4626 test this library uses, so {poolTokens} and {poolBalanceOfIndexed} cannot disagree.
    ///      `address(0)` means "treat as a plain token": a revert, a code-less address, a short reply, or a word
    ///      that masks to zero all land there, and all of them mean the same thing to both callers.
    function _wrapperAsset(address token) private view returns (address) {
        (, address underlyingAsset) = StaticCallLib.safeAddr(token, abi.encodeWithSelector(IERC4626.asset.selector));
        return underlyingAsset;
    }

    /// @notice Account's share of the pool token at `tokenIndex` (ERC4626-unwrapped to its underlying) for
    ///         `userBalance` BPT.
    /// @dev Index-driven on purpose: the callers iterate `poolTokens()` (one entry per pool-token index, in index
    ///      order) and pass the loop index here, so each pool-token index contributes exactly one leg. The previous
    ///      address-matching variant broke on the FIRST index whose (raw or unwrapped) token matched — for pools
    ///      that hold the same underlying at two indices (e.g. two distinct ERC4626 wrappers of the same asset) it
    ///      double-counted index 0 and dropped the duplicate. Keying on the index removes the ambiguity entirely.
    ///      Returns 0 if supply/balance is zero, `tokenIndex` is out of range, or a scaling factor / token rate is
    ///      transiently zero (which would otherwise divide-by-zero and revert the whole instance).
    function poolBalanceOfIndexed(IStablePool pool, uint256 userBalance, uint256 tokenIndex)
        internal
        view
        returns (uint256)
    {
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0 || userBalance == 0) {
            return 0;
        }

        IStablePool.StablePoolDynamicData memory poolData = pool.getStablePoolDynamicData();
        IStablePool.StablePoolImmutableData memory immutableData = pool.getStablePoolImmutableData();

        if (tokenIndex >= immutableData.tokens.length) return 0;

        // User's share of the live (18-dec scaled) balance. Math.mulDiv so an extreme supply can't overflow the
        // intermediate product and drop the leg via the per-instance try/catch (consistent with the V2/Curve libs).
        uint256 tokenBalance = Math.mulDiv(poolData.balancesLiveScaled18[tokenIndex], userBalance, totalSupply);

        // A transiently-zero scaling factor or token rate would divide-by-zero below (reverting the whole
        // instance via the per-instance try/catch). Treat it as a 0 leg so one bad rate can't drop the batch.
        if (immutableData.decimalScalingFactors[tokenIndex] == 0 || poolData.tokenRates[tokenIndex] == 0) {
            return 0;
        }

        // Undo scaling+rate back to raw token (wrapped-share) units. Math.mulDiv so the numerator product can't
        // overflow (the L56-58 guard already rules out a zero denominator). decimalScalingFactors * tokenRates is a
        // ~1e36 product, far below the uint256 ceiling, so the single-call form is safe.
        uint256 rawUnits = Math.mulDiv(
            tokenBalance, 1e18, immutableData.decimalScalingFactors[tokenIndex] * poolData.tokenRates[tokenIndex]
        );

        // If the pool token is an ERC4626 wrapper, preview-redeem the shares to the underlying; otherwise raw units.
        // Same predicate as {poolTokens} — see {_wrapperAsset} for why that has to be true rather than merely
        // convenient.
        address poolToken = address(immutableData.tokens[tokenIndex]);
        if (_wrapperAsset(poolToken) != address(0)) {
            return IERC4626(poolToken).previewRedeem(rawUnits);
        }
        return rawUnits;
    }
}
