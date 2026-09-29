# PR #338 deploy log

What was actually broadcast, per chain, with the gate results. The steps are defined in
[`PR338_EXECUTION_SHEET.md`](PR338_EXECUTION_SHEET.md). Fleet-wide addresses:

- NAV proxy `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` (unchanged: upgraded in place)
- new implementation `0xA7243DCDF7e4D6f8FA20A9F022186C0d0778C2b6` (was `0x40e4134849308d53F85A8B685324E2189b13ff7D`)
- `PriceFeedLib` `0x0f913658d70BB19b7B42eF9926c3df7c70fafCf2`, `NAVRegistryLib` `0x3D5369B0b2044d62a8f643bf9a2b8CC03775934D`
- ops Safe `0xEEd8dC3c034Be12ff66646cCaAf07D35C43E8AA1` (1/1, deployer; MANAGER only, revoked after Phase 2)

Per-chain adapter addresses: `script/config/deployments/<chainId>.json` (new) and `<chainId>.pre-swap.json` (old).
Broadcast details: `broadcast/01_2_*/<chainId>/`, `broadcast/04_*/<chainId>/`.

## Phase 1 — 2026-09-29 (no NAV effect)

| Chain | Commit | `phase1` gate | ops Safe deploy | ops Safe MANAGER grant | Verified |
|---|---|---|---|---|---|
| 10 Optimism | `14baac22` | 11/11 | `0x5f5947207bc26516b1da1fc76f960e7af9ef8c30c4e797c4c35cec9d6ba68004` | `0x4c5257cfbaab66eeb6ec87cf6e00aff40f5d2f7b801b8138589fa1191dcd7d0d` | all |
| 100 Gnosis | `d14b24b8` | 13/13 | `0xfbf086f9cff2867b707117738fbd93f19917503331a517719c24ffdc24fb48e1` | `0x253a82a4d55c3a25f926ad6b500ce8bde46fbbcf036b573c91a4457d9f116575` | all |
| 8453 Base | `8943500d` | 19/19 | (see broadcast) | `0xc2a76c59791f3e4ac7a62ed670eee6152e31ce49eca575fd806e0c9ed9401396` | all |
| 42161 Arbitrum | `c75e8979` | 25/25 | `0x39c3ef9395c7f4073bf76c301ee83399fd3a6a278ba888e9216061f43b8bef46` | `0x912a8a81ad6d4c5777056ca1802283662c75ff01fa4456b4ed202661a25f1c68` | pending (Arbiscan queue) |
| 1 Ethereum | `2bdc492b` | 56/56 | `0x8942a3bc58b91ae4d1a8353254003c6f93f408ac82e30584df709570f714ee33` | `0x392b0a58427d50aa2be1129b2541bb1a2b80147fad668545962c46960642e93b` | in progress |

## Phase 2 — upgrade + swap

### 10 Optimism — 2026-09-29

| Step | Tx | Result |
|---|---|---|
| snapshot s0 (before upgrade) | — | block 157555944, impl `0x40e41348`, NAV $5,168.47, 0 errors |
| `upgradeToAndCall` | `0xd6d84b1f4b307fa0c91c8b086b8af17ca418b444f9a1b7710a62dfbd75827434` | `upgrade` gate 3/3 (2 endpoints) |
| snapshot s1 (new impl, old adapters) | — | **0 differences vs s0**, NAV $5,168.47 (identical) |
| swap batch (6 calls, 1 tx via ops Safe) | `0xdd44ae41ec06d4684e99c5b37aae7c41856659d581ca9e57cbf91c9a4913f921` | gas 537,458 (= rehearsal) |
| wallet-adds batch (1 call, 1 tx via ops Safe) | `0xd4d5c93470d4905c465281a2d03101174bc3deaf2120333a9bedbdbb27655c1c` | gas 251,754 (= rehearsal) |
| `swap` gate | — | 18/18 |
| snapshot s2 | — | every position amount identical to s1; NAV −$0.22 = ETH price move between blocks; 0 health flags |
| `06` idempotence | — | nothing left |
| revoke ops Safe MANAGER | `0x9bedec9751556e16ea9a25660d39244eea6b64e84a45b9537fbed6263a23e73a` | ops Safe holds no role |

Note: the tracked Optimism account holds only wallet ETH/COMP/USDC/USDT, so no live position went through a
new adapter here — this chain proves the mechanics; Base/Arbitrum are the first with positions in swapped adapters.

### 100 Gnosis — 2026-09-29

| Step | Tx | Result |
|---|---|---|
| snapshot s0 | — | block 48504550, impl `0x40e41348`, NAV $5.034, 0 errors |
| `upgradeToAndCall` | `0x32b927189560a63f6e70e290505396a237af3b4b66dfa47df4bb7b453cb5e410` | `upgrade` gate 3/3 |
| snapshot s1 | — | **0 differences vs s0** |
| swap batch (9 calls: AaveV3, StakeWiseV3Vaults, UniswapV3Pools) | `0x9943d00fc1dfa0ed87f9ff1e39caccec4d89efb6fe977fb602952657f37b7df1` | gas 1,034,627 (= rehearsal) |
| wallet-adds batch (Lido, SkySavings, StakeWise osToken) | `0xaf21247b19cb0b5b8d0b0c0e23020ae3646bed16e84092541f60e7348de23f2e` | gas 579,200 (= rehearsal) |
| `swap` gate | — | 27/27 |
| snapshot s2 | — | every amount identical except Aave WXDAI collateral +interest (read through the NEW Aave adapter); sDAI Wallet → Supplied, same amount; 0 health flags |
| `06` idempotence | — | nothing left |
| revoke ops Safe MANAGER | `0x6265780dd9d88dd4ec16c2382a8121e60fc589214ff8223a42c94864c8d231cb` | ops Safe holds no role |

## Phase 3 — heartbeats

| Chain | Result |
|---|---|
| 10 Optimism | nothing to realign (10 configured heartbeats already match); `verify()` OK; backfill `NothingToDo` |
| 100 Gnosis | nothing to realign; `verify()` OK; backfill `NothingToDo` |
