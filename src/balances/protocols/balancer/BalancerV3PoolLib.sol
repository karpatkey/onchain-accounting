// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStablePool} from "src/balances/protocols/balancer/IBalancerV3.sol";

/// @title BalancerV3PoolLib
/// @author kpk
/// @notice Shared pool-share math for the Balancer V3 meta-adapters (pools + gauges). Given a BPT amount, computes
///         the account's share of each underlying pool token, unwrapping ERC4626 pool tokens to their underlying.
/// @dev Internal library (inlined into the adapters). Mirrors the math of the original combined
///      BalancerV3PoolBalanceOracle so per-token amounts match leg-for-leg (the only difference between the
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

    /// @notice Account's share of `token` (the pool's underlying, possibly ERC4626-unwrapped) for `userBalance` BPT.
    /// @dev Returns 0 if the token is not in the pool, or supply/balance is zero. Matches the original adapter's
    ///      live-scaled-balance → raw-units conversion, including the ERC4626 previewRedeem unwrap path.
    function poolBalanceOf(IStablePool pool, uint256 userBalance, address token) internal view returns (uint256) {
        uint256 totalSupply = pool.totalSupply();
        if (totalSupply == 0 || userBalance == 0) {
            return 0;
        }

        IStablePool.StablePoolDynamicData memory poolData = pool.getStablePoolDynamicData();
        IStablePool.StablePoolImmutableData memory immutableData = pool.getStablePoolImmutableData();

        uint256 tokenIndex;
        bool found = false;
        bool erc4626 = false;
        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            address currentToken = address(immutableData.tokens[i]);
            if (currentToken == token) {
                tokenIndex = i;
                found = true;
                break;
            }
            try IERC4626(currentToken).asset() returns (address underlyingToken) {
                if (underlyingToken == token) {
                    tokenIndex = i;
                    found = true;
                    erc4626 = true;
                    break;
                }
            } catch {}
        }

        if (!found) return 0;

        // User's share of the live (18-dec scaled) balance.
        uint256 tokenBalance = poolData.balancesLiveScaled18[tokenIndex] * userBalance / totalSupply;

        if (erc4626) {
            // Undo scaling+rate to wrapped-token shares, then preview-redeem to the underlying.
            uint256 shares = (tokenBalance * 1e18)
                / (immutableData.decimalScalingFactors[tokenIndex] * poolData.tokenRates[tokenIndex]);
            tokenBalance = IERC4626(address(immutableData.tokens[tokenIndex])).previewRedeem(shares);
        } else {
            // Undo scaling+rate back to raw token units.
            tokenBalance = (tokenBalance * 1e18)
                / (immutableData.decimalScalingFactors[tokenIndex] * poolData.tokenRates[tokenIndex]);
        }

        return tokenBalance;
    }
}
