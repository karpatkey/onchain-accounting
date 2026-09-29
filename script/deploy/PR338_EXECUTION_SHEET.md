# PR #338 — execution sheet (the live commands, in order)

**This is the step list to execute.** `PR338_MIGRATION_RUNBOOK.md` stays the reference for *why*
(hazards H1–H12, the claimant map, the timelock trade-offs); where the two disagree on *what to run*,
this sheet wins. Every command below was run, in this order, against a fork of each asset chain by
`script/deploy/preflight/rehearse_inplace_fork.sh`, which calls the same gates (`pr338_check.py`) and the same
ops-Safe tool (`ops_safe.py`) — rehearsal `RESULT: PASS` on all 8 asset chains, 0 structural value diff.

**Rules that apply to every step**

- **Explicit go per phase.** Nothing in Phase N+1 starts until Phase N's gates are green on every chain
  it touched.
- **Every broadcast step starts in a fresh shell with** `. script/deploy/preflight/pr338_env.sh <chainId>`.
  ⚠️ **Never pipe it** (`. pr338_env.sh 10 | tail -1`): a pipeline sources it in a SUBSHELL, so `$RPC` and
  the signer arrays stay empty in yours. forge then reads the empty `--rpc-url` as a local socket path
  ("Connection refused … with <cwd>"). This happened live on Gnosis; nothing broadcast. Redirect instead
  (`> file`), and check `[[ -n "$RPC" ]]` before any forge command.
  It resolves `$RPC` (never printed), checks the endpoint's chain id, unlocks the keystore into a 0600
  password file and checks it is the deployer, and sets the chain's gas workarounds (`FORGE_GAS`/`CAST_GAS`:
  Gnosis tip, HyperEVM `--legacy`, Hemi fee floor). It refuses on any mismatch — do not work around a refusal.
- **Simulate before sending.** `ops_safe.py` simulates by default (`--send` broadcasts); every `cast send`
  below has a `cast call` twin — run it first and expect no revert.
- **A gate that fails stops that chain.** Gates are read-only; re-running one is always safe.
- **Over-report is never licensed.** If any step leaves a token reported twice, stop and roll back
  (§5), do not push forward.

**Scope.** 25 chains with a live NAV (1101 has none — excluded).

| Group | Chains | Sequence |
|---|---|---|
| **Swap chains** (7) | 1, 10, 100, 137, 8453, 42161, 5042 | Phase 1 full → Phase 2 full → 3 → 4 |
| **56** (BSC) | 56 | Phase 1 full (its only meta key is pre-provisioned, unregistered) → Phase 2 upgrade only → 3 → 4 |
| **Upgrade-only** (17) | 130, 143, 146, 196, 204, 480, 999, 5000, 9745, 16661, 42220, 43111, 43114, 57073, 59144, 80094, 534352 | Phase 1 `01_2` → Phase 2 upgrade → 3 → 4 |

**Fixed addresses** (set by `pr338_env.sh`): NAV proxy `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` ·
deployer `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` · ops Safe `0xEEd8dC3c034Be12ff66646cCaAf07D35C43E8AA1`
(same on every chain) · rollback impl `0x40e4134849308d53F85A8B685324E2189b13ff7D`.

---

## 0. Before the first transaction

1. Worktree is at the reviewed tip, clean except gitignored files: `git status --short` empty,
   `ls safe-transactions/` empty.
2. `python3 script/upgrade/check_storage_layout.py` — must report COMPATIBLE (the raw `upgradeToAndCall`
   path below skips `UpgradeNAVCalculator`'s layout guard).
3. Fresh pre-snapshots of the 8 asset chains (tracked files — commit them). The Phase-2 value diff is
   measured against these:
   `python3 script/deploy/preflight/snapshot_production.py --out pre 1 10 56 100 137 8453 42161 5042`
   → 0 errors, 0 health flags, `implementation` = the rollback impl on every chain.
4. **Council Safe is THE Council on every chain** (it will be handed ADMIN in Phase 4):
   `for C in <all 25>; do python3 script/deploy/preflight/pr338_check.py council $C; done`. This checks code on
   ≥2 endpoints and the same owners and threshold as the chain-1 Council. **Any FAIL stops Phase 4 on that chain.**
   ⚠️ **Open blocker, run 2026-09-29:**
   - 24 chains pass.
   - **XLayer (196) fails.** It has the same 8 owners but **threshold 2** (nonce 0, never used). The owners
     must call `changeThreshold(5)` on it before 196's Phase 4, or 196 hands NAV ADMIN to a 2-of-8 Safe.
     Phases 1–3 on 196 do not involve the Council and may proceed.
   - Arc (5042) has one configured endpoint only. Confirm its Council on a second RPC by hand, then re-run
     with `--rpc-url` to pin it.
5. `python3 script/deploy/preflight/residue_audit.py --chain 1 --chain 10 --chain 56 --chain 100 --chain 137
   --chain 8453 --chain 42161` → **0 planned-coordinate collisions** (the hard stop). Dormant residue on
   deregistered adapters is known and inert.
6. `python3 script/deploy/preflight/deployer_balances.py`. Every chain must hold enough gas for its phases.
   A swap chain that runs dry between 2a and 2b sits upgraded but unswapped. Mainnet and Scroll were topped
   up on 2026-09-28.
7. No other MANAGER activity on the asset chains from here until each chain's Phase 2 lands (H8).
8. HyperEVM only: enable big blocks for the deployer before its `01_2` (REDEPLOY_RUNBOOK.md §1.10).
9. A chain that resolves only to a PUBLIC RPC is refused by `pr338_env.sh`. Add a private endpoint, or set
   `PR338_ALLOW_PUBLIC_RPC=1` deliberately for that one chain.

## 1. Phase 1 — EOA deploys (no reported NAV changes)

### 1a. Asset chains (1, 10, 56, 100, 137, 8453, 42161, 5042), one at a time

```bash
. script/deploy/preflight/pr338_env.sh $C
python3 script/deploy/preflight/snapshot_and_clear_meta.py $C            # dry run: eyeball the keys
python3 script/deploy/preflight/snapshot_and_clear_meta.py --apply $C    # writes deployments/$C.pre-swap.json
FOUNDRY_PROFILE=slow PERSIST_DEPLOYMENTS=1 forge script script/deploy/01_2_DeployNAVImplementation.s.sol \
  --rpc-url "$RPC" "${FORGE_SIGNER[@]}" "${FORGE_GAS[@]}" --broadcast --slow
DEPLOYER_EOA=$DEPLOYER FOUNDRY_PROFILE=slow PERSIST_DEPLOYMENTS=1 forge script \
  script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "$RPC" "${FORGE_SIGNER[@]}" "${FORGE_GAS[@]}" --broadcast --slow
python3 script/deploy/preflight/pr338_check.py phase1 $C                  # GATE
```

- ⚠️ **Never run `04` without `--broadcast` once the keys are cleared** — its simulation writes the record.
- ⚠️ `04` logs errors and exits 0. The `phase1` gate is what proves every enabled meta/wallet key has code
  at a NEW address; `Already deployed` lines for plain adapters are expected. Also eyeball
  `broadcast/04_DeployBalanceAdapters.s.sol/$C/run-latest.json`: every `contractAddress` it created is a
  recorded key.
- `01_2` lands the implementation and both libraries at the SAME CREATE2 address on every chain; a second
  chain's `01_2` that finds them already deployed is expected, not an error.

Then, **swap chains only** (not 56), the ops Safe:

```bash
python3 script/deploy/preflight/ops_safe.py deploy --rpc-url "$RPC" --owner $DEPLOYER               # simulate
python3 script/deploy/preflight/ops_safe.py deploy --rpc-url "$RPC" --owner $DEPLOYER --send \
  -- "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"                  # prints "DEPLOYED + verified: 0xEEd8…8AA1"
cast call --from $DEPLOYER $NAV "grantRole(bytes32,address)" $MANAGER_ROLE $OPS --rpc-url "$RPC"
cast send $NAV "grantRole(bytes32,address)" $MANAGER_ROLE $OPS \
  --rpc-url "$RPC" "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"
cast call $NAV "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $OPS --rpc-url "$RPC"   # true
cast call $NAV "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $OPS --rpc-url "$RPC"  # false
```

**Verify every contract before calling the chain done** (standing rule: ALL contracts on ALL chains):
`script/deploy/preflight/verify_pr338_chain.sh $C` verifies, on Etherscan V2:
- every adapter `04` created;
- `NAVRegistryLib`, the implementation and `PriceFeedLib` (plain `forge verify-contract` works for all of
  them, including the library).

It skips anything already verified and prints one line per contract; every line must read `VERIFIED`. The
ops Safe is auto-matched as `SafeProxy`. Chains NOT on Etherscan V2 (Ink, Scroll, X Layer, 0G, Hemi) need
their native explorer: see the verification recipes in `script/verify/sweeps/README.md`.

The ops Safe gets **MANAGER only, never ADMIN.** `ops_safe.py deploy` verifies owner = deployer,
threshold 1, the SafeL2 v1.4.1 singleton, the canonical fallback handler, no guard, no modules.

### 1b. Upgrade-only chains (17)

```bash
. script/deploy/preflight/pr338_env.sh $C
FOUNDRY_PROFILE=slow PERSIST_DEPLOYMENTS=1 forge script script/deploy/01_2_DeployNAVImplementation.s.sol \
  --rpc-url "$RPC" "${FORGE_SIGNER[@]}" "${FORGE_GAS[@]}" --broadcast --slow
python3 script/deploy/preflight/pr338_check.py phase1 $C                  # GATE
script/deploy/preflight/verify_pr338_chain.sh $C                          # every line VERIFIED
```

Commit the updated `deployments/*.json` **and `deployments/*.pre-swap.json`** once Phase 1 is green
everywhere. The `.pre-swap.json` files are the only record of the OLD meta addresses: `plan()` reads
them, and so does the rollback (§5). Keep them until the migration is closed.

## 2. Phase 2 — upgrade, then the swap as ONE transaction per chain

### 2a. Every chain: the upgrade (deployer EOA — it needs ADMIN, which the ops Safe never has)

```bash
. script/deploy/preflight/pr338_env.sh $C
IMPL=$(jq -r .NAVCalculatorImplementation script/config/deployments/$C.json)
cast call --from $DEPLOYER $NAV "upgradeToAndCall(address,bytes)" $IMPL 0x --rpc-url "$RPC"      # no revert
cast send $NAV "upgradeToAndCall(address,bytes)" $IMPL 0x --rpc-url "$RPC" "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"
python3 script/deploy/preflight/pr338_check.py upgrade $C                 # GATE: 1967 slot on ≥2 RPCs
```

On a chain with no meta adapter live before the swap (the 17 upgrade-only chains and 56), `phase1` and
`upgrade` both assert that no registered adapter carries a meta set (H9). They run it before the upgrade
and again after. **That chain's Phase 2 is then done.**

### 2b. Swap chains: swap batch, then wallet-adds batch — both through the ops Safe

Run immediately after 2a on the same chain. Nothing else may touch the NAV in between (H3/H8).

```bash
. script/deploy/preflight/pr338_env.sh $C
python3 script/deploy/preflight/pr338_check.py upgrade $C                 # re-check right before generating
OPS_SAFE=$OPS forge script script/manage/SwapMetaAdapter.s.sol --sig 'plan()' --rpc-url "$RPC" --sender $DEPLOYER
#   -> safe-transactions/$C-swap-meta-adapters.json (generated AFTER the upgrade, stamped for $OPS)
B=safe-transactions/$C-swap-meta-adapters.json
python3 script/deploy/preflight/ops_safe.py exec --rpc-url "$RPC" --owner $DEPLOYER --safe $OPS --batch $B
python3 script/deploy/preflight/ops_safe.py exec --rpc-url "$RPC" --owner $DEPLOYER --safe $OPS --batch $B \
  --send -- "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"            # "EXECUTED atomically … Safe nonce 0 -> 1"

python3 script/deploy/preflight/emit_wallet_adds_batch.py $C --safe $OPS # chains 1, 10, 100, 8453, 42161 only
W=safe-transactions/$C-wallet-adds.json
python3 script/deploy/preflight/ops_safe.py exec --rpc-url "$RPC" --owner $DEPLOYER --safe $OPS --batch $W
python3 script/deploy/preflight/ops_safe.py exec --rpc-url "$RPC" --owner $DEPLOYER --safe $OPS --batch $W \
  --send -- "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"            # "… Safe nonce 1 -> 2"

python3 script/deploy/preflight/pr338_check.py swap $C                    # GATE (completion, positive)
```

- **The swap batch must go through as one transaction.** `ops_safe.py exec` refuses:
  - a batch stamped for another Safe or another chain;
  - any DELEGATECALL entry;
  - a batch that fails simulation;
  - a batch that won't fit in one block.

  `safeTxGas = 0`, so a failing inner call reverts the whole transaction.
- Rehearsed gas for one transaction:

  | Chain | Swap batch | Wallet-adds batch |
  |---|---|---|
  | 1 | 6.30M (54 calls) | 3.06M (16 calls) |
  | 10 | 0.54M | 0.25M |
  | 100 | 1.03M | 0.58M |
  | 137 | 0.43M | — |
  | 8453 | 1.63M | 0.58M |
  | 42161 | 1.74M | 0.90M |
  | 5042 | 0.26M | — |
- The resting state between the two batches is clean: every wallet-class token is reported exactly once, by the default adapter.

Then, on the same chain:

```bash
D=/tmp/pr338-diff-$C; rm -rf $D; mkdir -p $D/pre      # per-chain dirs: the diff pairs EVERY chain in both
cp script/deploy/preflight/snapshots/pre/$C.json $D/pre/
python3 script/deploy/preflight/snapshot_production.py --out $D/post $C
python3 script/deploy/preflight/diff_snapshots.py $D/pre $D/post   # 0 structural; RECLASSIFIED + move INFO only
forge script script/deploy/06_Configure.s.sol --rpc-url "$RPC" --sender $DEPLOYER > /tmp/pr338-06-$C.log 2>&1
grep -q "Balance adapters: added 0 ; meta sets configured 0" /tmp/pr338-06-$C.log \
  && ! grep -qE "Deregistered|Reconciled|^Error" /tmp/pr338-06-$C.log && echo "06: nothing left"   # must print
cast send $NAV "revokeRole(bytes32,address)" $MANAGER_ROLE $OPS \
  --rpc-url "$RPC" "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"     # primary ops-Safe revoke (11 is the backstop)
```

**Snapshot timing:** `snapshot_production.py` reads a block a few behind the head, so a snapshot taken right
after a transaction can predate it (observed on mainnet: s1 read 2 blocks before the upgrade). Every
after-snapshot must show the post-step state before it counts: s1's `implementation` is the new impl, and
s2's `block` is ≥ the wallet-adds block. Otherwise re-take it.

**Expected NAV delta ≈ 0** (H7 = 0 measured on every swap chain). Any material move is a regression, not
the double-count closing — stop and investigate.

## 3. Phase 3 — heartbeats (deployer EOA; every chain, after its Phase 2)

```bash
. script/deploy/preflight/pr338_env.sh $C
forge script script/manage/RealignHeartbeats.s.sol --rpc-url "$RPC" --sender $DEPLOYER    # dry run: plan
forge script script/manage/RealignHeartbeats.s.sol --rpc-url "$RPC" "${FORGE_SIGNER[@]}" "${FORGE_GAS[@]}" \
  --broadcast --slow
forge script script/manage/RealignHeartbeats.s.sol --sig 'verify()' --rpc-url "$RPC"      # GATE: no revert
forge script script/manage/BackfillMetaInstanceClaimants.s.sol --sig 'plan()' --rpc-url "$RPC" \
  --sender $DEPLOYER 2>&1 | grep NothingToDo                                              # GATE (swap chains)
```

## 4. Phase 4 — timelock (only after Phase 3 is green on ALL 25 chains)

Needs a **5-of-8 Council signing round on every chain** — schedule it first.

```bash
. script/deploy/preflight/pr338_env.sh $C
for R in $ADMIN_ROLE $MANAGER_ROLE; do                     # Council gets ADMIN + MANAGER (NOT 07)
  cast send $NAV "grantRole(bytes32,address)" $R $COUNCIL --rpc-url "$RPC" "${CAST_SIGNER[@]}" "${CAST_GAS[@]}"
done
DEPLOYER_EOA=$DEPLOYER SAFE_RETAINS_ROLES=true OPS_SAFE=$OPS PERSIST_DEPLOYMENTS=1 forge script \
  script/deploy/11_DeployTimelockController.s.sol --rpc-url "$RPC" "${FORGE_SIGNER[@]}" "${FORGE_GAS[@]}" \
  --broadcast --slow
#   -> TimelockController at one CREATE2 address fleet-wide + safe-transactions/$C-install-timelock.json
```

- Pass `OPS_SAFE` on the swap chains only (elsewhere omit it). The batch comes out the same either way if
  2b's revoke already landed.
- Right before: `python3 script/deploy/preflight/pr338_check.py council $C` again (it must still be THE Council).
- **The Council executes** `safe-transactions/$C-install-timelock.json`: import it in the Safe
  Transaction Builder on the Council Safe, 5/8 sign, execute. This is the one place the Safe UI is used.
- Then run the gate:

  ```bash
  python3 script/deploy/preflight/pr338_check.py roles $C --ops-safe $OPS --council-retains
  ```

  It checks that the timelock holds ADMIN and MANAGER, and that the deployer and ops Safe hold neither. It
  then rebuilds the set of role holders from the proxy's grant logs and confirms each with `hasRole`. The
  only allowed holders are the timelock, the Council and the `AssetKindRegistry`. The registry holds
  MANAGER only, by design: every one of its setters re-checks `NAV.hasRole(MANAGER)`.
- **On one chain, rehearse one `schedule` → `execute` through the timelock before declaring done.** A
  timelock that cannot execute is a bricked NAV. Use an idempotent payload, e.g. re-granting MANAGER to
  the timelock itself.
- After this, `RealignHeartbeats` and the other EOA MANAGER scripts no longer work from the deployer;
  config changes go through the Council (retained roles) or `scheduleBatch`.

## 5. Rollback (per chain; the NEW implementation stays live until the last step)

Order matters. The claim guard (`includeAssetInDefaultAdapter` reverts while a coordinate is claimed)
makes "downgrade first" unexecutable, so:

0. **Prerequisite:** 2b revoked the ops Safe's MANAGER, so first re-grant it from the deployer, which still
   holds ADMIN until Phase 4: `cast send $NAV "grantRole(bytes32,address)" $MANAGER_ROLE $OPS …`. After Phase 4,
   only the Council can do this.
1. **Wallet family:** in ONE ops-Safe batch, for each wallet adapter:
   - `removeMetaInstances(wallet, coords)`, which releases the claim;
   - `includeAssetInDefaultAdapter(token)`, but **only for coordinates the pre snapshot shows as
     `includedInDefaultAdapter: true`**. Re-arming a token that was not armed pre-migration can double-count
     it against a plain adapter. All 35 were armed on 2026-09-28; re-check against the current `snapshots/pre/`;
   - `removeBalanceAdapters([wallet])`.
2. **Meta swap, reversed:** per adapter, adjacent in ONE batch:
   - `removeMetaInstances(new, set)`;
   - `removeBalanceAdapters([new])`;
   - `addMetaBalanceAdapter(old, set)`.

   **Emit it with `plan()`, never by hand.** Hand-building is where a pair gets split (H2). To emit it:
   - copy `deployments/$C.json` (NEW addresses) to `deployments/$C.pre-swap.json`;
   - restore the old addresses into the record's meta keys;
   - run `OPS_SAFE=$OPS … SwapMetaAdapter.s.sol --sig 'plan()'`;
   - put both files back afterwards.

   The old adapters still have code.
3. Execute both with `ops_safe.py exec`, simulate first, exactly as in 2b.
4. **Only then** the proxy: `upgradeToAndCall($PRE_IMPL, 0x)` from the deployer EOA, while it still holds ADMIN.

These changes are not undone by a rollback:
- exclusions written to `ERC20DefaultBalanceAdapter` (a separate immutable contract);
- the frozen `_metaInstanceTotal` slot.

Phase 1 alone has no on-chain NAV effect and needs no rollback.

## 6. Done

- All four gates green on every chain they apply to.
- `deployments/*.json` committed.
- `script/test/refresh-integration-snapshot.sh`, only after every asset chain has landed.
- `DEPLOYED_ADDRESSES.md` and the Notion Ops pages updated.
- The two expected-red address tests go green.
