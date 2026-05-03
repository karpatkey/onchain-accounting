# 0006 — Aave Umbrella Balance Oracle: hardcoded stake-token list, two-hop ERC4626

**Status:** accepted

## Context

Aave Umbrella is the successor to the legacy Aave V3 Safety Module. It deploys a new contract architecture (`Umbrella` controller, per-asset `UmbrellaStakeToken` ERC4626 vaults, and a multi-reward `RewardsController`) that the existing `AaveV3SafetyModuleBalanceOracle` adapter does not see — that adapter only knows about the four legacy stake tokens (`stkAAVE`, `stkABPT`, `stkABPTv2`, `stkGHO @ 0x1a88…1d`). ADR 0005 anticipated this transition: *"A future Aave Umbrella migration (where `stkGHO` becomes `sGHO`, etc.) requires a new adapter altogether — Umbrella uses different contracts (`Umbrella` / `StakeToken` / `RewardsController`) with different interfaces. That work goes in its own ADR."*

The Umbrella set on Mainnet (verified via `RewardsController.getAllAssets()` at planning time):

| Symbol | Stake-token address | `asset()` | Reward token |
|---|---|---|---|
| stkwaEthUSDC.v1 | `0x6bf183243FdD1e306ad2C4450BC7dcf6f0bf8Aa6` | waEthUSDC `0xD4fa…3E` | aEthUSDC `0x98C2…5c` |
| stkwaEthUSDT.v1 | `0xA484Ab92fe32B143AEE7019fC1502b1dAA522D31` | waEthUSDT `0x7Bc3…F8` | aEthUSDT `0x2387…6a` |
| stkwaEthWETH.v1 | `0xaAFD07D53A7365D3e9fb6F3a3B09EC19676B73Ce` | waEthWETH `0x0bfc…02` | aEthWETH `0x4d5F…E8` |
| stkGHO.v1 | `0x4f827A63755855cDf3e8f3bcD20265C833f15033` | GHO `0x40D1…2f` | GHO (no aToken) |

All four share the same `RewardsController` at `0x4655Ce3D625a63d30bA704087E52B4C31E38188B`.

## Decision

Ship a new, separate `AaveUmbrellaBalanceOracle` (`src/balances/protocols/AaveUmbrella.sol`) that mirrors the design philosophy of ADR 0005's `AaveV3SafetyModuleBalanceOracle`: **fully immutable, write-function-free, addresses pinned as compile-time `address public constant`**, with the stake-token table assembled in a `pure _records()` helper. Constructor takes only `(navCalculator, protocol)`. The legacy SM adapter remains in place — it owns the legacy four stake tokens; this adapter owns the Umbrella four. Both can be registered on `NAVCalculator` simultaneously without overlap.

The adapter emits **two `PositionBalance` entries per stake token** with self-describing labels:

- Staked leg: `(<bareReserve>, "<symbol> Staked")`, e.g. `(USDC, "stkwaEthUSDC.v1 Staked")`.
- Rewards leg: `(<bareReserve>, "<symbol> Rewards")`, e.g. `(USDC, "stkwaEthUSDC.v1 Rewards")`.

Both legs land in the same bare reserve token (`USDC` / `USDT` / `WETH` / `GHO`) so that NAVCalculator can price them out of the existing Chainlink registry without a new price feed. Reward aTokens are 1:1 unit-equivalent with their underlying reserve, so reporting reward amounts in the bare reserve is unit-correct.

Two-hop ERC4626 conversion handles the wa-backed stake tokens:

```
shares  --stk.convertToAssets-->  waToken amount  --wa.convertToAssets-->  bare reserve
```

For `stkGHO.v1` the underlying is plain GHO and a single hop (`stk.convertToAssets`) suffices.

## Why hardcoded, when on-chain enumeration is available

The Umbrella `RewardsController` does expose `getAllAssets() → address[]` for on-chain stake-token enumeration — strictly more discovery surface than the legacy SM has. We chose **not** to use it at runtime, for the same reasons ADR 0005 chose hardcoding for the legacy SM:

- Framework rule: "every balance adapter is immutable and write-function-free." Adding a runtime registry call doesn't violate that, but a *fully* hardcoded list keeps every wiring decision under PR review and matches the precedent.
- A new Umbrella stake token implies a new bare-reserve mapping (which `waToken` wraps it; which aToken pays its rewards). That mapping cannot be inferred from `getAllAssets()` alone — the adapter would still need the bare-reserve correspondence pinned in source. Pinning the addresses too is a strict superset.
- The test suite (`test/balances/protocols/fork/AaveUmbrella.fork.t.sol`) **does** call `getAllAssets()` and asserts the live set equals the hardcoded set. A governance addition therefore surfaces immediately as a fork-test failure, prompting a deliberate code change rather than silently being ignored.

## Slashing and cooldown semantics

`UmbrellaStakeToken` is ERC4626; slashing decreases `totalAssets` while leaving `totalSupply` constant, so `convertToAssets(balanceOf(user))` is automatically post-slash-correct without extra accounting. Cooldown / unstake-window state does not affect `balanceOf`, so the adapter reports total staked principal regardless of which window the user is in. Downstream consumers that need cooldown-state breakdowns query the stake token directly.

## Reward-token forward compatibility

Each stake token currently pays one reward token (the matching aToken; or GHO for stkGHO). The adapter pulls `(rewardTokens[], amounts[])` via `RewardsController.calculateCurrentUserRewards(stakeToken, user)` and only emits a position for the **hardcoded expected** reward token; additional reward tokens added by Aave governance in the future are silently dropped (with a clear comment in source). That tradeoff is intentional: the bare-reserve mapping for any new reward token requires a deliberate code change, not a silent misattribution.

## Consequences

**Positive**

- Same uniform rule across the framework — every balance adapter is immutable and review-time-wired.
- No admin role, no Ownable. Constructor takes two arguments. Chain config has only one field (`protocol`).
- Live `getAllAssets()` in the fork test acts as a tripwire when Aave governance adds a new Umbrella stake token.
- Reports in bare reserves means NAVCalculator prices everything via existing Chainlink feeds — no new price-feed adapters required for this PR.

**Negative / things to watch**

- Adding a new Umbrella stake token requires a code change + redeploy + Safe transaction. Higher friction than a runtime registry would offer, but acceptable for events that happen at most once or twice a year.
- Mainnet-only in spirit. The constants are baked in; running this contract on any other chain would resolve the addresses to EOAs and revert at the first `IUmbrellaStakeToken.balanceOf` call. Chain config gates deployment per-chain, so this is not a runtime hazard, but it is worth keeping in mind.
- Additional reward tokens added by governance for an existing stake token (e.g. an AAVE incentive on top of the aToken reward) are silently dropped until a code change extends the per-stake-token reward mapping.

## Debank cross-check classification

Debank surfaces Umbrella positions under the existing `aave3` (Aave V3) protocol id rather than a dedicated `aaveumbrella` entry. Verified by querying `/v1/user/all_complex_protocol_list` for a real stkGHO.v1 holder: the `aave3` portfolio item lists both the staked GHO supply leg and the GHO rewards leg matching our adapter's output unit-for-unit. Since `aave3` is already in `test/integration/accounts.json`'s Mainnet `supportedDebankProtocols` allowlist, **no allowlist change is required** — the cross-check transparently includes Umbrella the moment an account holds an Umbrella position.

The legacy SM's `aave2` carve-out (per ADR 0005) is independent of this and remains in place: legacy stkAAVE / stkABPT rewards are still surfaced under `aave2` by Debank.

## Test holders

Fork tests cover all four stake tokens against real holders sourced from Etherscan top-holder views, verified to have non-zero stake balances **and** non-zero accrued rewards at `FORK_BLOCK = 25_000_000`:

| Stake token | Holder |
|---|---|
| stkwaEthUSDC.v1 | `0xd0002c648CCa8DeE2f2b8D70D542Ccde8ad6EC03` |
| stkwaEthUSDT.v1 | `0x7FE4b2632f5AE6d930677D662AF26Bc0a06672b3` |
| stkwaEthWETH.v1 | `0x000000000004444c5dc75cB358380D2e3dE08A90` (also the legacy SM stkAAVE / stkABPTv2 holder used in ADR 0005's fork tests) |
| stkGHO.v1 | `0x6Ca0D65fe5c8700a5cc7A2C3bfE801111A1dEd1a` |

When refreshing fork blocks (via the bump workflow described in `docs/howto/refresh-integration-test-blocks.md`), re-verify these addresses still hold positions; if a holder withdraws, swap in a fresh one from an Etherscan top-holder scan or a Transfer-events scan over recent blocks.

## Alternatives considered

1. **Inherit from `RewardsController.getAllAssets()` at runtime.** Rejected per the rationale above — the bare-reserve mapping cannot be derived from the registry alone, so hardcoding the address set is at no extra cost over hardcoding the mapping.
2. **Report positions in waToken or aToken units instead of the bare reserve.** Rejected because NAVCalculator does not have price feeds registered for waEth* or aEth* (only for the bare reserves). Adding four custom price feeds would be a larger surface area and require independent ADRs.
3. **Reuse `AaveV3SafetyModuleBalanceOracle` and add Umbrella entries to its hardcoded table.** Rejected because the two protocols have entirely different interfaces (`stkAAVE.previewRedeem`/`getTotalRewardsBalance` vs. `UmbrellaStakeToken.convertToAssets` + `RewardsController.calculateCurrentUserRewards`). One adapter per protocol-shape keeps each adapter narrow.
4. **Merge staked + rewards into a single position when both legs land in the same bare reserve (mirroring the legacy SM's `stkAAVE` collapse).** Rejected because the value of the user's "position" is more useful broken out — the staked principal accrues yield via the waToken's exchange rate, while the rewards are claimable but unclaimed aToken balances. Two `PositionBalance` entries with distinct `positionDetail` strings preserve that breakdown for downstream accounting.

## Reference

- Adapter: `src/balances/protocols/AaveUmbrella.sol`
- Tests: `test/balances/protocols/AaveUmbrella.t.sol` (unit), `test/balances/protocols/fork/AaveUmbrella.fork.t.sol` (fork)
- Deploy schema: `script/config/chains/1.json` `balanceAdapters.AaveUmbrella` (only `protocol` field)
- Aave Umbrella source: <https://github.com/aave-dao/aave-umbrella>
- Companion ADR: [0005 — Aave V3 Safety Module: hardcoded stake-token list, immutable adapter](0005-aave-safety-module-hardcoded-immutable.md)
