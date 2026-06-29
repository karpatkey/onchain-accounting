// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title BalancerV2PoolLib
/// @author KPK
/// @notice Shared pool-share math for the Balancer V2 meta-adapters (pools + gauges). Given a pool's `bytes32`
///         poolId and a BPT amount, computes the account's pro-rata share of each underlying pool token by
///         reading the Vault's live balances.
/// @dev Balancer V2 holds all pool tokens in a single Vault. The pool's BPT (ERC20) address is the top 160 bits
///      of the poolId. Total supply is read via `getActualSupply()` when available (composable-stable pools,
///      which also pre-mint their own BPT into the pool token list — excluded here) and falls back to
///      `totalSupply()` for legacy weighted/stable pools.
library BalancerV2PoolLib {
    /// @notice The pool's BPT (ERC20) address, encoded in the top 160 bits of the poolId.
    function bptOf(bytes32 poolId) internal pure returns (address) {
        return address(uint160(uint256(poolId) >> 96));
    }

    /// @notice The pool's effective BPT supply — `getActualSupply()` (composable-stable: excludes pre-minted BPT,
    ///         includes due protocol fees) when present, else `totalSupply()`.
    function effectiveSupply(address bpt) internal view returns (uint256) {
        try IBalancerV2Pool(bpt).getActualSupply() returns (uint256 s) {
            return s;
        } catch {
            return IBalancerV2Pool(bpt).totalSupply();
        }
    }

    /// @notice The pool's underlying tokens (excluding the pool's own BPT for composable-stable pools).
    function poolTokens(address vault, bytes32 poolId, address bpt) internal view returns (address[] memory tokens) {
        (address[] memory all,,) = IBalancerV2Vault(vault).getPoolTokens(poolId);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != bpt) n++;
        }
        tokens = new address[](n);
        uint256 k;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != bpt) tokens[k++] = all[i];
        }
    }

    /// @notice The account's share of each underlying token for `bptAmount` BPT.
    /// @return tokens The underlying tokens (BPT-in-pool excluded).
    /// @return amounts The corresponding `balances[i] * bptAmount / effectiveSupply` (0 if supply or bptAmount is 0).
    function shares(address vault, bytes32 poolId, address bpt, uint256 bptAmount)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        (address[] memory all, uint256[] memory balances,) = IBalancerV2Vault(vault).getPoolTokens(poolId);
        uint256 ts = effectiveSupply(bpt);

        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != bpt) n++;
        }
        tokens = new address[](n);
        amounts = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] == bpt) continue;
            tokens[k] = all[i];
            amounts[k] = (ts == 0 || bptAmount == 0) ? 0 : (balances[i] * bptAmount) / ts;
            k++;
        }
    }
}

/// @notice Minimal Balancer V2 Vault view — the single Vault that custodies every pool's tokens.
interface IBalancerV2Vault {
    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

/// @notice Minimal Balancer V2 pool (BPT) view.
interface IBalancerV2Pool {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    /// @dev Composable-stable pools only; reverts on legacy weighted/stable pools (handled via try/catch).
    function getActualSupply() external view returns (uint256);
    function getPoolId() external view returns (bytes32);
}
