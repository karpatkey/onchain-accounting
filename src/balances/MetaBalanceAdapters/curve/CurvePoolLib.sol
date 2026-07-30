// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {LabelLib} from "src/balances/LabelLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";

/// @title CurvePoolLib
/// @notice Shared helpers for reading Curve pool and gauge state across all pool/gauge generations.
/// @dev Handles the three main interface divergences in the Curve ecosystem:
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

    /// @dev Curve's AddressProvider. Deterministically deployed to this same address on every Curve
    ///      network — verified identical code on mainnet, Arbitrum and Optimism. Read through guarded
    ///      staticcalls, so a chain without it simply falls through.
    address internal constant CURVE_ADDRESS_PROVIDER = 0x0000000022D53366457F9d5E68Ec105046FC4383;

    /// @dev Encoded once because both registry helpers ask the provider the same question.
    bytes private constant _GET_REGISTRY = abi.encodeWithSignature("get_registry()");

    // ─── LP Token / Pool resolution ───────────────────────────────────────────

    /// @notice Derives the LP token from a pool address.
    ///         For most classic pools, pool IS the LP token.
    ///         For TriCryptoNG, pool is also self-LP (no lp_token() method).
    ///         For StableSwap-NG factory pools, lp_token() returns a separate ERC20.
    /// @dev KNOWN, DELIBERATE UNDER-REPORT — legacy StableSwap pools are not resolved here.
    ///      3pool (`0xbEbc4478…`) exposes no `lp_token()` (verified on mainnet: it reverts), so this falls
    ///      through to "the pool IS the LP token". For 3pool that is false — its LP is the separate 3Crv, and
    ///      `balanceOf` on the pool also reverts — so wallet-LP decomposition for such pools reports NOTHING.
    ///
    ///      A registry fallback for this direction was written, measured working, and then REMOVED from the PR
    ///      that fixed `getPool`. The reason is SCOPE, and only scope: `getLpToken` has a THIRD consumer,
    ///      `CurvePoolsMetaBalanceAdapter`, which that PR did not touch. Resolving the LP flips it from emitting
    ///      nothing to emitting full `Supplied` coin legs — an unreviewed behavioural change to a file outside
    ///      that PR's diff, which belongs in a PR that reviews all three consumers together.
    ///
    ///      An earlier revision of this note gave a different reason: that resolving the LP would re-arm an
    ///      `ERC20Default` double-count for an operator who had registered the LP token as an asset. That is
    ///      recorded here as REFUTED, because it was measured and because it is the kind of claim that turns
    ///      into operator guidance. At block 22,500,000: `getLpToken(3pool)` returns the pool, `balanceOf` on
    ///      the pool reverts, `_balanceOf` fail-opens to 0, and `CurvePoolsMeta` therefore returns an EMPTY
    ///      array before reaching any leg — asserted by `assertEq(pos.length, 0)` in
    ///      `test_threepool_walletLp_decomposes`. There is no second count to double against. The hazard is a
    ///      constraint on the SUCCESSOR PR, once the fallback actually resolves the LP; it is not a property of
    ///      the code as it stands.
    ///
    ///      The fix belongs in its own PR that reviews all three consumers together — see the successor brief
    ///      in the PR that introduced this note. `_lpTokenFromRegistry` is retained below because `getPool`'s
    ///      round-trip validation depends on it.
    function getLpToken(address pool) internal view returns (address) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("lp_token()"));
        if (ok && data.length == 32) {
            address token = _firstAddress(data);
            if (token != address(0) && token != pool) return token;
        }

        return pool; // pool IS the LP token (classic StableSwap, TriCryptoNG)
    }

    /// @dev Curve's AddressProvider -> MainRegistry -> `get_lp_token`. Returns address(0) on any failure.
    ///      Bounded via {StaticCallLib.safeAddr} — see {_poolFromRegistry} for why that is load-bearing here.
    function _lpTokenFromRegistry(address pool) private view returns (address) {
        (, address registry) = StaticCallLib.safeAddr(CURVE_ADDRESS_PROVIDER, _GET_REGISTRY);
        if (registry == address(0)) return address(0);

        (, address lpToken) = StaticCallLib.safeAddr(registry, abi.encodeWithSignature("get_lp_token(address)", pool));
        return lpToken;
    }

    /// @notice Derives the pool address from an LP token.
    ///         Handles the self-LP case, the minter() pattern for NG pools, and the original StableSwap
    ///         generation whose LP tokens expose neither.
    ///         Returns address(0) if the pool cannot be determined.
    /// @dev    The third step exists because the first two miss the OLDEST pools, not the newest. 3Crv
    ///         (`0x6c3F90f0…`, the 3pool LP) is a CurveTokenV1: verified on mainnet, `coins(uint256)`,
    ///         `coins(int128)` and `minter()` ALL revert on it, while `symbol()` answers "3Crv". So both
    ///         heuristics fail and this returned `address(0)` — and every consumer gates its entire staking
    ///         decomposition on `pool != address(0)`, so a real staker in a 3pool gauge or a Convex 3pool
    ///         rewarder reported NO staking legs at all. An under-report, so the direction was safe, but a
    ///         silent one.
    ///
    ///         The Curve AddressProvider answers it. It lives at the same deterministic address on every
    ///         Curve deployment (verified: identical code on mainnet, Arbitrum and Optimism), and its
    ///         registry maps LP token -> pool for exactly the legacy generation the heuristics miss:
    ///         `get_pool_from_lp_token(3Crv)` returns `0xbEbc4478…` (the real 3pool) on mainnet.
    ///
    ///         The registry's answer is VALIDATED rather than trusted, and the validation must establish
    ///         CORRESPONDENCE, not plausibility. An earlier revision accepted any answer that merely responded
    ///         to `coins()` and claimed that was sufficient; it was not. `coins()` is a "looks like a Curve
    ///         pool" sniff that says nothing about whether that pool backs THIS lpToken, and a reviewer proved
    ///         it: pointing `get_registry()` at a 30-line contract implementing only `coins`/`balances`
    ///         inflated a Staking leg 12,213x (833.74 USDC reported as 10,182,786.55), because `totalSupply`
    ///         still came from the real LP while `balances` came from the impostor. So the answer is now
    ///         round-tripped through the registry's other direction — `get_lp_token(pool) == lpToken`.
    ///
    ///         BE PRECISE ABOUT WHAT THAT BUYS, because an earlier revision of this comment overclaimed and a
    ///         reviewer was right to reject it a second time. Both questions are answered by the SAME contract,
    ///         fetched through the SAME mutable `get_registry()` pointer. The round-trip therefore proves only
    ///         SELF-CONSISTENCY: it rejects a registry that is broken, stale or half-populated, and it rejects
    ///         the specific PoC that inflated a leg 12,213x with a stub implementing only `coins`/`balances`.
    ///         It does NOT defend against a hostile-but-consistent registry, and it cannot: legacy StableSwap
    ///         pools expose no on-chain backlink to their LP, which is the entire reason the registry is
    ///         consulted. There is nothing else to cross-check against.
    ///
    ///         So the trust boundary is explicit and unavoidable: whoever controls Curve's AddressProvider
    ///         admin can choose which pool backs a legacy LP's accounting. That is the same DAO that controls
    ///         the gauges and pools already governed into these adapters, but it IS a wider surface than
    ///         before, and it is stated here rather than implied. Every step is a guarded staticcall, so a chain with
    ///         no AddressProvider, an older one whose `get_registry()` returns zero (Base today), or an LP the
    ///         registry does not know, all degrade to the previous behaviour rather than reverting.
    function getPool(address lpToken) internal view returns (address) {
        // Fast path: check if lpToken has coins() — then it IS the pool
        if (_hasCoinMethod(lpToken)) return lpToken;

        // StableSwap-NG / TwoCryptoNG LP tokens have minter() pointing to the pool
        (bool ok, bytes memory data) = lpToken.staticcall(abi.encodeWithSignature("minter()"));
        if (ok && data.length == 32) {
            address minter = _firstAddress(data);
            if (minter != address(0)) return minter;
        }

        // Legacy StableSwap (CurveTokenV1/V2): neither coins() nor minter(). Ask the Curve registry.
        address fromRegistry = _poolFromRegistry(lpToken);
        if (fromRegistry != address(0) && _hasCoinMethod(fromRegistry) && _lpTokenFromRegistry(fromRegistry) == lpToken)
        {
            return fromRegistry;
        }

        return address(0); // Cannot resolve — consumers report the LP token itself rather than nothing
    }

    /// @dev Curve's AddressProvider -> MainRegistry -> `get_pool_from_lp_token`. Returns address(0) on any
    ///      failure at any hop; never reverts.
    ///
    ///      **Both hops are bounded, and that is load-bearing rather than tidiness.** The reply here is the only
    ///      value in this library fetched through a pointer a third party can repoint: `get_registry()` is
    ///      mutable by the AddressProvider admin, so the address of the contract answering the second hop is
    ///      not fixed at deploy time. Hand-rolled `target.staticcall(...)` forwards 63/64 of the frame and,
    ///      when destructured as `(bool ok, bytes memory data)`, `returndatacopy`s the WHOLE reply at the
    ///      caller's expense. Both were measured in this worktree against a stub registry: a gas-burning
    ///      registry turned a single-instance `CurveGaugesMeta` read from 86,771 gas into 28,710,283 and made
    ///      the read REVERT outright below roughly a 3M budget, and a 20,000-word reply cost the caller
    ///      1,877,102 gas for bytes it discards — a 21x amplification.
    ///
    ///      A hard revert is worse than the under-report this whole fallback exists to fix, because
    ///      `MetaBalanceAdapter`'s per-instance catch deliberately re-raises gas exhaustion rather than
    ///      substituting empty legs: one Curve gauge would make `getAccountNav` unreadable for the entire
    ///      account, and starve every adapter after it in a `PriceFeedLib` sweep. {StaticCallLib.probeWord}
    ///      caps the callee at {StaticCallLib.PROBE_GAS} and reads into a fixed 32-byte window, so the worst a
    ///      repointed registry can do is fail this hop — which degrades to the previous behaviour.
    ///
    ///      Masking ({safeAddr}) rather than rejecting ({safeAddrStrict}) is right here: a garbage answer has
    ///      to survive `_hasCoinMethod` AND the `get_lp_token` round-trip in {getPool} before it is used, so a
    ///      wrong address fails validation instead of changing an answer.
    function _poolFromRegistry(address lpToken) private view returns (address) {
        (, address registry) = StaticCallLib.safeAddr(CURVE_ADDRESS_PROVIDER, _GET_REGISTRY);
        if (registry == address(0)) return address(0);

        (, address pool) =
            StaticCallLib.safeAddr(registry, abi.encodeWithSignature("get_pool_from_lp_token(address)", lpToken));
        return pool;
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
        return Math.mulDiv(poolBalance, lpBalance, totalSupply);
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
        if (ok) return _firstAddress(data);
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
        if (ok) return _firstAddress(data);
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

    /// @dev Bounded, because {getPool} calls this on an address the CURVE REGISTRY chose. Leaving it unbounded
    ///      would have made bounding the two registry hops decorative: a repointed `get_registry()` returning a
    ///      gas-burning address still reaches here, and two unbounded probes burn 63/64 of the frame twice over.
    ///      The fast-path call site (`_hasCoinMethod(lpToken)`, on a MANAGER-governed LP) is bounded by the same
    ///      change; `coins(0)` is a single storage read on every real pool generation, orders of magnitude under
    ///      {StaticCallLib.PROBE_GAS}, so no honest pool is newly excluded.
    function _hasCoinMethod(address target) private view returns (bool) {
        (bool ok,,) = StaticCallLib.probeWord(target, abi.encodeWithSignature("coins(uint256)", uint256(0)));
        if (ok) return true;
        (ok,,) = StaticCallLib.probeWord(target, abi.encodeWithSignature("coins(int128)", int128(0)));
        return ok;
    }

    function _coin(address pool, uint256 i) private view returns (address) {
        // Try uint256 index (all modern pools: StableSwap 0.2+, StableSwap-NG, Crypto*, TriCryptoNG)
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("coins(uint256)", i));
        if (ok) {
            address coin = _firstAddress(data);
            if (coin != address(0)) return coin;
        }
        // Fallback: int128 index (original StableSwap, Vyper 0.1.x)
        (ok, data) = pool.staticcall(abi.encodeWithSignature("coins(int128)", int128(int256(i))));
        if (ok) return _firstAddress(data);
        return address(0);
    }

    /// @notice First returned word as an address, or `address(0)` when the reply is not one clean address word.
    /// @dev Every address reader in this library funnels through here instead of `abi.decode(data, (address))`,
    ///      which REVERTS on a word whose upper 96 bits are dirty. A length check is not a range check, and these
    ///      readers back `positionLabels` — a display-only view that must never revert, reachable with an arbitrary
    ///      caller-supplied pool/gauge address — as well as the NAV read path.
    ///
    ///      **Rejects rather than masks.** `address(uint160(raw))` on a dirty word could name a DIFFERENT live pool
    ///      or token, which on the NAV path would decompose and value the wrong thing. `address(0)` is the
    ///      "unresolved" sentinel every caller here already handles (skip the LP decomposition, drop the reward
    ///      slot, collapse the label leaf), so a malformed reply lands on the established degraded path — an
    ///      under-report — instead of reverting or inventing an address.
    ///
    ///      A short or empty reply also yields `address(0)`, which is why the callers no longer pre-check
    ///      `data.length >= 32`: that check lives here, applied uniformly.
    function _firstAddress(bytes memory data) private pure returns (address) {
        if (data.length < 32) return address(0);
        uint256 raw = abi.decode(data, (uint256));
        if (raw >> 160 != 0) return address(0);
        return address(uint160(raw));
    }

    /// @notice Joins coin symbols with "/" — e.g. [USDC, DAI] → "USDC/DAI".
    /// @dev Shared by CurvePoolsMeta and CurveGaugesMeta. Delegates the per-coin read to the shared
    ///      `LabelLib.symbol` (codesize-guarded + try/catch fail-open, "?" fallback) so the convention stays
    ///      identical to every other AMM meta-adapter — including Curve's native-ETH sentinel (0xEEee…EEeE),
    ///      a codeless address whose high-level `symbol()` call would otherwise revert via the extcodesize check.
    function coinSymbols(address[] memory coins) internal view returns (string memory result) {
        for (uint256 i; i < coins.length; ++i) {
            string memory sym = LabelLib.symbol(coins[i], "?");
            result = i == 0 ? sym : string.concat(result, "/", sym);
        }
    }
}
