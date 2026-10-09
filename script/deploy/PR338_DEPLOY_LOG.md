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

### Pass 1 complete — 2026-10-01: timelock granted ADMIN + MANAGER by the deployer on all 24 chains
Per chain: fork dry-run of the full deployer sequence (strict `roles` gate 11/11), then the two live grants
(simulated, confirmed), then a live census from the proxy's creation block = exactly {timelock, Council, deployer,
AssetKindRegistry}. Census via Etherscan logs on Arc, Berachain and Mantle (their RPCs can't serve the log range /
historical reads). The deployer still holds ADMIN + MANAGER everywhere — pass 2 (revoke) waits for the go.

| Chain | grant ADMIN → timelock | grant MANAGER → timelock |
|---|---|---|
| 1 | `0x425421d845483b74f1e056d3582a0f6bc132b5619f8b07393ef2aeb8d204d180` | `0x3a10b01112009449c3f08198d3bc9aaf38afab584cefdaabfd90fb88ee786270` |
| 10 | `0xb1ce687ff535c9a50f6adea7019c061a7f4652172b898bc0f9a312d554f07a91` | `0x6aa6ee74bef993daccf33467952471f8adef9bb9155f9435eed3512c63e98799` |
| 56 | `0x0ac1d5c0212a3c6ea1d84c1e9c46bc3f02c8137a8dc639a9418d233c7c293c5f` | `0x4158e813b414269fd228b7df5dfea434fa793330e2f396f15b6a1695e46a6317` |
| 100 | `0x83f99d847dad186a157ad3b80850d5db38a5fa25d39950b5e325279a45913fa4` | `0x44a7f63834b81f972ae314d00012afdfe6171afe76b126faccec53fc621be7c4` |
| 130 | `0xea63b326c4bc7a9d28c2571e7b9ab2369aadbff781e3f1877b4ee0476e574366` | `0xf5d8118ced21ef2d2587a0a24b024ea602a78c242819c9190dc99a7fd78bab12` |
| 137 | `0xd0261fa8c37ee659c81e75e208db084ad2c3032974b431e47cddaaecc7c01ea6` | `0x2dc56a010076509625f998aab470f2b803a25287e7bffcebe2526fd8d815aef6` |
| 143 | `0x1e275fb5207bbf77b817a8b07af49e35ebe8cf5a7affb4b8bba9f243a254ed54` | `0x7da234b979633143d9d9a7f2548cc2eaedfed1af7f0a2f3ffee69536b878bc0b` |
| 146 | `0x9769f42cf694e542ba0dc2e8bd0377afebebd85bf42661f7baa2f482ddc68365` | `0xcb67266a39290b7a115e2a62028398a469a2c2a50b3d218c01edf6c999f97e2c` |
| 204 | `0xa732e272d411611cd8ced749e55e95b5e20038d2ea574584462b7cc91ce5c462` | `0x823ccaaf88580d34da85310e8d0d1fe08e27b757a9d20e4aa8bd1128c26955bb` |
| 480 | `0xe32b181d30950e7b608dda3411edfb83b81ae6ce5cfcc443bcffbf62e327e5a3` | `0x417009ef31d977be5628f18050bb20fa85c47afad23493e6ce7e83f35f79747e` |
| 999 | `0x7684ff924f2231f1fd92bb552e07d369a9be3e8d42843d13e9c4826025a210ac` | `0x9d8a9129be654c4cd2b8d68cb8d874eae9e061fd2fb70b0748e8c3248b671fd7` |
| 5000 | `0xdfbdbf8ccde0cc45793bcb19dad50c1a28e54353bac9171a31359472d0e4f95e` | `0x76a0435bd7a5163b5c38e18864bebf6fa1ef46e8040c3e2bd3f2bd2fcb4c86b7` |
| 5042 | `0xff46044d46c82c04c32592a298dd99cc901f6ece3f1a5dfa309f0bd5c044023c` | `0x3b156ba81362c217b2e7c689f07821eb0dfc76eeb08f6e6efa85b911592f284e` |
| 8453 | `0xb8b27556332e784340d1894c43e40e98153284a185da155a3b595ef56831db82` | `0x7e3de33a21ffadb052238c7e23d55f43882a90aa3d9cd7d072bbd8db0c2df711` |
| 9745 | `0x40e8ede070dc4acd66aa804c66d5b12ae2610e112cc45f5edb6617da0bd4da57` | `0x70c44ca50569ee9532e78c681595ff83b5d26ef3f8bbba116431beb836cb2f7b` |
| 16661 | `0xed478210dba1692bd0c41fc2046f767f71fc5bb63f8a8fd40fcf7795a3ffd36a` | `0xbd5a5333625202e664dd02d8404b6f65f64b859d9f445758691db4327b3c4254` |
| 42161 | `0x8d74fe10fd70025da8bee6bdbb555192e288b0810e6d4974134a67e80db31517` | `0x0a9e90958e6402c8e7249bd81226b407228f4974af63da367547793fb5b7f989` |
| 42220 | `0xcb10ebe390635be75def7e67d2b8ea960f5196adf213529fe823c99201a7f943` | `0xcd61762cc415801a8697f824818226e8c648c868821a2832fd6215958fa205e3` |
| 43111 | `0x1eaf53868b9385789c755746de5e55752fbec3920746564037ae8ac862a3f7b8 (same-nonce replacement of an underpriced first send)` | `0x472d7cc2577b6da4b89d89757ccdbea5e762572500f9b77e3065660a153b4acb` |
| 43114 | `0x3197433892fba3025168b25bb680f60e43050dc5a324669c1b1f0447f08b8240` | `0x99450ef361a8dbd79a04c45a3fb0bd0d0ed94dcb68f006b456059dc48297c85e` |
| 57073 | `0xbede12940c7c65253256d9507d6843d5e0c7c40ca30df35377c4a7e2c1e29408` | `0xc278f30b1a59150d224edf7620b342b1e982505159264d4ccaeadf17172dc77b` |
| 59144 | `0xc56f437defe222150e9b0941d982376f8434db71196dbb1a53ee903d473e6726` | `0x26187b22ed79b5a9e7d5543ea3609a4f06a84f085af7787ada4470b99d0262d4` |
| 80094 | `0x37291d0c2b0928953366424fe607295a423c53ffc72f34f1ffa0745cc5865a35` | `0x2c4963eb0ce0b4b23109126a1186857c30b0a8ef83c0ce7fae338f1b62aa6580` |
| 534352 | `0xed675140d2f498a86934cc8f0120daeb0be8ccb0930de2d00762086bfc4eac99` | `0x6e708c034c9052739810d94376db87bb5bccca2507f36081e427ab1a67bf6a33` |

## Full audit — 2026-10-01 (read-only, before pass 2)

- **All 25 chains** (part 1): 1967 impl slot = `0xA7243DCD…` on every endpoint (≥2 per chain; Arc 1); implementation,
  PriceFeedLib, NAVRegistryLib and timelock bytecode identical fleet-wide; NAV role census from the proxy's
  creation block exact on every chain ({timelock, Council, deployer, AssetKindRegistry}; X Layer {deployer,
  AssetKindRegistry}); AssetKindRegistry holds no ADMIN; ops Safe holds no NAV role and is still 1/1 deployer;
  the timelock's own roles exact (admin = itself, proposer + canceller = Council, executor = open, minDelay 0,
  nothing else ever granted); Council Safe 5-of-8 everywhere except X Layer (2-of-8); no pending deployer tx.
- **8 asset chains** (part 2): `swap` gates all pass (ETH 150/150 …); RealignHeartbeats `verify()` OK; `06` has
  nothing left; fresh snapshots 0 errors / 0 health flags. Diff vs the pre-migration baseline: only the intended
  changes (Council roles; ETH weETH monitor heartbeat 86400 → 21600) plus ~2 days of market/account activity.
  stETH reclassified Wallet → Staking (Lido) with amounts up only by rebase; ACCOUNT_11's rETH left the account
  on-chain (balance 0); the RocketPool wallet adapter was spot-checked to report a holder's exact rETH balance.
- **Verification**: 169 contracts (libs, impl, timelock, every adapter 04 created) — all verified on the chain's
  explorer; Arbitrum's timelock was verified on Sourcify, then manually on Arbiscan (2026-10-01) after its API queue stalled — all 169 now verified on their primary explorers (see "Explorer coverage — 2026-10-06" for every other explorer).
- **Records/CI**: `DEPLOYED_ADDRESSES.md` now lists the timelock; the address guard additionally checks every
  canonical-layer contract is one address fleet-wide and published (`526e4d4d`); CI 11/11 green.

## Explorer coverage — 2026-10-06 (source verification only, no transactions)

The 2026-10-01 audit checked each contract on its chain's primary explorer. This pass covers every explorer that
supports each chain. It follows the team's `verify-contracts` skill. 176 rows: the 169 PR #338 contracts plus 7
ops-Safe proxies.

| Backend | Before | After | Not covered |
|---|---|---|---|
| Etherscan V2 (and its "…scan" sites) | 157 | 157 | 19 rows on chains not on V2 (196, 16661, 43111, 57073, 534352) |
| Sourcify v2 | 53 | **176/176** | — |
| Routescan | 55 | 55 | supports only 1, 5000, 9745, 43111, 43114 (all verified) |
| Blockscout | 24 | **78** | Cloudflare-challenged instances (polygon, base, arbitrum `.blockscout.com`, explorer.arc.io), unreachable explorer.hemi.xyz, chains with no instance |
| 0G chainscan (16661) | 0/4 | **4/4** | — |
| OKLink | — | **137/137 supported** | chains it doesn't support (130, 143, 146, 480, 5000, 16661, 43111, 80094) |
| Tenderly (public, org project) | 0 | **153/153 supported** | chains it doesn't support (204, 999, 16661, 43111) |

Every row is verified on at least 2 backends, and most on 4 or more. No Etherscan submission was needed.

## Robinhood (chain 4663) — not part of the 25; pending (2026-10-06)

Robinhood also runs the NAV proxy `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214`. It still runs the pre-#338
implementation `0x40e4134849308d53F85A8B685324E2189b13ff7D`, and the deployer EOA is its only admin and manager.
It is an asset chain: 27 assets, plus three meta-adapters from the separate `kpk-labs/APE-robinhood` kit
(UniswapV3/V4/Fables Sickle adapters, which have no owner). It prices the kRHUSD, kRHETH and kRHSPY vaults.

Decided by the fund owners: no timelock on Robinhood for now. NAV admin and manager go to the Safe
`0x2F0d561B9a8CD981e6E73069592BDeA4e48A8bec` (2-of-5), and the deployer is removed last.

The fork rehearsal passed (block 81,739,680):
- The three `01_2` CREATE2 transactions, replayed with byte-identical calldata, reproduce mainnet's code hashes.
- The upgrade leaves the adapters, assets, meta sets and all three vaults' NAV and positions identical.
- The Safe grant and the deployer revoke leave holders = {Safe, AssetKindRegistry (MANAGER)}.
- The Safe can remove and re-add an instance on each APE adapter with no change to NAV or positions.

No source change is needed: the live run replays the recorded transactions.

## Robinhood (4663) — upgraded and handed to its Safe (2026-10-06 → 2026-10-08)

Not one of the 25. No timelock, by decision of the fund owners: NAV `DEFAULT_ADMIN_ROLE` + `MANAGER` go to the Robinhood Safe `0x2F0d561B9a8CD981e6E73069592BDeA4e48A8bec` (2-of-5). The three `01_2` CREATE2 transactions were replayed byte-identical from chain 130's broadcast (code hashes == mainnet).

| Step | Tx |
|---|---|
| CREATE2 PriceFeedLib | `0x94d2badda077dc60c93617586e9b28c0c5c5d524920c12144729b0a9222da39a` |
| CREATE2 NAVRegistryLib | `0x7adf93bbe200068f04993ad02718f6cba61a7cba5fbb95648bc159556ce3c8f9` |
| CREATE2 NAVCalculator | `0x70f9b92e1e8d16a478c3ab8ae9dc823d93bf4246fad7faf63f0d05f243fef3a8` |
| upgradeToAndCall | `0x2089ff8621b0fa436d52201b1dd3079bb899cc6d1a1a4be1f70398323d4c0c6a` |
| grant ADMIN -> Safe | `0x494480974b5d7c731aff415c03811479e98a5151df2166d8678fe79d02cf980c` |
| grant MANAGER -> Safe | `0x7a6e2ff64fae75badeddb40ead2ad5bbce78e540a581e7bddcf0fc36be7ba5ad` |
| Robinhood Safe revokes the deployer's MANAGER + ADMIN (one Safe tx, 2026-10-08 13:19Z, block 83,343,871) | `0xf97a6878199cd79c1f0da2b96ab51b15f12c62c86d4be73d4fabcf9e3c1b846d` |

Role census from block 0 (Etherscan V2 logs): ADMIN = {Safe}; MANAGER = {Safe, AssetKindRegistry}. The deployer holds nothing. The proxy's setup contract `0x03ee5dad…9a0c` renounced its admin at creation. Verified on Sourcify, Etherscan (robin.etherscan.io), OKLink, Tenderly and Blockscout (partial match = the maximum, `bytecode_hash = "none"`).

## X Layer (196) — full Phase 4 in one run (2026-10-09)

The Council Safe was raised to 5-of-8 first (nonce 1). The timelock was deployed by replaying chain 130's recorded `11` CREATE2 transaction byte-identical (code hash == mainnet; `minDelay` 0, Council proposer + canceller, open executor, self-administered). Verified on Sourcify, OKLink and Tenderly (Etherscan V2, Blockscout and Routescan do not serve 196).

| Step | Tx |
|---|---|
| grant ADMIN -> Council | `0xdcd54eb8c38fcd1466fa6373832298e121a31d1f2063afa606cafc31b36c0661` |
| grant MANAGER -> Council | `0x6f593cf070bef6f7db5965eed70a7f0331e3578b83843c1f8eaf3573b7aec6d6` |
| CREATE2 TimelockController | `0x8f2891eab4e749b592cba9d8b4758fe16d12bda72dd858ff29d7801d5f0ec440` |
| grant ADMIN -> timelock | `0xe57e675108553b6f59c951b7e518bc03de4953887a8ecdc6bd6b8f95441a041f` |
| grant MANAGER -> timelock | `0xea05b59b59b4cb00853319658b694d9235f7189861a7e5cfeb5584346d301708` |
| NAV revoke MANAGER (deployer) | `0x2eafa612e34f9c8f44dbeedea0f5243c97ba706efed7b1f2250fae291418fc2e` |
| NAV revoke ADMIN (deployer) | `0x7eda390bd957b930a1003fcedd68d52eb86f51122a3a57fc4d222e98b71dfaad` |

Roles gate `roles 196 --council-retains`: 12 pass, 0 fail.

## Pass 2 — the deployer removes itself (2026-10-09)

Per chain, from the deployer: `revokeRole(MANAGER, deployer)` then `revokeRole(DEFAULT_ADMIN_ROLE, deployer)`, each simulated first, then the strict gate `pr338_check.py roles <cid> --council-retains` (holders = {timelock, Council} + AssetKindRegistry MANAGER). Unichain was the canary, reviewed by Fable before the rest; Ethereum last. On the 7 Merkl chains, the Merkl adapter `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` admin went to the Council first (`grantRole` then the deployer's `renounceRole`).

| Chain | Merkl: grant Council | Merkl: deployer renounces | NAV: revoke MANAGER | NAV: revoke ADMIN |
|---|---|---|---|---|
| 130 Unichain | — | — | `0x1bab8f18d67cf8e61206cc1acdaaaf903c80ece8117b5d6c4c3e4e924d3d1b2e` | `0x9c5b0a45848e25c4cf025a6e3b6eb08007d8c73938f0f255062ecac48f31c942` |
| 143 Monad | — | — | `0xc4443c0d87f48487d7ba9c3f78634c659cc9a5531f29fe340ca424fe6c30a304` | `0x0af0d1160ea22077c62fb5fb57c52afd92f7a7b68cd4327d804560d855c2c561` |
| 146 Sonic | — | — | `0xcad70a03ce78304de67bda3f792c9f1d2c16b5c768790389e7622a1fed1493c6` | `0x44ec54c3ac69c1411fa7e352c3c81dd0b50de63e1ca46970c97457a53b7ddb4a` |
| 204 opBNB | — | — | `0xef983e41e9d8e58f3dd818fd4651423b5cef4542fa640473aa7f71f7a5f7b366` | `0xdbad4f23f61a014e5f52be6286640b3ab3e1784d20e358b8b72bea4c7c0d4eae` |
| 480 World Chain | — | — | `0x4555c4b1efd87a919d2ebdd3d5dba884e262bdd8e1a5527f4193faf3ecfdfb91` | `0xfee7437bc1fed01e4327ea6ce030644fb4ac4e472c71d17756cf88d628cf3fdc` |
| 999 HyperEVM | — | — | `0xe6fcc59c2be802ee67d04063d53ff4b43d7ed55cc66c95298547be1fd6f60147` | `0x649a24b34599ba7c840912e8af03027bd1653c505811142dc72b644996370dfd` |
| 5000 Mantle | — | — | `0xc845b878b4b85f00d0289fad9ae7c065a1e6620f57039e4c2d58a6d709635c5c` | `0x8267176c74535f717d6ad888019659dbf0d4484e2d300659f3c5990c39b8fd8c` |
| 9745 Plasma | — | — | `0x3733aa73983160560efdeaebc912c033233274f3f3a9494727f3682eeff2bdeb` | `0x68480f9df58e1a4e797e20d31b5dfac1465055255cbb249a62ea5639958c2556` |
| 16661 0G | — | — | `0xb23158aa2e12315bf778ab4e83a3f1c8fb5c61408769d99814b1ba1bbae2f30e` | `0x78cc5da880f7bc1433409dc7a56fb99289b82dd99705a3545468fc40e0900623` |
| 42220 Celo | — | — | `0xf200ee94aeee80a352c098169a915703140081fcd3c7b1855fea3f94ceb9ac91` | `0x9621307e1cc88a97835fbc00f49f91e5d5eaa31fef0a29a8effb807406f98502` |
| 43111 Hemi | — | — | `0xa2bb7fa935d5ef4722b5d96f755b501194d21a8faf2563c72df9531f6a8b8e6f` | `0x42c26fd4aba6326ed204d67c9ba9bf258764687ea81a3341595838b3b1b957bc` |
| 43114 Avalanche | — | — | `0x5da3442e957d6f2e0689615a03226d530c07381bfa9d02f8037ebdd7b2c1d475` | `0x01e207b8f4b474c13fd6db59ba21e50c9284bbc0cbdc6864c6a6991045105def` |
| 57073 Ink | — | — | `0x880c4074ba65cf3afd49728c72408e96d0d67385b286675a8c940cb762af0b62` | `0x5ce8327f8c69bcaaf4ed005111f9cfbca8454c4fb278dc4913a6527442758d51` |
| 59144 Linea | — | — | `0x4750a366e27284ef99e894ff657ac855e88e67738c3877e236bbda6461f2a3b5` | `0x9c1cc46b1544b57d93049bf02abd416c0b1dcbd03137bd8b237e1fe4c310a4ae` |
| 80094 Berachain | — | — | `0xb5e492d478d36c2988a004e6c0383c61ce445af5a1e4364620ea5981d77547b0` | `0x626837bc8b2a05dc9046bc95ecb3f0da58b33b6040a49ba58221dad3cfa1b5c1` |
| 534352 Scroll | — | — | `0x0ebe27646504ee8ac371a26d5ce5b96b17bdc48386fb8060bd28805e329e727c` | `0x08fe207458565cc878c4296575edef9cd0e1fe98e8557daad389bdbf43228469` |
| 56 BSC | `0xb3839d3c9fed00f5542a41724a3387eb77b2a5d28b2c38c5e909b9978dd4e07a` | `0x9e316fd1e3c4f4d3ffb2efa64180d5702bfa0eb54f0b4b0197b2a42cc06a424e` | `0xa8cf4e7a78c9a5e7836339b3dbb5c62d6817c633a837f2b84c9a653018f267d3` | `0x20e58f72e3e8519b120c95582b91d602244baeefad390ec3e8f3708bae26d456` |
| 137 Polygon | `0x9a9b990ca471621c60b2e511db5f8ee7a3a9981afc466d9619ac2ee666b3fe55` | `0xd3818a10c0f0fc216e5e97cc9b15d7a5317bc39c7604d87b92f2b7d414e3d707` | `0xb3460ca789e633ecd33705ceba038fd9b02f3a0f4ccef244f7f893ea1023c4a2` | `0x809a963e3022babe836e72158253900528bc8e784f0d4af14a34a2d489db8719` |
| 100 Gnosis | `0x1d7ae32d8e77191061f4364fb52597df4fda3672afd0b8521c2c79a041daff84` | `0x4cce088b1f4d46406ca60811616b2fb54cc73a0f9b801b6b50221dd8b0f2dcef` | `0xd52157bc7bf854b4da9a4adb339c8082d94b652abd8e60a428c0388196ddbd5b` | `0xf15c05ca8042c83f1e1d7b15378d78b927c6de83534cb912174a203f26a9e298` |
| 10 Optimism | `0x1103b9069cb2bebaa7663505ad7fc4972a194b8989295ea900ecfe3f7931642a` | `0x2c1410726bbe764235215a2218a856023387cb29281ef2330c200660bd224bd3` | `0x5e6de824080af29254a442b0131cc522976c15de7f8d87b7d3046ae76fa1c149` | `0x7b0178cb76f3d150bcb6ae133e73e687981850b85c3aa6b269f59ed77e52336e` |
| 8453 Base | `0xa38a478d151542eb706e11b50ec7027919f95f2e6bb11b607c018cdbad0213a5` | `0xf47e817f80d3b493c9f9816a9882aedbd1cb594749895ea32e9cd793f46df41a` | `0x6bc8473c4e6c1bd2da46faa830a0d7e5f8c8612aae05999a735ad8f79b1ec5ca` | `0x05c223930f8e116120a26f7cc0f443111c3831fd8020256dcde6c5fdc9a0c401` |
| 42161 Arbitrum | `0x7b17a8179089e48619f88dc5b70e6351a3dda4b7d10e3e5316f96c02349f2d79` | `0xb11e408ecb93d35d9dc8af45aac63a77bfdf018c29c9a482348f99452d0126ac` | `0x362e3193e0f7da8d70a18041290e6a9406798a99e0edca0d7cbe934c56e4f62e` | `0xae01433b9b73658a4fad5ad1a5a222baa95c2523edb90017cfd21c120c52bfb8` |
| 5042 Arc | — | — | `0xaa26755f675bb2ae9c5a625e0e23b67c318e1715461d3eec88d2c472ee3fccda` | `0x8df21266074fdab63f173f8d752b2031794d318c1a4b3f31d9f8d435c196b370` |
| 1 Ethereum | pending | pending | in progress at commit time | in progress at commit time |

**At the time of this commit** pass 2 was still running on 1 Ethereum (Ethereum last, by design). Their transaction hashes are recorded in a follow-up records-only PR.

Every completed chain's gate passed 12/12 (Arc's slow log census was still running at commit time; its direct `hasRole` checks confirmed the deployer holds nothing and the timelock + Council hold both roles), except Mantle (5000), where the gate's log census hit Mantle's historical-RPC DNS failure; its census was rebuilt from Etherscan V2 logs and nets to exactly {Council, timelock} ADMIN and {Council, timelock, AssetKindRegistry} MANAGER. Once pass 2 completes, the deployer EOA holds no role on the NAV on any of the 25 chains, nor on the Merkl adapter.

