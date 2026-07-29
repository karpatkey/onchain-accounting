# NAV stack — from-scratch redeploy runbook

Ordered, per-chain command sequence for the full redeploy of the NAV stack onto a **new proxy**, with
the precondition and post-condition of every step. Written 2026-07-27, revised 2026-07-29 against
`main` @ `dc5810eb` — the hardening wave is complete and a short merge train still runs ahead of the
two-library pin regen (0.1, 0.3).

Companion tooling lives in [`preflight/`](preflight/README.md). Everything there is read-only except
`rehearse_fork.sh`, which only ever broadcasts to a loopback anvil.

- **Scope:** exactly the **24 chains** that already have a `NAVCalculatorProxy`. Chain **1101**
  (Polygon zkEVM) is excluded — its deployment record is empty, so it was never deployed.
- **Bridge is deferred.** `src/bridge/` was untouched by the wave and holds no NAV reference.
- **Step 07 (admin handoff) is NOT part of this deploy.** The deployer EOA keeps
  `DEFAULT_ADMIN_ROLE` + `MANAGER` on every chain afterwards.

| chains | what they get |
| --- | --- |
| all 24 | 2 libraries + NAV impl + **new** proxy + ERC20Default (minted by `initialize`) |
| 1, 10, 56, 100, 137, 8453, 42161 | + custom price feeds, balance adapters, assistants, full NAV config |
| the other 17 | ERC20Default only |

Configured totals, reconciled from config **and** confirmed against the live NAV on 2026-07-27:
**33 meta adapters, 110 meta instances, 12 plain adapters, 39 custom price feeds, 93 assets.**

| chain | meta adapters | meta instances | plain | feeds | assets |
| --- | --- | --- | --- | --- | --- |
| 1 mainnet | 15 | 66 | 11 | 24 | 43 |
| 42161 arbitrum | 7 | 16 | 0 | 8 | 11 |
| 8453 base | 6 | 16 | 0 | 4 | 11 |
| 10 optimism | 2 | 4 | 0 | 0 | 6 |
| 100 gnosis | 2 | 4 | 1 | 3 | 11 |
| 137 polygon | 1 | 4 | 0 | 0 | 5 |
| 56 bsc | 0 | 0 | 0 | 0 | 6 |

("plain" excludes `ERC20Default`, which every chain gets automatically. Chain 56's only meta adapter,
`PancakeSwapV2PoolsMeta`, is `enabled: false` in nav-config, so BSC registers `ERC20Default` only.)

---

## 0. Blocking prerequisites

Do not start until **all** of these hold.

### 0.1 The hardening wave — landed; a short merge train still runs ahead of 0.3

| landed | what it was |
| --- | --- |
| #175, #179 | malformed-`positionId` guards |
| #176 | StakeWise label leaf |
| #177 | cross-adapter enumeration tripwire |
| #178 | adapter gas caps (`PriceFeedLib._getAdapterPositions`, `NAVCalculator._safeStringArray`, the caller-side `registerAsset` codesize guard) |
| #181, #183 | `foundry.lock` drift + its CI guard (see 0.4) |
| #182 | meta-instance gas starvation |
| #186 | per-leaf gas bound on `positionLabels` |
| #189 | Morpho existence invariant + a tighter `protocolName` ceiling |
| #190 | enough runner memory for the `via_ir` build (see 0.8) |
| #191 | the library-pin assertions in `01` (see 1.2) |
| #187 | paginated NAV read over a caller-supplied adapter set |

`main` is at **`89274d50`**. What still has to land, **in this order**, before 0.3 can be computed:

| open | relationship to the pin regen |
| --- | --- |
| the O(1) registry-getter PR (`_getAssetInfo`, not yet opened) | its effect on each pin must be **measured, not predicted** — see below |
| **#185, the regen itself (0.3)** | must be computed last, against the final tree |

**Both pinned values will be regenerated, but for two independent reasons — do not attribute either to
the other.**

- **`PriceFeedLib` moved because #187 edited `src/prices/PriceFeedLib.sol` directly.**
- **`NAVRegistryLib` was already drifted on `main`** before #187 existed, independently of anything in
  flight. Measured across four trees — `main` before #187, and #187 at `66490d6a`, `94dc81be` and
  `0d68fcf4` — its computed value was `0x7Fc30f7a1A3b89040f1CA74CbE71814B4A4dAF04` at **every** one.
  #187 did not move it. (That figure is cited as evidence of *invariance across four trees*, not as a
  value to pin: it is a CI reading, and per 0.3 those are not a reliable source for the pin itself.)

This matters because both `LibraryPinConsistency` tests are red simultaneously, which invites the
conclusion that one in-flight PR moved both. It did not. An earlier revision of this section asserted
that `INAVCalculator.sol` sits in both libraries' compilation closure and therefore any PR touching it
moves both pins; #187 touched that file and `NAVRegistryLib` did not move, so **that reasoning is
wrong and has been removed**. Do not predict a pin movement from the import graph — measure it.

### 0.2 Bump `DeploySalts.NAV_PROXY` — **CONFIRMED REQUIRED, already done (6 → 7)**

The NAV proxy address is
`CREATE2(0x4e59…4956C, keccak256("NAVCalculatorProxy" ++ DeploySalts.NAV_PROXY), UUPSProxy.creationCode ++ abi.encode(placeholder, ""))`.
Its creation code carries **no per-chain and no per-implementation data**, so a new NAV implementation
does **not** move it — unlike the libraries and the impl, whose addresses change automatically because
their bytecode changed.

**Measured on a mainnet fork, 2026-07-27.** With `NAV_PROXY = 6`, `02_2` computed
`0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` — the live proxy — so `AtomicNAVProxyDeployer` found
code already there, skipped the deploy (`AtomicNAVProxyDeployer.sol:43`), and reverted on
`upgradeToAndCall` holding no admin role:

```
Placeholder impl (same on all chains): 0x85Ee38b0385D042918a59C01dB319b6eDdF7A8Cf
  NAVCalculator proxy: 0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d
[ATOMIC] Deploying placeholder + NAV proxy + upgrade in a single transaction
Error: script failed: NotAuthorized()
```

That would happen on **every chain**. The address did *not* drift on its own because
`UUPSPlaceholder`'s bytecode is unchanged — it still lands at `0x85Ee38b0…`, matching
`DEPLOYED_ADDRESSES.md`. **`NAV_PROXY` is therefore bumped to `7` on this branch.** Re-confirm with
the rehearsal after any further source change, since the placeholder's bytecode *can* shift under
`via_ir` with no source change (the `NAVRegistryLib` precedent):

```bash
script/deploy/preflight/rehearse_fork.sh 1        # asserts the proxy address differs from live
```

> **The rehearsal treats the config tree as disposable, and you must let it.** It forks as the *real*
> chain id (ConfigReader keys every path off it), so the deploy scripts rewrite
> `script/config/deployments/<id>.json` wholesale — impl, proxy, every feed, every adapter including
> `ERC20Default` — with **anvil** addresses, and forge writes `broadcast/<script>/1/run-latest.json`,
> indistinguishable from a genuine mainnet broadcast (`.gitignore` only excludes
> `/broadcast/*/31337/`, and `script/verify/sweeps/make_targets.py` enumerates deployed price feeds
> from exactly those files, so a leftover would feed fork addresses into a verification sweep).
>
> `deployments/<id>.json` is the only record of what production runs and the baseline every audit
> diffs against, so `rehearse_fork.sh`: (a) **refuses to start** unless `script/config` and
> `broadcast` are git-clean, (b) restores both on exit with `git checkout --` + `git clean -fd`
> — byte-exact, whatever the run did — and (c) asserts they are clean again, keeping the run's own
> output under `/tmp/nav-rehearsal-<id>/config-after/`. Never blanket-delete `broadcast/`: it also
> holds committed records from the real PR #141 migrations (`MigrateAssistedAdapters`,
> `MigrateGnosisStakeWiseExit`, `RemoveMerkl`).

If the rehearsal's `NAV proxy address differs from the live one` assertion **fails**, bump
`DeploySalts.NAV_PROXY` again and re-run. The bump must land **before** 0.3 — `DeploySalts.sol` is in
the full-project `via_ir` compile scope, so it can move the `PriceFeedLib` pin, and any pin computed
before the bump is stale on arrival.

### 0.3 Regenerate BOTH library pins — last, in its own commit

Own PR, own commit, computed against the **final merged tree** — which already includes the
`DeploySalts.NAV_PROXY` bump from 0.2 (merged in #180 ahead of the regen for this reason). Never in the same commit as a source change — that is exactly how `6b7e4851` wrote a
stale-from-birth pin.

This is a hard gate, not a nicety: `01_2` asserts the computed CREATE2 addresses equal
`LibraryPins.PRICE_FEED_LIB` / `LibraryPins.NAV_REGISTRY_LIB` and that the impl bytecode is linked
against both (`01_2_DeployNAVImplementation.s.sol:46-68`). A wrong pin reverts `01_2` on every chain
before it broadcasts anything.

Iterate to a fixpoint; a 2-cycle has been observed. Always `forge clean` first — an incremental `out/`
yields a wrong address that looks authoritative.

> **A CI reading is NOT a reliable measurement of a pin value.** Two runs of the same branch 25
> minutes apart, with a one-markdown-file diff and **zero `.sol` changed**, produced two different
> computed `PriceFeedLib` addresses (`0x00a3AFAC…` and `0xD477d7e2…`), both runs' `headSha` confirmed
> via the API. Cause not yet settled — `via_ir` non-determinism or a CI cache effect; the regen
> session is running back-to-back local clean builds to pin it down. Until that is resolved, **the
> regen's own local clean-build measurement is the only source this runbook or `LibraryPins.sol`
> should take a value from.** No pin address is quoted anywhere in this runbook as authoritative for
> that reason. See `reference_pricefeedlib_pin_drift` for the full history.

### 0.4 Submodules at the recorded commits — **root cause fixed, keep the check**

This was a live hazard during deploy prep and is now resolved. The history is worth keeping because
the failure was silent and would have invalidated every measurement taken against it.

**What went wrong:** a fresh worktree has an empty `lib/`, so `forge build` runs `forge install`. The
committed `foundry.lock` was **malformed JSON** (a trailing comma), so forge discarded it
(`Warning: Failed to parse foundry.lock`) and resolved to remote tips instead — observed moving
`openzeppelin-contracts-upgradeable` from `1334fc17` to `heads/master` and `forge-std` from
`887e8725` to `6e8c4a92`, among others. OZ-upgradeable is in `NAVCalculator`'s inheritance chain, so
that silently changes compiled bytecode and would poison both the library pins and the bytecode audit.
Worse, the lock's revisions also **disagreed with the gitlinks for 5 of 9** submodules, so repairing
only the comma would have made forge honour a lock that installs the *wrong* set.

**Fixed by #181 + #183:** the lock was regenerated from the gitlinks, and CI now asserts they stay in
agreement (`script/ci/check-foundry-lock.sh`, wired into `.github/workflows/foundry.yml`). Verified on
`2077c82e`: the lock parses, has 9 entries, and matches all 9 gitlinks.

Still run the check before building — it is two seconds and it is the thing that goes wrong:

```bash
git submodule update --init --recursive --force
git submodule status | grep -v '^ ' && echo "DRIFT — fix before building" || echo "submodules OK"
```

### 0.5 RPC endpoints for all 24 chains

The Alchemy app behind `ALCHEMY_API_KEY` has most networks **disabled**; only
`eth / opt / gnosis / base / arb` answer. `ConfigReader` resolves 22 of the 24 chains through
`$ALCHEMY` alone (`ConfigReader.sol:759`), so a bare `forge script` **cannot reach 19 of them**,
including **polygon (137), a configured chain**.

Either enable the networks on the Alchemy app, or pass `--rpc-url` explicitly per chain from the
per-chain `*_URL` vars. Confirm the full inventory first:

```bash
python3 script/deploy/preflight/deployer_balances.py      # prints the endpoint each chain resolves to
```

Chains with no `*_URL` and no Alchemy access — `143 monad`, `196 xlayer`, `204 opbnb`, `16661 0g`,
`43111 hemi` — currently fall back to public RPCs. Public endpoints are fine for reads but should be
replaced with real ones before broadcasting.

### 0.6 Fund the deployer

```bash
python3 script/deploy/preflight/deployer_balances.py --json topup.json
```

Re-measured **2026-07-29, after the linea top-up landed**: every priced chain is funded, linea
included (0.03066 ETH against an estimated 0.02800). Re-check on the day — linea had already been
topped up once on 2026-07-27 without clearing, so measure rather than assume.

**Some chains report `UNPRICEABLE`, which is a third state and not a pass.** Gnosis, scroll and
intermittently plasma quote an `eth_gasPrice` far below any usable price (gnosis ~5–10k wei, scroll
~120k), so `need` computes to roughly zero and `balance >= need` is true for *any* balance. The test
is a tautology and its `True` means nothing, so the script reports `sufficient = None`, lists those
chains under `NOT PRICED`, and exits non-zero. The estimate is deliberately **not** inflated to
compensate: a floor generous enough to cover gnosis over-states the cheap rollups by three to four
orders of magnitude, and a 1 gwei floor was measured reporting `TOP UP` on 11 of 24 amply-funded
chains. Funding on those chains has been confirmed sufficient out of band; the state exists so nobody
later reads a green row as evidence the chain was checked. Hemi's fee floor (1.8) is the same species
with a known workaround.

### 0.7 Capture the pre-deploy production state — **irreplaceable, do it before anything else**

```bash
python3 script/deploy/preflight/snapshot_production.py --out pre
```

This is the only chance: the old NAV is abandoned in place, and without the snapshot "does the new
stack reproduce the old one?" becomes unanswerable. The `pre/` capture from 2026-07-27 is committed;
refresh it if the deploy happens materially later.

### 0.8 Green build and tests

```bash
forge clean && forge build --sizes
forge test                                   # both LibraryPinConsistency tests must pass
python3 script/deploy/preflight/bytecode_audit.py --self-test
```

---

## 1. Per-chain deploy sequence

**THE AUTHORITATIVE ORDER:**

```
1.1  clear the deployment record
1.2  01_2_DeployNAVImplementation     libraries + NAV impl        PERSIST_DEPLOYMENTS=1
1.3  02_2_DeployNAVProxy              new proxy + ERC20Default    PERSIST_DEPLOYMENTS=1
1.4  03_DeployPriceFeeds              39 custom feeds             <- BEFORE RegisterAssets
1.5  RegisterAssets                   assets + feeds on the NAV
1.6  04_DeployBalanceAdapters         adapters + assistants
1.7  06_Configure                     register + reconcile
```

This **differs from the original plan**, which had `RegisterAssets` before `03`. That order is wrong:
`RegisterAssets` resolves each `Custom` feed from `deployments/<id>.json .customPriceFeeds.<name>`
(`RegisterAssets.s.sol:19` states the dependency outright), so run first it logs
`[skip] primary feed unresolved (deploy it first)` and moves on. Measured on a mainnet fork in the
plan's order: **20 of 43 assets skipped** — wstETH, eETH, weETH, rETH, ezETH, rsETH, ETHx, osETH,
stETH, lsETH, sUSDe, sUSDS, syrupUSDC, RWIV, sGHO, LDO, OETH, ankrETH, NXM, wNXM. `RegisterAssets` is
idempotent so a later re-run tops them up, but the first pass leaves nearly half of mainnet
unregistered while reporting nothing worse than a skip line.

`01_DeployImplementations` is **not** in the sequence — see 1.2 for why.

Every command runs from the repo root. Common flags:

```bash
CID=1
RPC=<endpoint for $CID>                       # see 0.5
DEPLOYER=0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
BROADCAST="--rpc-url $RPC --broadcast --account my-deployer --password-file <pwfile> --slow"
```

> **`PERSIST_DEPLOYMENTS=1` is mandatory on steps 1.2 and 1.3.** `BaseDeployScript.sol:33` gates the
> top-level address writes on it. Without it `01_2`/`02_2` only *log* the new library, impl and proxy
> addresses; `script/config/deployments/<CID>.json` keeps the OLD ones, and steps 1.4–1.7 then build
> feeds against the old NAV and register adapters on the old proxy. Nothing errors.
> (The per-adapter writes in `03`/`04` are NOT gated — they always write.)

> **Gate every step on its post-condition, not on its exit code.** Each step below states one, and
> `verify_step.py` asserts them:
>
> ```bash
> python3 script/deploy/preflight/verify_step.py 1.2            # the whole 24-chain scope
> python3 script/deploy/preflight/verify_step.py 1.6 1 100      # named chains
> python3 script/deploy/preflight/verify_step.py all 1          # every step, one chain
> ```
>
> It exits non-zero on the first real problem and treats an **unreachable** chain as a failure, not a
> pass, so "no problem found" cannot come from a chain that was never read. It reads only the
> deployment records and the chains — no `forge build` — so it works *between* steps; code identity is
> `bytecode_audit.py`'s job (2.2), not this one's. Do not advance to the next step until the current
> one reports `PASS` on every chain in scope.

### 1.1 Clear the deployment record — otherwise 03 and 04 are silent no-ops

`03_DeployPriceFeeds` and `04_DeployBalanceAdapters` are skip-if-already-deployed. Every feed's
`_deploy*` helper and `04`'s `_deployIfEnabled` (`04:230-234`, **32** such guards in `03`) start with

```solidity
address deployed = _readAdapterDeployed(<section>, <name>);
if (deployed != address(0)) { console2.log("  Already deployed at:", deployed); return; }
```

A re-run against a populated record therefore **succeeds while deploying nothing**, and `06` then
registers the OLD feeds and adapters — which bake the OLD NAV address as an immutable — onto the NEW
proxy. There is no error at any point.

```bash
# dry run first: prints every address that would be cleared
python3 script/deploy/preflight/reset_deployment_records.py

# archive + clear all 24 (bridge keys are deliberately left alone)
python3 script/deploy/preflight/reset_deployment_records.py --apply --tag pre-redeploy
```

Values are set to `""`, which `ConfigReader._readAddrOrZero` (`ConfigReader.sol:216-221`) reads as
`address(0)` while keeping the JSON key present, so `vm.writeJson` writes back into an existing
pointer. The pre-clear record is archived to `preflight/archive/pre-redeploy/<CID>.json` and is the
"old addresses" input for the before/after audits.

- **Precondition:** `git status` clean; snapshot 0.7 captured.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.1` — every key in the NAV
  stack blank, the bridge keys still populated, and a rollback archive present for every chain
  (without it, `--restore` has nothing to put back). Or by hand:
  `jq '.NAVCalculatorProxy, .balanceAdapters.ERC20Default' script/config/deployments/$CID.json` → `""`.

### 1.2 `01_2_DeployNAVImplementation` — libraries + NAV implementation

```bash
PERSIST_DEPLOYMENTS=1 forge script script/deploy/01_2_DeployNAVImplementation.s.sol $BROADCAST
```

**Use `01_2`, not `01` — this matters more than it looks.**

1. ~~**`01` has NO pin assertions.**~~ **No longer true** — `01` gained the same four `require`s
   (both CREATE2 pins, plus impl-linked-against-both, `01_2:47-68`) in the PR superseding #188. The
   history is kept because it is the measurement that motivated the change. Measured on a
   mainnet fork against `main` @ `31c7b1b7` (stale pin): `01_2` reverted safely before broadcasting,
   while `01` **succeeded** and deployed `PriceFeedLib` to `0xee114702…` and `NAVRegistryLib` to
   `0x660e6018…` — the *computed* addresses — even though `NAVCalculator` is linked against the
   foundry.toml pins `0x450421a3…` / `0x549f6fB0…`. On a fresh chain that impl would DELEGATECALL
   code-less addresses and `initialize()` would revert. It only looked healthy on the fork because
   the old pinned libraries already exist on mainnet.
2. `01` additionally deploys and persists `BridgeEscrowImplementation` (`01:68,115`) — wasted ~3–4M
   gas on each of 24 chains, and it rewrites bridge deployment state for a deferred stack.

`01_2` deploys exactly the NAV subset and fails fast on a bad pin.

- **Precondition:** pins regenerated (0.3); record cleared (1.1).
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.2` — all three addresses
  populated, each with code on-chain, the two recorded library addresses equal to the pins (which is
  what the impl is linked against), the two canonical pin copies agreeing with each other, and all
  three **identical on every chain**, since CREATE2 means they must be. The four `require`s in `01_2`
  passing is the pin check on the deploy side; this is the same check from the outside.

### 1.3 `02_2_DeployNAVProxy` — the new proxy + ERC20Default

```bash
PERSIST_DEPLOYMENTS=1 forge script script/deploy/02_2_DeployNAVProxy.s.sol $BROADCAST
```

One atomic transaction: placeholder + proxy + `upgradeToAndCall(impl, initialize(...))`, with roles
granted to `addresses.admin` / `addresses.manager` and the deployer contract renouncing its own
admin. `initialize()` mints the fresh `ERC20DefaultBalanceAdapter` via
`NAVRegistryLib.deployDefaultAdapter` (`NAVCalculator.sol:78`) and `02_2` records it.

- **Precondition:** 1.2 done; `DeploySalts.NAV_PROXY` bumped if 0.2 said so.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.3` — the proxy differs from
  the pre-deploy one and is identical on all 24 chains, its EIP-1967 implementation slot equals the
  recorded impl, `version()` is 1, `erc20DefaultBalanceAdapter()` is a *fresh* address that also
  matches the record (it is minted inside `initialize()`, so an unchanged one means the proxy is the
  old one), and `admin`/`manager` hold `DEFAULT_ADMIN_ROLE` + `MANAGER` while `securityCouncil` holds
  neither — step 07 is excluded from this deploy, so a handoff here would be a mistake, not progress.
  Or by hand:
  ```bash
  cast call $PROXY 'erc20DefaultBalanceAdapter()(address)' --rpc-url $RPC   # != 0x41967559D0a20Ad102F6e27b7723b1963390aD75
  cast call $PROXY 'version()(uint64)' --rpc-url $RPC                       # 1
  cast call $PROXY 'hasRole(bytes32,address)(bool)' 0x00…00 $DEPLOYER --rpc-url $RPC  # true
  ```

> **There is no `initialAssets` argument.** `initialize(admin_, chainlinkL2SequencerUptimeFeed_,
> nativeTokenSymbol_)` hardcodes the ERC20Default seed to `[NATIVE_ADDRESS]`
> (`NAVCalculator.sol:62-78`). The asset set is *not* frozen at genesis — every `registerAsset` calls
> `addSupportedAsset` on it (`NAVCalculator.sol:133`), and
> `excludeAssetFromDefaultAdapter`/`includeAssetInDefaultAdapter` (`:240`/`:247`) mutate it later.
> Nothing needs preparing here, and `script/manage/update-erc20-default-from-chain.sh` is dead code
> (it reads `chains/<id>.json .deployed.NAVCalculatorProxy`, a path that no longer exists, and skips
> every chain).
>
> The one thing a fresh proxy genuinely cannot rebuild from config is the **exclusion** set, since
> `RegisterAssets` re-includes everything. The 2026-07-27 snapshot shows it is **empty on all 24
> chains**, so there is nothing to re-apply — but re-check `excludedFromDefaultAdapter` in the `pre`
> snapshot on the day.

*Chains 130, 143, 146, 196, 204, 480, 999, 5000, 9745, 16661, 42220, 43111, 43114, 57073, 59144,
80094, 534352 are finished here.*

### 1.4 `03_DeployPriceFeeds` — 39 custom feeds

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol $BROADCAST
```

Chains 1 (24), 42161 (8), 8453 (4), 100 (3) only. Each feed's constructor takes the NAV proxy
address, held as `INAVCalculator public immutable NAV` (ADR 0019) — which is precisely why a new
proxy invalidates every existing feed.

> **Three feed contracts are dead code, and the count is still 39.** `cbETH_CustomPriceFeed`,
> `ETHPlus_CustomPriceFeed` and `sDAI_CustomPriceFeed` are deployed on no chain and are enabled in no
> chain's config: `cbETH` and `sDAI` are not config keys at all, and `ETHPlus` is present on mainnet
> with `enabled: false`. Their deploy branches (`03:231`, `03:525`, `03:701`) are reachable in the
> source but never taken, because all three call sites are gated on `ConfigReader.isAdapterEnabled`
> (`03:98`, `03:153`, `03:183`) and a missing key reads as false.
>
> **Dropping them would change the feed count by zero** — they were never among the 39. An audit note
> suggested the redeploy might be 36 rather than 39 instances if they were removed; that is not the
> case, and the 39 in the table above stands. Verified against both the deployment records and the
> enabled config on 2026-07-29.
>
> Worth noting they stay harmless after step 1.1 too: clearing the record removes the skip-guard
> short-circuit, but the `isAdapterEnabled` gate upstream still keeps the branches unreached, so
> nothing tries to read the constructor params they do not have.

> **THE HIGHEST-CONSEQUENCE ORDERING REQUIREMENT IN THIS RUNBOOK: 1.1 MUST precede 1.4, on every
> chain.** Each of `03`'s 32 `_deploy*` helpers opens with a skip-if-deployed guard that `return`s
> early without reverting (`03:233-237` and alike). If the `customPriceFeeds` records survive from
> the previous NAV generation, `03` no-ops on **every** feed, logs, and exits 0 — leaving all 39
> instances bound to the OLD proxy through their `immutable NAV` (ADR 0019). Nothing fails at deploy
> time. It surfaces only when the old proxy is decommissioned, at which point `NavBaseUsdLib`'s catch
> drops **every custom-priced asset to $0 simultaneously** — 24 on mainnet, 8 on arbitrum, 4 on base,
> 3 on gnosis. `03` also exits 0 on logged errors, so a green run is not evidence anything deployed.
>
> `reset_deployment_records.py` clears `customPriceFeeds` (`:66`), and `ConfigReader.sol:147` confirms
> `03`'s `"priceFeeds"` section token is an alias for that same key — so the mitigation exists and
> this is purely an ordering discipline. **`verify_step.py 1.4` now enforces it**: it asserts each
> recorded feed address is *new*, not merely non-zero, by comparing against the pre-clear archive and
> the `pre` snapshot's Custom-type feeds. A count or name check cannot catch this — after a skipped
> reset the names and the count are identical to the previous generation, which is precisely what
> makes it quiet.

- **Precondition:** 1.1 cleared `customPriceFeeds.*`; 1.3 wrote the NEW `NAVCalculatorProxy`.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.4` — the feed count matches
  the table above, every feed has code, and every feed's `NAV()` immutable points at the **new** proxy.
  That last one is the check that matters: a feed is otherwise indistinguishable from a correct one
  while still pricing against the abandoned NAV.

### 1.5 `RegisterAssets` — assets + feeds on the new NAV

```bash
mkdir -p safe-transactions        # REQUIRED — see below
FOUNDRY_PROFILE=slow forge script script/manage/RegisterAssets.s.sol $BROADCAST
```

`FOUNDRY_PROFILE=slow` (16 GiB) is required on mainnet — 43 assets otherwise `MemoryOOG`.

`safe-transactions/` must exist: the script ends by writing a Safe-TX batch there, and if the
directory is missing it aborts with
`vm.writeJson: failed to open file ".../safe-transactions/1-register-assets.json"` **after** the
on-chain registrations have already been broadcast. The chain state is fine and the script is
idempotent, but the run reports failure. The directory is not in the repo, so create it once per
checkout.

- **Precondition:** **1.4 done** — Custom feeds resolve through
  `deployments/<id>.json .customPriceFeeds.<name>`, and without them 20 of mainnet's 43 assets are
  silently skipped (see the authoritative order at the top of section 1).
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.5` — `getAssetCount()` equals
  the configured count (43 / 11 / 11 / 6 / 11 / 5 / 6 for chains 1 / 42161 / 8453 / 10 / 100 / 137 /
  56) **and** the registered address set equals the configured one, so one asset silently substituted
  for another cannot pass on the count alone.

### 1.6 `04_DeployBalanceAdapters` — adapters + assistants

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol $BROADCAST
```

Deploys plain + meta adapters via plain `new` (CREATE), then the delegatecall assistants, whose
`immutable ADAPTER` must point at the **new** assisted adapters.

- **Precondition:** 1.1 cleared `balanceAdapters.*` **and** the three `*Assistant` keys.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.6` — adapter count per chain
  = 27 / 8 / 7 / 4 / 3 / 2 / 1 for 1 / 42161 / 8453 / 100 / 10 / 137 / 56 (ERC20Default included),
  every adapter has code, and **each assistant's `ADAPTER()` resolves to its paired assisted adapter**.
  Run it on chains 1 and 100: against the live stack it reproduces all four orphaned pairings from
  2.1, so a clean report here is the proof the swap was rebuilt rather than inherited.

### 1.7 `06_Configure` — register adapters, reconcile meta instances

```bash
forge script script/deploy/06_Configure.s.sol $BROADCAST
```

Idempotent and reconciling; safe to re-run. If a chain hits an RPC nonce race, re-run just this step
with `--slow`.

`06` also configures `BridgeEscrow`, but it reads `BridgeEscrowProxy` from the deployment record
(`06:31`) and **no chain has one** — so it logs `WARNING: BridgeEscrow not deployed, skipping Bridge
configuration` (`06:37`) and skips the entire bridge block. The deferred bridge is therefore not
touched at all by this step, not merely touched idempotently.

- **Precondition:** 1.5 and 1.6 done.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.7` — `getAdapterCount()`
  matches 1.6, every recorded adapter reports `isAdapterRegistered`, nothing is registered that is not
  in the record, and each meta adapter's `getMetaInstances()` **set equals** its configured coordinate
  set, summing to **110 across the 7 configured chains** (66 / 16 / 16 / 4 / 4 / 4 / 0).

> **Watch for the silent skip.** `06` does `if (deployed == address(0)) continue;` (`06:113` for
> meta, same shape for plain), so an adapter that failed to deploy is skipped **without an error**.
> Always assert the post-condition counts; never trust the exit status alone. Running
> `python3 script/deploy/preflight/preflight_config.py` beforehand catches the config-side causes.

> **Operator check during re-registration (from #172).** Verify each registered instance resolves as
> intended rather than silently masking a misconfiguration. In particular, Aave V3 exposes two
> DataProviders; registering both double-counts positions. `verify_step.py 1.7` compares instance
> **sets**, not counts, so a wrong-but-same-sized instance set fails — but it compares against
> *config*, so it cannot tell you the config itself named the wrong DataProvider. That judgement stays
> human.

### 1.8 Chain-specific workarounds

- **hyperevm (999):** the NAV impl deploy is ~12.5M gas; HyperEVM's small blocks cap at ~3M. Enable
  "big blocks" (~30M) for the deployer via the Hyperliquid `evmUserModify` L1 action
  (`Exchange(wallet, MAINNET_API_URL).use_big_blocks(True)`) before 1.2/1.3, and disable afterwards.
  The chain's reported block gas limit still shows 3M — that is expected.
- **hemi (43111):** the chain enforces a fee floor; a tx priced off a naive `eth_gasPrice` is
  rejected. Raise `--with-gas-price`.

---

## 2. After the deploy

### 2.1 Owners must re-feed the assisted coordinate caches — **4 caches on 2 chains**

`AssistedCoordCache` keys its coordinate cache by account
(`mapping(address account => bytes[] coords)`, `AssistedCoordCache.sol:41`), so a redeployed assisted
adapter starts **empty** and under-reports those positions until the owner Safe re-submits. The
assistants hold an `immutable ADAPTER`, so they are redeployed too and the Safe must delegatecall the
**new** assistant addresses.

| chain | assisted adapter | assistant |
| --- | --- | --- |
| 1 | `EtherFiWithdrawalQueueAssisted` | `EtherFiWithdrawalQueueAssistant` |
| 1 | `NexusMutualStakingPoolsAssisted` | `NexusMutualStakingPoolsAssistant` |
| 1 | `StakeWiseV3ExitQueueAssisted` | `StakeWiseV3ExitQueueAssistant` |
| **100 gnosis** | **`StakeWiseV3ExitQueueAssisted`** | **`StakeWiseV3ExitQueueAssistant`** — the easy miss |

The gnosis pair is easy to miss — the assisted family is usually described as mainnet-only. Read the
new addresses out of `deployments/{1,100}.json` and hand them to the owners. This was left open after
PR #141; do not let it slip again.

> **The assistants recorded today are ORPHANS — measured 2026-07-27.** All four point at adapters
> that are *not* registered on the NAV:
>
> | chain | assistant | its `ADAPTER()` | registered assisted adapter |
> | --- | --- | --- | --- |
> | 1 | `0x8a887C7F` Nexus | `0xb73b3a6b` (has code, **not registered**) | `0x9b3ee866` |
> | 1 | `0xd45cB5B6` ether.fi | `0xb0a8a756` (has code, **not registered**) | `0xdCF0E047` |
> | 1 | `0x13845Fc9` StakeWise | `0xb9a7a8ac` (has code, **not registered**) | `0xcb97dA2c` |
> | 100 | `0xEb438283` StakeWise | `0xe333a72e` (has code, **not registered**) | `0x04E39d91` |
>
> Almost certainly fallout from the PR #141 adapter swap: the assisted adapters were replaced, the
> assistants were not. Delegatecalling the recorded assistants today writes coordinates into the
> cache of an unregistered adapter, which the NAV never reads — so those positions are currently
> un-feedable through the recorded addresses, and this deploy is the first time they will be fed
> correctly.
>
> The redeploy fixes it by construction: `04`'s `_deployAssistantsIfEnabled` builds each assistant
> from the freshly-deployed adapter address, so the pairings are rebuilt from nothing. **But only if
> the `*Assistant` keys are cleared** — it skips an assistant whose key is already populated.
> `reset_deployment_records.py` clears them; do not hand-edit around that.

**2.1a Verify every assistant pairing — REQUIRED, both chains.**

```bash
python3 script/deploy/preflight/bytecode_audit.py 1 100
# every entry must be CURRENT; no CURRENT_CODE_STALE_POINTER, no ORPHAN
```

The audit resolves `ADAPTER()` on each assistant and checks **two** things — that it is in the
deployment record, *and* that `isAdapterRegistered(ADAPTER())` is true on the new NAV. The second is
the one that matters: an assistant pointing at an unregistered adapter feeds a cache the NAV never
reads, which is precisely the live failure (all four report `ORPHAN` against the current stack). Or by
hand, per pair:

```bash
ASST=$(jq -r '.StakeWiseV3ExitQueueAssistant' script/config/deployments/$CID.json)
ADAP=$(cast call $ASST 'ADAPTER()(address)' --rpc-url $RPC)
cast call $PROXY 'isAdapterRegistered(address)(bool)' $ADAP --rpc-url $RPC   # must be true
jq -r '.balanceAdapters.StakeWiseV3ExitQueueAssisted' script/config/deployments/$CID.json  # must equal $ADAP
```

**2.1b Owners re-feed the coordinate caches — 4 caches on 2 chains.**

Hand the owners the **new** assistant addresses from `deployments/{1,100}.json` and confirm each cache
is non-empty afterwards. All four must be done; the gnosis one is the easy miss because the assisted
family is usually described as mainnet-only.

**Until a cache is re-fed those positions UNDER-report — they do not report wrongly.** That is the
family invariant (ADR 0015): the adapter caches position *coordinates only*, values every position
from live on-chain reads, and re-verifies ownership on every read, so a missing coordinate can only
omit value, never invent it. Consequence for triage: a NAV that is *low* after the cutover points at
an un-fed cache and is safe to sit with while owners catch up; a NAV that is *high* is a different
bug entirely and must not be attributed to this step.

```bash
# per (chain, adapter): returns [] until the owner has re-submitted, then the coordinate blobs.
# `coordsOf` is the only cache view getter (AssistedCoordCache.sol:81) — there is no count getter.
cast call $ADAPTER 'coordsOf(address)(bytes[])' $OWNER_SAFE --rpc-url $RPC
```

The cache is keyed per account (`mapping(address account => bytes[] coords)`,
`AssistedCoordCache.sol:41`), so query it for **the owner Safe that holds the positions**, not for the
deployer.

### 2.2 Bytecode-reality audit — the acceptance test

```bash
forge clean && forge build
python3 script/deploy/preflight/bytecode_audit.py --self-test
python3 script/deploy/preflight/bytecode_audit.py --require-current --json post-deploy-bytecode.json
python3 script/deploy/preflight/verify_step.py all          # every step's post-condition, all 24
```

Every address in every `deployments/<chainId>.json` must report `CURRENT`. Any `STALE` is an address
still running code this build does not produce — i.e. something was missed.

**`--require-current` is what makes this a gate.** Without it the audit prints its findings and exits
0 regardless, which is right for the *pre*-deploy run — where 155 `STALE` out of 231 was the expected
answer, not a failure — and wrong here. With it, any non-`CURRENT` address *or any unreachable chain*
exits 1: a chain that was never read has not passed. Pair it with `verify_step.py all`, which asserts
the shape (counts, sets, pointers, roles) that identical bytecode alone does not guarantee.

### 2.3 Before/after NAV comparison

```bash
python3 script/deploy/preflight/snapshot_production.py --out post
python3 script/deploy/preflight/diff_snapshots.py pre post
```

Expect equality except where a hardening fix legitimately changes a label or suppresses an
unreportable leg. Any change in `nav.value` beyond price drift between the two capture blocks needs
an explanation before the cutover.

**Known-expected diffs — do NOT treat these as regressions:**

- **ETHx drops from 2 monitor feeds to 1 on mainnet.** Redstone is retiring both of its ETHx push
  feeds, which backed both monitors. The direct Redstone **ETHx/USD** monitor `0xFaBEb147…` is gone
  with no replacement — Chainlink has no ETHx/USD feed at all (`FeedRegistry.getFeed` reverts
  `Feed not found`). The **`ETHxCrossRate`** monitor survives: its underlying ETHx/ETH rate feed was
  migrated from Redstone `0xc799194c…` to **Chainlink `0xC499ec76e2F5ac15e127A352Bc40cF24FC472401`**.
  So the diff shows ETHx's `monitorFeeds` 2 → 1, and the cross-rate feed at a new address (every feed
  is redeployed anyway). Feed counts are unchanged at 24 mainnet / 39 total, and ETHx keeps its
  divergence/`irregular` signal at 250 bps.
  ETHx's **primary** price was never involved — `ETHx_CustomPriceFeed` reads Stader's on-chain rate
  via `stakePoolsManager` — so `nav.value` should not move.
  Verified on-chain before adopting: `description() == "ETHx / ETH"`, 18 decimals, answer
  `1.093319e18` vs Stader `getExchangeRate` `1.093906e18` = **5.4 bps** apart, last update ~13.8 h
  (inside the 86400 s heartbeat). The 18 decimals need no config change —
  `TwoFeedChainlinkPriceFeed` captures `10 ** rateFeed.decimals()` in its constructor
  (`TwoFeedChainlinkPriceFeed.sol:72`), so the rate decimals cancel into `NAV_DECIMALS`.

### 2.4 Records and docs

- `script/config/deployments/<chainId>.json` — the only place addresses live; all 24 updated.
- `script/deploy/DEPLOYED_ADDRESSES.md` — update the canonical addresses. **It must NOT claim the
  security-council Safe holds admin.** Step 07 is deliberately excluded, so the deployer EOA
  `0xAa5A7C7E…` retains `DEFAULT_ADMIN_ROLE` + `MANAGER` on every chain (verified on-chain across all
  24 in the `pre` snapshot). That file made exactly this false claim once before, fixed in
  `e2230a9d`; today's wording is correct — keep it.

### 2.5 Source verification

Use the `verify-contracts` skill. `PriceFeedLib` needs its special recipe: a **287-file**
standard-json (the import closure of all non-test roots, which pulls in exactly 3 `test/` files that
`script/test/*` imports), whitespace-only reduction to fit Etherscan's hard **3,000,000-character**
limit, and `settings.libraries` linking **both** `NAVRegistryLib` and `PriceFeedLib` (self-link).
Comment-stripping corrupts the bytecode; whitespace-only reduction does not. Always local-compile the
reduced JSON and assert the `PriceFeedLib` creation size before submitting.

### 2.6 Integration snapshots

```bash
script/test/refresh-integration-snapshot.sh
```

Fork blocks and expected NAVs derive from live addresses, so they must be refreshed after the
cutover. PR #174 (the bot's snapshot refresh) was **closed, not merged**, so this is outstanding
independently of this deploy.

### 2.7 Downstream cutover — the user's

kpkShares / portal / agents / subgraphs must repoint from `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d`
to the new proxy. The old stack keeps answering until they do; nothing needs unregistering on it.

---

## 3. Failure playbook

> **Exit status 0 does not mean work happened.** Several scripts return cleanly when a precondition
> is unmet: `RegisterAssets` prints `NAVCalculator not deployed for this chain. Deploy it first, then
> re-run.` and returns; `03`/`04` print `Already deployed at:`; `06` prints `BridgeEscrow not
> deployed, skipping`. In the fork rehearsal, `RegisterAssets`, `04` and `06` all reported success
> having done nothing, purely because `01_2` had reverted upstream. Always verify the
> post-condition counts, never the exit code. `rehearse_fork.sh` now treats those phrases as
> failures, and `verify_step.py <step>` asserts the post-conditions themselves.
>
> **The preflight tools have the same failure mode, and it was real.** They defaulted their chain
> scope to `chainlib.deployed_chain_ids()`, which infers scope from a populated `NAVCalculatorProxy` —
> the very key step 1.1 blanks on all 24 chains. Post-1.1 that returns `[]`, so
> `preflight_config.py` reported `0 error(s) across 0 chain(s)` and exited 0, and
> `reset_deployment_records.py --restore <tag>` with no chain arguments restored **nothing** and
> exited 0 — the rollback failing silently at the one moment it is needed. Scope now comes from
> `chainlib.resolve_chains`, which prefers the committed `snapshots/pre/index.json` (a file the deploy
> cannot invalidate) and **exits 2 rather than resolving to an empty list**. Every tool prints the
> scope it resolved and where from; read that line.

| symptom | cause | fix |
| --- | --- | --- |
| `01_2` reverts `… CREATE2 addr != foundry.toml pin` | library bytecode drifted from the pin | regenerate both pins against the final tree (0.3); never from an incremental build |
| `01` "succeeds" but the NAV reverts on `initialize` | historical: `01` had no pin assertions and deployed the libraries at the *computed* addresses while the impl links the *pinned* ones. `01` now asserts the pins, so this fails fast instead | if it still happens, the pins are stale — regenerate, do not work around |
| a step exits 0 having done nothing | unmet precondition, handled by an early `return` | `verify_step.py <step>`; check the post-condition, not the exit code |
| a preflight tool reports `0 … across 0 chain(s)` | its chain scope resolved to empty | it now exits 2 instead; if you see this on an old checkout, pass the chain ids explicitly |
| `--restore` prints `restored 0 record(s)` | same empty-scope bug, on the rollback path | pass the chain ids explicitly, and check `archive/<tag>/` actually holds the records |
| `01_2` reverts `NAVCalculator impl not linked against pinned …` | `foundry.toml [libraries]` drifted from `LibraryPins` | make them agree, rebuild |
| `02_2` reverts inside `AtomicNAVProxyDeployer` | proxy address unchanged → code already there → `upgradeToAndCall` with no admin | bump `DeploySalts.NAV_PROXY` (0.2), then re-pin (0.3) |
| `03`/`04` log "Already deployed at:" and deploy nothing | the record was not cleared | run 1.1, re-run |
| `06` finishes but adapter/instance counts are short | an adapter never deployed; `06:113` skipped it silently | `preflight_config.py`, then re-run 1.6 and 1.7 |
| `06` reverts `addMetaInstances failed … DuplicateMetaInstance` | duplicate coordinate in config | `preflight_config.py` flags it; fix nav-config |
| `RegisterAssets` `MemoryOOG` on mainnet | default memory limit | `FOUNDRY_PROFILE=slow` |
| `RegisterAssets` logs `[skip] primary feed unresolved (deploy it first)` | it ran before `03`, so Custom feeds are not in the record | run `03` first; re-run `RegisterAssets` (idempotent) and confirm `getAssetCount()` |
| `vm.writeJson: failed to open .../safe-transactions/<id>-register-assets.json` | the directory does not exist; on-chain writes already succeeded | `mkdir -p safe-transactions`, re-run |
| addresses differ per chain that should be identical | a chain ran with a different build or submodule set | 0.4, then rebuild and redeploy that chain — `verify_step.py 1.2`/`1.3` compares across chains and names the odd one out |
| an assistant's `ADAPTER()` is not its paired adapter | the `*Assistant` key was not cleared, so `04` skipped the redeploy | clear it (1.1), re-run 1.6, re-check with `verify_step.py 1.6` |
| hyperevm impl deploy "exceeds block gas limit" | small blocks | enable big blocks (1.8) |
| hemi tx rejected on price | fee floor | raise `--with-gas-price` (1.8) |
