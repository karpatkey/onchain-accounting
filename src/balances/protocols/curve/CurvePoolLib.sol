// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

/// @title CurvePoolLib
/// @notice Shared helpers for reading Curve pool and gauge state across all pool/gauge generations.
/// @dev Handles the two main interface divergences in the Curve ecosystem:
///
///      1. INDEX TYPE: Vyper 0.1.x pools (original StableSwap) use `int128` for `coins(i)` and
///         `balances(i)`. All modern pools (StableSwap-NG, CryptoSwap, TriCryptoNG, TwoCryptoNG,
///         StableSwap 0.2+) use `uint256`. Helpers try `uint256` first, fall back to `int128`.
///
///      2. LP TOKEN LOCATION: Most pools ARE their own ERC20 LP token (classic StableSwap, TriCryptoNG).
///         StableSwap-NG factory pools and TwoCryptoNG create a separate LP ERC20 whose `minter()`
///         points back to the pool — this is the reliable pool-discovery mechanism.
///         The heuristic order: (a) try `coins(0)` on the address — if it works, it IS the pool;
///         (b) try `minter()` — returns pool for all NG-style LP tokens.
///
///      3. TOTAL SUPPLY: Standard `totalSupply()` (ERC20) works everywhere except StableSwap-NG which
///         exposes it as a public storage variable `total_supply()` (different selector).
///
///      Pool families covered:
///        - StableSwap (2/3/4-coin, Vyper 0.1.x, int128 indices)
///        - StableSwap 0.2.x+ (uint256 indices, separate LP token)
///        - StableSwap-NG / MetapoolNG (factory, separate LP with minter(), uint256 balances)
///        - CryptoSwap 2-coin (uint256, separate LP token)
///        - TriCryptoNG (uint256, pool IS the LP token)
///        - TwoCryptoNG (uint256, separate LP token with minter())
///        - Lending pools (int128, balances = wrapped token amounts — consumers must be aware)
///        - Metapools — `coins()` enumerates the meta-coins; base pool coins are not recursed into
///          (the base LP token has its own price feed in the system)
///
///      Gauge families covered (see gauge helpers below):
///        - LiquidityGauge V1: no extra rewards, CRV via Minter
///        - LiquidityGaugeV2/V3/V4/V5: `reward_tokens(i)` + `claimable_reward(account, token)`,
///          CRV via integrate_fraction − minter.minted (view-safe lower bound)
///        - RewardsOnlyGauge: extra rewards only, no CRV Minter integration
///        - ChildGauge (L2): extra rewards, CRV claimed via ChildGaugeFactory; skip Minter
///
/// @author KPK
library CurvePoolLib {
    uint256 internal constant MAX_COINS = 8;

    // ─── LP Token / Pool resolution ───────────────────────────────────────────

    /// @notice Derives the LP token from a pool address.
    ///         For most classic pools, pool IS the LP token.
    ///         For TriCryptoNG, pool is also self-LP (no lp_token() method).
    ///         For StableSwap-NG factory pools, lp_token() returns a separate ERC20.
    function getLpToken(address pool) internal view returns (address) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("lp_token()"));
        if (ok && data.length == 32) {
            address token = abi.decode(data, (address));
            if (token != address(0) && token != pool) return token;
        }
        return pool; // pool IS the LP token (classic StableSwap, TriCryptoNG)
    }

    /// @notice Derives the pool address from an LP token.
    ///         Handles both the self-LP case and the minter() pattern for NG pools.
    ///         Returns address(0) if the pool cannot be determined (rare edge case).
    function getPool(address lpToken) internal view returns (address) {
        // Fast path: check if lpToken has coins() — then it IS the pool
        if (_hasCoinMethod(lpToken)) return lpToken;

        // StableSwap-NG / TwoCryptoNG LP tokens have minter() pointing to the pool
        (bool ok, bytes memory data) = lpToken.staticcall(abi.encodeWithSignature("minter()"));
        if (ok && data.length == 32) {
            address minter = abi.decode(data, (address));
            if (minter != address(0)) return minter;
        }

        return address(0); // Cannot resolve — gauge/pools meta will skip LP decomposition
    }

    // ─── Coin / balance enumeration ───────────────────────────────────────────

    /// @notice Enumerates all coin addresses for a pool.
    ///         Stops at the first zero address or revert. Safe up to MAX_COINS.
    function getCoins(address pool) internal view returns (address[] memory coins) {
        address[] memory tmp = new address[](MAX_COINS);
        uint256 n;
        for (uint256 i; i < MAX_COINS; ++i) {
            address coin = _coin(pool, i);
            if (coin == address(0)) break;
            tmp[n++] = coin;
        }
        coins = new address[](n);
        for (uint256 i; i < n; ++i) {
            coins[i] = tmp[i];
        }
    }

    /// @notice Returns the pool's stored balance for coin at index `i`.
    ///         Tries `uint256` index selector first, falls back to `int128`.
    function getPoolBalance(address pool, uint256 i) internal view returns (uint256) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("balances(uint256)", i));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));

        (ok, data) = pool.staticcall(abi.encodeWithSignature("balances(int128)", int128(int256(i))));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    /// @notice Returns the LP token's total supply.
    ///         Tries ERC20 `totalSupply()` first, then the StableSwap-NG storage-var variant.
    function getTotalSupply(address lpToken) internal view returns (uint256) {
        (bool ok, bytes memory data) = lpToken.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));

        // StableSwap-NG exposes total_supply as a public state variable
        (ok, data) = lpToken.staticcall(abi.encodeWithSignature("total_supply()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    /// @notice Pro-rata share of coin `i` for an LP holder.
    ///         = poolBalance[i] × lpBalance / totalSupply
    function proRataAmount(uint256 poolBalance, uint256 lpBalance, uint256 totalSupply)
        internal
        pure
        returns (uint256)
    {
        if (totalSupply == 0 || lpBalance == 0) return 0;
        return (poolBalance * lpBalance) / totalSupply;
    }

    // ─── Gauge helpers ────────────────────────────────────────────────────────

    /// @notice Returns gauge-staked LP balance (gauges are ERC20-tokenized since V2).
    function gaugeStaked(address gauge, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = gauge.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    /// @notice Derives the LP token from a gauge via `lp_token()`.
    ///         Returns address(0) if not available (unusual, defensive).
    function gaugeLpToken(address gauge) internal view returns (address) {
        (bool ok, bytes memory data) = gauge.staticcall(abi.encodeWithSignature("lp_token()"));
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return address(0);
    }

    /// @notice CRV claimable lower bound for a gauge staker (view-safe).
    ///         = integrate_fraction(account) − minter.minted(account, gauge)
    ///         This is a lower bound: it is stale between checkpoints (deposit/withdraw/claim).
    ///         It will be 0 or underestimated for recently transferred gauge tokens.
    ///         For accurate amounts, `claimable_tokens(account)` must be called as a state mutation
    ///         (or via eth_call to the gauge), which we cannot do in a view function.
    /// @param minter The Curve Minter contract (0xd061D61a4d941c39E5453435B6345Dc261C2fcE0 on mainnet).
    ///               Pass address(0) to skip CRV computation (L2 / non-mainnet deployments).
    function crvClaimableLb(address gauge, address minter, address account) internal view returns (uint256) {
        if (minter == address(0)) return 0;

        (bool ok1, bytes memory d1) = gauge.staticcall(abi.encodeWithSignature("integrate_fraction(address)", account));
        if (!ok1 || d1.length < 32) return 0;
        uint256 integrateFraction = abi.decode(d1, (uint256));

        (bool ok2, bytes memory d2) =
            minter.staticcall(abi.encodeWithSignature("minted(address,address)", account, gauge));
        if (!ok2 || d2.length < 32) return 0;
        uint256 alreadyMinted = abi.decode(d2, (uint256));

        return integrateFraction > alreadyMinted ? integrateFraction - alreadyMinted : 0;
    }

    /// @notice Returns the extra reward token address at slot `i` (V2+ gauges).
    ///         Returns address(0) if the slot is empty or the method does not exist.
    function rewardToken(address gauge, uint256 i) internal view returns (address) {
        (bool ok, bytes memory data) = gauge.staticcall(abi.encodeWithSignature("reward_tokens(uint256)", i));
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return address(0);
    }

    /// @notice Claimable amount of `token` for `account` from a V3+ gauge.
    ///         Returns the stale-but-view-safe value from claimable_reward().
    ///         Note: V3 gauges update rewards at most hourly; value may be stale.
    function claimableReward(address gauge, address account, address token) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            gauge.staticcall(abi.encodeWithSignature("claimable_reward(address,address)", account, token));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _hasCoinMethod(address target) private view returns (bool) {
        (bool ok,) = target.staticcall(abi.encodeWithSignature("coins(uint256)", uint256(0)));
        if (ok) return true;
        (ok,) = target.staticcall(abi.encodeWithSignature("coins(int128)", int128(0)));
        return ok;
    }

    function _coin(address pool, uint256 i) private view returns (address) {
        // Try uint256 index (all modern pools: StableSwap 0.2+, StableSwap-NG, Crypto*, TriCryptoNG)
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("coins(uint256)", i));
        if (ok && data.length >= 32) {
            address coin = abi.decode(data, (address));
            if (coin != address(0)) return coin;
        }
        // Fallback: int128 index (original StableSwap, Vyper 0.1.x)
        (ok, data) = pool.staticcall(abi.encodeWithSignature("coins(int128)", int128(int256(i))));
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return address(0);
    }

    /// @notice Joins coin symbols with "/" — e.g. [USDC, DAI] → "USDC/DAI".
    /// @dev Shared by CurvePoolsMeta and CurveGaugesMeta to avoid duplicate code.
    function coinSymbols(address[] memory coins) internal view returns (string memory result) {
        for (uint256 i; i < coins.length; ++i) {
            string memory sym;
            try IERC20Symbol(coins[i]).symbol() returns (string memory s) {
                sym = s;
            } catch {
                sym = "?";
            }
            result = i == 0 ? sym : string.concat(result, "/", sym);
        }
    }
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}
