# 0006 — Aave Umbrella Balance Adapter: dynamic discovery via RewardsController

**Status:** accepted

## Context

Aave Umbrella is the successor to the legacy Aave V3 Safety Module. It deploys a new contract architecture (`Umbrella` controller, per-asset `UmbrellaStakeToken` ERC4626 vaults, and a multi-reward `RewardsController`) that the existing `AaveV3SafetyModuleBalanceAdapter` adapter does not see — that adapter only knows about the four legacy stake tokens (`stkAAVE`, `stkABPT`, `stkABPTv2`, `stkGHO @ 0x1a88…885d`). ADR 0005 anticipated this transition: *"A future Aave Umbrella migration … requires a new adapter altogether — Umbrella uses different contracts (`Umbrella` / `StakeToken` / `RewardsController`) with different interfaces. That work goes in its own ADR."*

The Umbrella set on Mainnet today (verified via `RewardsController.getAllAssets()` at planning time): `stkwaEthUSDC.v1`, `stkwaEthUSDT.v1`, `stkwaEthWETH.v1`, `stkGHO.v1`. All four share the same `RewardsController` at `0x4655Ce3D625a63d30bA704087E52B4C31E38188B`. The wa-backed stake tokens hold StataTokenV2 wrappers (waEthUSDC etc.) over the matching aTokens; rewards are paid in the matching aToken. `stkGHO.v1`'s `asset()` is plain GHO and its reward is also plain GHO.

## Decision

Ship a new, separate `AaveUmbrellaBalanceAdapter` (`src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol`). The adapter is fully **immutable** and **write-function-free**, but unlike ADR 0005 (legacy SM, where Aave does not publish an on-chain registry) **no stake-token, waToken, aToken, or reserve addresses are pinned in source**. The constructor takes only:

```solidity
constructor(address rewardsController, address navCalculator)
```

The `rewardsController` is the protocol's trust anchor — every other piece of information is discovered at runtime through it:

- **Stake-token set.** `RewardsController.getAllAssets() → address[]` enumerates every Umbrella stake token currently configured. Aave governance can add a new stake token and the adapter picks it up on the next view call without a redeploy.
- **Bare reserve per stake token.** The adapter walks the ERC4626 `asset()` chain (following at most one wrapper hop) until it lands on a non-ERC4626 token, probing each level with a bounded-gas low-level `staticcall` to detect the boundary. For the wa-backed stake tokens this resolves `stk → waToken → bare reserve`; for `stkGHO.v1` a single hop yields plain GHO.
- **Bare reserve per reward token.** The adapter calls `IAToken.UNDERLYING_ASSET_ADDRESS()` via a bounded-gas low-level `staticcall`; aTokens return the bare reserve, and any reward token that does not implement that getter (e.g. plain GHO) is treated as already-bare.

For each stake position the adapter emits up to two `PositionBalance` entries:

- Staking leg (`positionKind = Staking`) — principal denominated in the bare reserve. The `positionId` (encoding the stakeToken address) disambiguates which stake token the position belongs to.
- Rewards leg (`positionKind = Rewards`) — claimable but unclaimed rewards, also in the bare reserve. Reward aTokens are 1:1 unit-equivalent with their underlying so the amount returned by `calculateCurrentUserRewards` is treated as bare-reserve-denominated.

Stake tokens whose bare reserve is not registered with `NAVCalculator` are silently skipped — the same convention `AaveV3InstancesMetaBalanceAdapter` uses for unregistered Aave reserves.

## Why dynamic over hardcoded

ADR 0005 hardcodes the legacy Safety Module set because Aave does not publish an on-chain registry for it. Umbrella ships with one (`getAllAssets()`), and other adapters in this repo (notably `AaveV3InstancesMetaBalanceAdapter`, which discovers reserves via `dataProvider.getAllReservesTokens()`) follow the *use the registry when it exists* convention. We do the same here:

- A new Umbrella stake token (or a re-configured reward token on an existing one) does not require a code change or a redeploy. The adapter picks up governance changes the next time NAV is computed.
- The constructor surface stays minimal — one trust-anchor address, no per-token plumbing — so the only config field the deploy script reads for this adapter is `rewardsController` (the deployment-config object also carries the boilerplate `protocol` / `positionDetail` / `positionId` keys, but `04_DeployBalanceAdapters.s.sol` passes only `rewardsController` to the constructor).
- The bounded-gas `staticcall` walk over `asset()` and `UNDERLYING_ASSET_ADDRESS()` is cheap (a handful of view calls per stake token) and isolates the adapter from any single adversarial token contract: a misbehaving wrapper that reverts on `asset()` (or burns gas in its fallback) simply terminates the walk at that level.

The adapter still pins **one** address — the `RewardsController` — as constructor input. That is the protocol's trust root: the entire stake-token graph reachable from it is treated as trusted. If governance ever ships a second controller (covering a disjoint stake-token set), this adapter would be redeployed pointing at the new controller; both adapters could be registered on `NAVCalculator` simultaneously.

## Slashing and cooldown semantics

`UmbrellaStakeToken` is ERC4626; slashing decreases `totalAssets` while leaving `totalSupply` constant, so the chained `convertToAssets` walk is automatically post-slash-correct without extra accounting. Cooldown / unstake-window state does not affect `balanceOf`, so the adapter reports total staked principal regardless of which window the user is in. Downstream consumers that need cooldown-state breakdowns query the stake token directly.

## Reward-token forward compatibility

Each stake token currently pays one reward token (the matching aToken; or GHO for stkGHO). The adapter pulls the full `(rewardTokens[], amounts[])` tuple via `RewardsController.calculateCurrentUserRewards(stakeToken, user)` and emits one `Rewards` leg per non-zero entry whose mapped bare reserve equals the stake token's staked-side bare reserve. If governance adds an extra reward token whose bare reserve differs (e.g. an AAVE incentive on top of the aToken reward), it would be silently dropped — `_claimableRewardInBareReserve` only sums entries that map to the same `wantedBareReserve`. This is conservative by design: surfacing AAVE rewards inside an entry whose `balanceAsset` is USDC would mis-price them. If/when multi-reward Umbrella stake tokens go live, the framework can either extend this adapter to emit additional `Rewards` legs per reward bare reserve or rely on the existing `ERC20DefaultBalanceAdapter` to surface the held AAVE balance separately.

## Debank cross-check classification

Debank surfaces Umbrella positions under the existing `aave3` (Aave V3) protocol id rather than a dedicated `aaveumbrella` entry. Verified by querying `/v1/user/all_complex_protocol_list` for a real `stkGHO.v1` holder: the `aave3` portfolio item lists both the staked GHO supply leg and the GHO rewards leg matching this adapter's output unit-for-unit. Since `aave3` is already in `test/integration/accounts.json`'s Mainnet `supportedDeBankProtocols` allowlist, **no allowlist change is required** — the cross-check transparently includes Umbrella the moment an account holds an Umbrella position.

The legacy SM's `aave2` allowlist entry (in `accounts.json`'s Mainnet `supportedDeBankProtocols`) is independent of this and remains in place: legacy stkAAVE / stkABPT rewards are still surfaced under `aave2` by Debank.

## Consequences

**Positive**

- One uniform rule across the framework: adapters use the protocol's on-chain registry when it exists. Matches `AaveV3InstancesMetaBalanceAdapter`'s precedent.
- No hardcoded token addresses anywhere in source. The only address pinned is the `RewardsController`, passed via constructor and treated as a trust anchor — it is the only deployment-config field the script consumes for this adapter.
- Aave governance can add a new Umbrella stake token (or change its reward configuration) and the adapter picks it up on the next view call, provided the bare reserve is already registered with `NAVCalculator`.
- Reports in bare reserves means NAV pricing falls through to existing Chainlink feeds — no new price-feed adapters required for this PR.

**Negative / things to watch**

- A few extra view calls per `getAdapterPositions` invocation (per stake token: `balanceOf` + `convertToAssets` + a couple of bounded-gas `asset()` / `convertToAssets(0)` probes + per-reward `UNDERLYING_ASSET_ADDRESS`). Acceptable for a view function called for NAV computation, not on a hot path.
- A misconfigured RewardsController that returns malicious stake-token addresses would be trusted. This is the same trust assumption every dynamically-discovered adapter has — mitigated by pinning the *controller* address at deploy time, so the trust root is fixed even though the discovered set is not.
- Multi-reward stake tokens whose extra rewards land in a *different* bare reserve are silently dropped (rather than mis-attributed). When this becomes a real configuration, extend the adapter to emit additional `Rewards` legs per distinct reward bare reserve.
- Mainnet-only in spirit. The RewardsController is Mainnet-specific; deploying on another chain requires passing that chain's controller (or none, if Umbrella is not deployed there).

## Test holders

Fork tests cover the four currently-deployed stake tokens against real holders sourced from Etherscan top-holder views, verified to have non-zero stake balances **and** non-zero accrued rewards at `FORK_BLOCK = 25_287_877` (the verification block; see the fork test for the canonical value):

| Stake token | Holder |
|---|---|
| stkwaEthUSDC.v1 | `0xd0002c648CCa8DeE2f2b8D70D542Ccde8ad6EC03` |
| stkwaEthUSDT.v1 | `0x7FE4b2632f5AE6d930677D662AF26Bc0a06672b3` |
| stkwaEthWETH.v1 | `0x000000000004444c5dc75cB358380D2e3dE08A90` (also the legacy SM stkAAVE / stkABPTv2 holder used in ADR 0005's fork tests) |
| stkGHO.v1 | `0x6Ca0D65fe5c8700a5cc7A2C3bfE801111A1dEd1a` |

The fork test maps live `getAllAssets()` entries to test holders by **symbol**, so a governance addition that introduces a new symbol surfaces immediately as a `revert` ("no test holder for new Umbrella stake token: <symbol>"), prompting a test update rather than silently passing.

When refreshing fork blocks, re-verify these addresses still hold positions; if a holder withdraws, swap in a fresh one from an Etherscan top-holder scan or a Transfer-events scan over recent blocks.

## Alternatives considered

1. **Hardcode every stake-token, waToken, aToken, and reserve address as `address public constant` in source (mirroring ADR 0005).** Rejected because Umbrella, unlike the legacy SM, exposes a usable on-chain registry. The framework convention is *use the registry when it exists* (cf. `AaveV3InstancesMetaBalanceAdapter`), and a code change every time governance adds a stake token is friction the registry lets us avoid.
2. **Hybrid: pass the stake-token list via constructor but discover the rest dynamically.** Rejected because the stake-token list is the part most likely to change. Pinning the controller and discovering everything beneath it from a single trust anchor is a strict simplification.
3. **Report positions in waToken or aToken units instead of the bare reserve.** Rejected because `NAVCalculator` does not have price feeds registered for waEth* or aEth* (only for the bare reserves). Adding four custom price feeds would be a larger surface area and require independent ADRs.
4. **Reuse `AaveV3SafetyModuleBalanceAdapter` and add Umbrella entries.** Rejected because the two protocols have entirely different read interfaces (`stkAAVE.previewRedeem` / `getTotalRewardsBalance` vs. `UmbrellaStakeToken.convertToAssets` + `RewardsController.calculateCurrentUserRewards`). One adapter per protocol-shape keeps each adapter narrow.
5. **Merge Staked + Rewards into a single position when both legs land in the same bare reserve (mirroring the legacy SM's stkAAVE collapse).** Rejected because the value of the user's "position" is more useful broken out — the staked principal accrues yield via the waToken's exchange rate, while the rewards are claimable but unclaimed aToken balances. Two `PositionBalance` entries with distinct `positionKind` values (`Staking` for the staked principal, `Rewards` for the claimable rewards) preserve that breakdown for downstream accounting.

## Reference

- Adapter: `src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol`
- Tests: `test/balances/protocols/AaveUmbrellaBalanceAdapter.t.sol` (unit), `test/balances/protocols/fork/AaveUmbrellaBalanceAdapter.fork.t.sol` (fork)
- Deploy schema: `script/config/contracts-deployment-config/balance-adapters/1.json` `AaveUmbrella` (`04_DeployBalanceAdapters.s.sol` reads only `rewardsController` from this object; `navCalculator` is injected by the script)
- Aave Umbrella source: <https://github.com/aave-dao/aave-umbrella>
- Companion ADR: [0005 — Aave V3 Safety Module: hardcoded stake-token list, immutable adapter](0005-aave-safety-module-hardcoded-immutable.md)
