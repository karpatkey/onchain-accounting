// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStablePool} from "src/balances/protocols/balancer/IBalancerV3.sol";

/// @title BalancerV3PoolLib
/// @author kpk
/// @notice Shared pool-share math for the Balancer V3 meta-adapters (pools + gauges). Given a BPT amount, computes
///         the account's share of each underlying pool token, unwrapping ERC4626 pool tokens to their underlying.
/// @dev Internal library (inlined into the adapters). Mirrors the math of the original combined
///      the split meta-adapters so per-token amounts are consistent (the only difference between the
///      combined adapter and the split is that wallet- and gauge-held BPT are converted separately rather than
///      summed into a single conversion — a ≤1-wei rounding difference per token).
library BalancerV3PoolLib {
    /// @notice Returns the pool's underlying tokens, unwrapping ERC4626 pool tokens to their `asset()`.
    function poolTokens(IStablePool pool) internal view returns (address[] memory tokens) {
        IStablePool.StablePoolImmutableData memory immutableData = pool.getStablePoolImmutableData();
        tokens = new address[](immutableData.tokens.length);
        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            address currentToken = address(immutableData.tokens[i]);
            (bool success, bytes memory data) = currentToken.staticcall(abi.encodeWithSelector(IERC4626.asset.selector));
            tokens[i] = (success && data.length >= 32) ? abi.decode(data, (address)) : currentToken;
        }
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

        // User's share of the live (18-dec scaled) balance.
        uint256 tokenBalance = poolData.balancesLiveScaled18[tokenIndex] * userBalance / totalSupply;

        // A transiently-zero scaling factor or token rate would divide-by-zero below (reverting the whole
        // instance via the per-instance try/catch). Treat it as a 0 leg so one bad rate can't drop the batch.
        if (immutableData.decimalScalingFactors[tokenIndex] == 0 || poolData.tokenRates[tokenIndex] == 0) {
            return 0;
        }

        // Undo scaling+rate back to raw token (wrapped-share) units.
        uint256 rawUnits =
            (tokenBalance * 1e18) / (immutableData.decimalScalingFactors[tokenIndex] * poolData.tokenRates[tokenIndex]);

        // If the pool token is an ERC4626 wrapper, preview-redeem the shares to the underlying; otherwise raw units.
        address poolToken = address(immutableData.tokens[tokenIndex]);
        (bool ok, bytes memory data) = poolToken.staticcall(abi.encodeWithSelector(IERC4626.asset.selector));
        if (ok && data.length >= 32) {
            return IERC4626(poolToken).previewRedeem(rawUnits);
        }
        return rawUnits;
    }
}
