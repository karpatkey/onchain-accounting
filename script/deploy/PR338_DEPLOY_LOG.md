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
| 42161 Arbitrum | `c75e8979` | 25/25 | `0x39c3ef9395c7f4073bf76c301ee83399fd3a6a278ba888e9216061f43b8bef46` | `0x912a8a81ad6d4c5777056ca1802283662c75ff01fa4456b4ed202661a25f1c68` | all (Arbiscan + Sourcify) |
| 1 Ethereum | `2bdc492b` | 56/56 | `0x8942a3bc58b91ae4d1a8353254003c6f93f408ac82e30584df709570f714ee33` | `0x392b0a58427d50aa2be1129b2541bb1a2b80147fad668545962c46960642e93b` | all |
| 137 Polygon | `1f0d214c` | 8/8 | `0xda6cbde7186ee0330807b48ff23d3abc05a70ecbb17f5496dd487ea7b4e012f5` | `0xc1b7ad74c156a9191a7ea739a7acaa43252a12d0a9f281777f27925176ab12e2` | all |
| 56 BSC | `9d0088a4` | 7/7 | — (upgrade-only) | — | all |
| 5042 Arc | `39333555` | 6/6 | `0xc8f59d885db73fa5d6a71bce8176eca91e22fd702930732fd2353312e1cd7f09` | `0xbcb437123e18172f5b222fb3d66068d06bb0ae9f823711872ac583da0f0a0edf` | all |

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

### 8453 Base — 2026-09-29 (Phase 2 + 3)

| Step | Tx | Result |
|---|---|---|
| snapshot s0 | — | block 51962074, impl `0x40e41348`, NAV $400,163.77, 0 errors |
| `upgradeToAndCall` | `0x0e32dc1d35f8b653bd39c1c46674413f4f5a1005e2395efee17f6f5c459392c8` | `upgrade` gate 3/3 |
| snapshot s1 | — | **0 differences vs s0** (NAV +$0.04 accrual) |
| swap batch (18 calls: AaveV3, MorphoMarkets, BalancerV3 Pools+Gauges, FluidFTokens, CompoundV3) | `0x0139fd1e02e262c54637040e9f99e83ff8e7d77efa18b4731158da68b3443386` | gas 1,633,946 (= rehearsal); PancakeSwapV3 skipped (disabled, never deployed) |
| wallet-adds batch (Coinbase cbETH, EtherFi weETH, Lido wstETH) | `0xc078da91838f0fef4b5639bdb01f6bc37891dea76942589ab3090278822b2501` | gas 579,200 |
| `swap` gate | — | 45/45 |
| snapshot s2 | — | 7→7 positions, none lost/added; USDC Supplied $399,775 (Compound V3) now read by the NEW adapter, +$0.38 interest only; COMP Rewards moved adapter, same amount; 0 health flags |
| `06` idempotence | — | nothing left |
| revoke ops Safe MANAGER | `0xe47c84d7cb1fe9fc7d08bbd7837be85fdc4cd78f00c2e9ce4a99ba30e89d0a3e` | ops Safe holds no role |
| Phase 3 heartbeats | — | nothing to realign; `verify()` OK; backfill `NothingToDo` |

### 42161 Arbitrum — 2026-09-29 (Phase 2 + 3)

| Step | Tx | Result |
|---|---|---|
| snapshot s0 | — | block 510138707, impl `0x40e41348`, NAV $1,882,991.82, 0 errors |
| `upgradeToAndCall` | `0xeb6d23be56b4338344535b60376736f9a9730f0f5954d788cb1c4063a905b238` | `upgrade` gate 3/3 |
| snapshot s1 | — | **0 differences vs s0** |
| swap batch (21 calls: AaveV3, MorphoVaults, MorphoMarkets, BalancerV3 Pools+Gauges, FluidFTokens, CompoundV3) | `0xc16798e45445ad099d34b02b7df7e5b65b65ec5eee993bef86c935227e33c5c1` | gas 1,760,141 (rehearsal 1,744,981; Arbitrum gasUsed includes a variable L1 component) |
| wallet-adds batch (EtherFi, Kelp, Lido, Maple, Renzo) | `0x398be6f15b21c681d9b4940fb19b94a0af29a43c46421f6d9267f9c467812e88` | gas 904,781 |
| `swap` gate | — | 56/56 |
| snapshot s2 | — | 12→12 positions, none lost/added; 8 now read by NEW adapters (incl. USDC Supplied $1.48M + $406k); amounts only up (interest); syrupUSDC Wallet → Supplied same amount; NAV −$3.13 = USDC oracle 1.00000787 → 1.00000580; 0 health flags |
| `06` idempotence | — | nothing left |
| revoke ops Safe MANAGER | `0x5b79252143f68a80576db5f513b5a8153d6c5ec2b3dd396cc410314945922e7d` | ops Safe holds no role |
| Phase 3 heartbeats | — | nothing to realign; `verify()` OK; backfill `NothingToDo` |

### 1 Ethereum — 2026-09-29 (Phase 2 + 3)

| Step | Tx | Result |
|---|---|---|
| snapshot s0 | — | block 26086301, impl `0x40e41348`, NAV $132,308,262.00, 0 errors; 18 meta sets / 74 instances = this morning's pre-snapshot |
| `upgradeToAndCall` | `0x55c51f1d4ea5f9941523d9ffd9717c13a9748976eaaedfb10a91dff02a83a0a1` (block 26086307) | `upgrade` gate 3/3 |
| snapshot s1 | — | first s1 read block 26086305, BEFORE the upgrade (snapshot block lag) — discarded; re-taken at 26086309 on the new impl: **0 differences vs s0** |
| swap batch (54 calls, 18 meta adapters; every instance set = pre-snapshot) | `0x0aad6aba8d718a8d5a102426aebe7f1c67140a0162c55efdef1ffb8b72d06ae1` | gas 6,297,714 (= rehearsal); BalancerV2 Pools/Gauges skipped (not configured on mainnet) |
| wallet-adds batch (16 adapters, 23 coordinates, all = config) | `0x6bac365065a9ba5ef98c18cb8c7e42dd1dff6b69ba3d42651455127b5572d38f` | gas 3,057,205 (= rehearsal) |
| `swap` gate | — | 150/150 |
| snapshot s2 | — | 130→130 positions, none lost/added; 87 now read by NEW adapters (23 reclassified: 19 Wallet→Staking, 4 Wallet→Supplied); NAV +$372.74 (+0.0003%) over 70 blocks; only decreases = Balancer V3 LP composition shifts ($1–$54 positions); 1 transient stale WBTC on a $0 Uniswap V3 Fees leg (BTC/USD feed mid-heartbeat), 0 flags on re-snapshot |
| `06` idempotence | — | nothing left |
| revoke ops Safe MANAGER | `0xe1fbb65cf7849529f6db805987726190c7c87fb9a639b2897f8a88dc16a93cf1` | ops Safe holds no role |
| Phase 3 heartbeats | `0xe5081f96e0070549f6e82396a3b7a2857b90f90cad1efb976eb54d244364daf1` | weETH monitor feed → 21600 s; `verify()` OK; backfill `NothingToDo` |

### 137 Polygon · 5042 Arc · 56 BSC — 2026-09-30 (Phase 2 + 3; no tracked accounts, so structural checks only)

| Chain | Upgrade tx | Swap (1 ops-Safe tx) | `swap` gate | Ops Safe revoke | Phase 3 |
|---|---|---|---|---|---|
| 137 Polygon | `0xc2084e02655a770135f9524d4ef5c0b8b742981e2feaeff4a3c15f86ff885ef8` | FluidFTokensMeta (3 calls) `0xdc6516049cef01766604613ed84aeb778b7a3d321fb25bfd1d6e80a277ad7097`, gas 543,177 (rehearsal 427,257: Polygon gas schedule differs from the fork's EVM; outcome gated) | 10/10 | `0xbe5be759e1a1b4f42f694d76410e91a0176181cc13f17a10cfb44be20e41c1b8` | aligned; `verify()` OK; backfill `NothingToDo` |
| 5042 Arc | `0xd2d47fb3e28de12765e10dbe62514f81c903bdd9d51071505cd0a8147ca272f2` | MorphoVaultsMeta (3 calls) `0xd58316b29d258436c5847ffcf0b3add4780a067c29449664104c251a48011a30`, gas 261,188 (= rehearsal) | 9/9 | `0xf3c6c3bfeade90b84b865d57a0f1f1a366fd2efb056e68be55f8199d7e431b9a` | aligned; `verify()` OK; backfill `NothingToDo` |
| 56 BSC | `0x8cccf7322e083eb0ba4fc195fed295d03b4e8834e5cddcaa08bf8f4216c4e1cd` | none — `plan()` = `NoMetaAdaptersToSwap(56)`; H9: no meta set on any adapter | — | no ops Safe | aligned; `verify()` OK |

All three: upgrade window 0 structural differences (s1 confirmed on the new impl).

## Upgrade-only chains — 2026-09-30 (01_2 + upgrade; no adapters, no swap)

Every chain: `phase1` gate 5/5 (incl. H9 before the upgrade), `upgrade` gate 4/4 (1967 slot on ≥2 RPCs + H9: no
registered adapter carries a meta set), upgrade window 0 structural differences (s1 confirmed on the new impl),
Phase 3 N/A (no asset config — only the native asset registered at initialize). HyperEVM ran with big blocks
switched on for the deployer, then off.

| Chain | Upgrade tx |
|---|---|
| 130 Unichain | `0x3d4e842c8d9f6b216cdaab043deb8a048343a1b7b9ea3aac9d65d8cc18206289` |
| 143 Monad | `0x099881fbcc3a2552245956576361f51c1ffbf1771dd211a467ebab19d6e9a060` |
| 146 Sonic | `0x6039e87ff6e2f1e43eddee6144743c52d727f6c6b92a19587c987560e857192d` |
| 196 XLayer | `0x808a3abd3a1cda706d3f1fda4657be3273f449b2575c4bd468c8f2de94f8a724` |
| 204 opBNB | `0xc8fa02411b1769aaa7934937fab5aaf9a4670d401a288eefb646000d8d5efcb4` |
| 480 Worldchain | `0xa45754e0fcc66a182f7f2e9545689348bed73cc113079ed352da4c99cb1acf77` |
| 999 HyperEVM | `0x2afe3605cbe90002a4cfb60ca1487e3c4515623c95f3440d2dd48cceba45508d` |
| 5000 Mantle | `0x7b329f72c0da030a2d7f9819bf1169c47367a31432d2162c2f64fd74f14957ae` |
| 9745 Plasma | `0xb4305ad08e33234ba5caf3fe9de88ad1c46bb4cbac823659a06b7895af032038` |
| 16661 0G | `0x5328a1946c88a5e0786e11ee5ec49137fecba6d71abfe9c525d1ad676efa4e32` |
| 42220 Celo | `0xc964c7eae046873a0e4a8e57d6397823fd342f1f7b238e746cd721195ea2c092` |
| 43111 Hemi | `0xa198656e39bf5b7d69c3a3272c23f0ad97b9c16a6a0ac4e214cfe80dd5712a92` |
| 43114 Avalanche | `0x00401b3c5f2b11aff0ce937c310dd6ee366057edc36ff4d926fd424f830bd390` |
| 57073 Ink | `0x4f86e91529112d8fec03cb92bf7d664b0c653620b17f277df9e0f3d12b3af65c` |
| 59144 Linea | `0x8baff2246283227cbca14f8a91f8955d7601da6362a541e6551281b00b4d8b0c` |
| 80094 Berachain | `0x400fb17e071e175cc4dfcb57c69faa83a10dfc66e15e3215b5d19836656c1f97` |
| 534352 Scroll | `0x1da7be3fe3046275d98d80be5f9c235b1e27a7241e6d51a27394b98a28e01714` |

Verification (2026-09-30): PriceFeedLib, NAVRegistryLib and the implementation are source-verified on all 17
upgrade-only chains — Etherscan V2 on 130, 143, 146, 204, 480, 999, 5000, 9745, 42220, 43114, 59144, 80094;
Sourcify on the five Etherscan V2 does not serve (196 XLayer, 16661 0G, 43111 Hemi, 57073 Ink, 534352 Scroll).
Every PR #338 contract on the 8 asset chains is verified on Etherscan, except Arbitrum (Sourcify; Arbiscan's
queue has held every submission "Pending").

Update 2026-10-01: Arbiscan processed its queue overnight — all 16 Arbitrum contracts now verified on Arbiscan too. Every PR #338 contract is verified on its chain's primary explorer on all 25 chains.

## Phase 4 — timelock handoff (prepared 2026-10-01; awaiting the Security Council)

On 24 chains (all but X Layer 196, held for the ops decision on its Council threshold, 2-of-8 today):
- deployer granted the Council Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` ADMIN + MANAGER (additive);
- `11` deployed the timelock `0xAB92EA75D07792915eB1f29259354866B880dFC2` (CREATE2, identical everywhere;
  minDelay 0, Council proposer + canceller, open executor) and wrote the handoff batch — committed in
  `script/deploy/pr338-handoff-batches/` (4 ordered calls: grant timelock ADMIN, grant timelock MANAGER,
  revoke deployer MANAGER, revoke deployer ADMIN);
- every batch equals independently rebuilt calldata, and was dry-run on a fork AS the Council: all calls
  execute, strict `roles` gate 11/11, timelock schedule → execute round trip OK (Berachain with
  `--log-chunk 1000`, Arc with `--log-chunk 10` from just before its grant — their RPCs can't serve long log ranges).

The deployer EOA keeps ADMIN + MANAGER on every chain until the Council executes its batch.

### Handoff route changed (2026-10-01, Nicolás): the DEPLOYER EOA does it, no Council signing round
Two passes, keeping the deployer until everything has landed:
- **Pass 1 — grant** the timelock ADMIN + MANAGER from the deployer (additive; each tx simulated first,
  confirmed before the next). Before each chain: the full deployer-sent sequence (both grants + both revokes)
  is dry-run on a fork and must pass the strict `roles` gate.
- **Pass 2 — revoke** the deployer's MANAGER then ADMIN, only once every chain is confirmed; then the strict
  `roles` gate per chain. The committed Council batches (`pr338-handoff-batches/`) are kept as a record, unused.

| Chain | Fork dry-run (full sequence) | Pass 1 grant ADMIN | Pass 1 grant MANAGER | Live census after |
|---|---|---|---|---|
| 130 Unichain | roles 11/11 | `0xea63b326c4bc7a9d28c2571e7b9ab2369aadbff781e3f1877b4ee0476e574366` | `0xf5d8118ced21ef2d2587a0a24b024ea602a78c242819c9190dc99a7fd78bab12` | exactly {timelock, Council, deployer, AssetKindRegistry} |
