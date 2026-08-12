# Deploy preflight tooling

Tooling for preparing and verifying a from-scratch NAV redeploy. Nothing here broadcasts to a real
chain; the one script that broadcasts at all — `rehearse_fork.sh` — refuses any RPC that is not
loopback.

Four scripts write **git-tracked** files. This list has been wrong before, so treat `git status` as
the check of record rather than this paragraph. `reset_deployment_records.py --apply` also creates
`archive/<tag>/` here, which is neither tracked nor ignored — that is the copy `--restore <tag>`
reads, so leave it in place while a rollback is still wanted. (`rehearse_fork.sh` creates one too, as
`archive/rehearsal-<pid>/`, and removes it again immediately (`:421-424`); one left behind is a
killed rehearsal, not a rollback copy.)

- `reset_deployment_records.py --apply` archives the record of every in-scope chain that has one under
  `archive/<tag>/`, then clears the NAV keys in the deployment records; the bridge keys are
  deliberately kept. Dry-run by default. `--restore <tag>` copies back every archived record in the
  resolved scope; that scope comes from the declared chain list rather than from the archive, so
  undoing a subset clear still prints the other chains as `MISSING` and exits 1 even though the
  restore itself succeeded.
- `snapshot_production.py` resolves `--out` to `snapshots/<out>/` here, or, when the value contains a
  `/`, to that path exactly as given — absolute, or relative to the directory you run it from
  (`:346`; nothing here changes directory, and the "Typical order" block below runs from this
  directory). It **defaults to `--out pre`**, the committed capture described below, and that block
  passes `--out pre` deliberately. Judge safety by the resolved destination, not the flag text: any
  run whose `out_dir` lands on `snapshots/pre/` overwrites it.
- `declared_heartbeat_guard.py --refresh` rewrites the committed `chainlink_declared_heartbeats.json`.
- `rehearse_fork.sh` mutates tracked config under `script/config/` and writes `broadcast/` during a
  rehearsal, refuses to start if either is dirty (`:63` — those two paths only, not the whole tree),
  and on exit restores tracked files with `git checkout --` (`:386`) **and deletes untracked,
  non-ignored ones with `git clean -fdq`** (`:393`) under those same two paths.

The `--json` report paths these tools accept, and `snapshot_production.py`'s `--out`, are opened
exactly as given, so they can be pointed anywhere: run from the repo root, `--out
script/config/deployments` would write snapshots over the deployment records, and nothing in the
tooling prevents it. `reset_deployment_records.py`'s `--tag` is joined to the archive directory
without validation, so an absolute or `../` value puts the archive outside this directory as well.
The remaining destinations — the deployment records, the heartbeat snapshot, `script/config/` — are
fixed in code. The four bullets above describe the **documented invocations**, not a guarantee the
tools enforce.

Before treating any of this as reversible, check what the target currently holds.
`script/config/deployments/` is the only place deployed addresses live, so once a step has written
new ones, `git checkout --` discards them and `--restore <tag>` replaces them with the previous
generation's — neither is an undo at that point. Reversibility here is a property of *when you are*,
not of the tool.

The ordered procedure these support is [`../REDEPLOY_RUNBOOK.md`](../REDEPLOY_RUNBOOK.md).

| tool | what it does |
| --- | --- |
| `chainlib.py` | shared library: repo paths, RPC resolution + probing, batched JSON-RPC, deployment-record enumeration |
| `snapshot_production.py` | captures the full live NAV state of every deployed chain to `snapshots/<tag>/` |
| `diff_snapshots.py` | diffs two snapshots; addresses are expected to move, shape is not |
| `bytecode_audit.py` | proves every deployed address does (or does not) run code from the current build |
| `preflight_config.py` | validates every per-chain config the deploy reads, before a tx is sent. Includes the **base allowlist** — a NAV-sourced custom feed's `baseAsset` must be a direct-priced asset, which is where multi-hop pricing cycles are caught (the on-chain guard sees only the self case). `--base-report` prints the base graph; `--self-test` proves every arm, including by mutating the real mainnet config |
| `declared_heartbeat_guard.py` | flags registered heartbeats that do NOT exceed the provider's declared cadence — WARN for an unmeasured one, ERROR only for a broken exemption; also runs inside `preflight_config.py`. `--refresh` re-fetches the committed snapshot, `--self-test` proves the guard |
| `chainlink_declared_heartbeats.json` | committed snapshot of each feed's provider-declared heartbeat; regenerate with `declared_heartbeat_guard.py --refresh` |
| `reset_deployment_records.py` | archives + clears the deployment records so `03`/`04` actually redeploy |
| `deployer_balances.py` | deployer-EOA balance vs estimated gas per chain; emits a top-up list |
| `verify_step.py` | asserts the runbook's post-condition for a given deploy step, on-chain, per chain |
| `redeploy_scope.json` | the declared 24-chain scope; hand-maintained, never written by tooling |
| `rehearse_fork.sh` | runs the real deploy sequence end-to-end against a local anvil fork |

## Typical order

```bash
# before the deploy
python3 preflight_config.py                       # config must be clean
python3 snapshot_production.py --out pre          # irreplaceable — the old NAV is abandoned after this
python3 deployer_balances.py --json topup.json
./rehearse_fork.sh 1                              # dress rehearsal on a mainnet fork
python3 reset_deployment_records.py --apply --tag pre-redeploy

# … deploy per the runbook, gating each step on its post-condition …
python3 verify_step.py 1.2                        # after 01_2, before 02_2
python3 verify_step.py 1.3                        # … and so on through 1.8

# after the deploy
forge clean && forge build
python3 bytecode_audit.py --self-test
python3 bytecode_audit.py --require-current --json post-bytecode.json   # every address CURRENT, or exit 1
python3 verify_step.py all                        # every post-condition, all 24 chains
python3 snapshot_production.py --out post
python3 diff_snapshots.py pre post
```

## `snapshots/pre/`

The committed capture from **2026-07-27**, taken from the live stack on proxy
`0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` across all 24 chains, zero read errors. Per chain it
holds the proxy and EIP-1967 implementation, `erc20DefaultBalanceAdapter` and its full supported-asset
set, role holders, every registered asset with its price/monitor feeds (type, decimals, heartbeat) and
tolerances, every registered adapter with its `AdapterType` and full meta-instance set, and
`getAccountNavVerbose` for every `test/integration/accounts.json` account enabled on that chain. Each
chain's reads are pinned to a single block.

`index.json` is the per-chain summary. Highlights recorded at capture time:

- **110 meta instances** across the 7 configured chains (66 / 16 / 16 / 4 / 4 / 4 / 0 for
  1 / 42161 / 8453 / 10 / 100 / 137 / 56), matching config exactly on every chain.
- **`excludedFromDefaultAdapter` is empty on all 24 chains** — every registered asset is included in
  the default adapter, so there is no exclusion state to re-apply after the redeploy.
- The deployer EOA holds `DEFAULT_ADMIN_ROLE` + `MANAGER` and the security-council Safe holds neither,
  on all 24 chains — step 07 has not been run, consistent with `DEPLOYED_ADDRESSES.md`.

## Notes on the tooling

**RPC resolution mirrors `ConfigReader`, then goes further.** `chainlib.resolve_rpc` reproduces
`_resolveRpcUrl` (`ConfigReader.sol:837`) exactly (`$ALCHEMY` → `ALCHEMY_API_KEY`, `$FOO` → env).
`probe_rpc` then adds what the deploy does in practice: a URL *resolving* is not a URL *working* — the
Alchemy app behind `ALCHEMY_API_KEY` has most networks disabled and only says so on a real request.
`probe_rpc` tries the configured endpoint, then the per-chain `*_URL` var, then a public fallback, and
reports which ones were rejected and why.

**Batched JSON-RPC.** Providers meter per request, not per call. Mainnet's snapshot is ~200 calls; run
one at a time against a throttled endpoint it takes over 15 minutes, batched it takes ~70 seconds.

**The bytecode audit matches by code, not by name.** Deployment-record keys are operator shorthand
(`AaveV3InstancesMeta`, `osGNO`) that does not map mechanically onto artifact names
(`AaveV3InstancesMetaBalanceAdapter`, `osToken_CustomPriceFeed`). Rather than maintain a name table, the
audit indexes every artifact by its immutable-masked runtime code and looks the on-chain code up. Run
`--self-test` first: it verifies on real artifacts that masking recovers a contract whose immutables
differ, that a byte flipped outside the immutable ranges does *not* match, and that garbage and
truncated code match nothing.

**Chain scope is DECLARED, never inferred.** `redeploy_scope.json` holds the 24 chain ids and no tool
writes it. Every derived alternative is rewritten by something in the deploy, so each one can shrink
the scope silently: `deployments/<id>.json .NAVCalculatorProxy` is blanked by step 1.1, and
`snapshots/pre/index.json` is rebuilt from whichever chains the last `snapshot_production.py` run
covered — so a chain that failed capture, or the documented per-chain re-snapshot, would have narrowed
every downstream tool at once. `chainlib.resolve_chains` reads the declared list, reports any
disagreement with derived state as a `SCOPE WARNING` instead of absorbing it, labels an explicit
chain list as a `SUBSET` when it omits declared chains, and **exits 2 rather than returning an empty
list**. `snapshot_production.py` merges into its index rather than replacing it, so a capture can only
ever add knowledge. The obvious-looking default,
`deployed_chain_ids()`, reads `NAVCalculatorProxy` out of the deployment records — the exact key
`reset_deployment_records.py --apply` blanks on all 24 chains at runbook step 1.1. With that default,
everything downstream of the reset checked zero chains and exited 0: `preflight_config.py` reported
`0 error(s) across 0 chain(s)`, and `--restore <tag>` with no chain arguments restored nothing while
reporting success, which is the rollback path failing exactly when it is wanted. Each tool now prints
the scope it resolved and its source.

**Post-conditions are assertions, not prose.** `verify_step.py <1.1…1.8|all>` runs the runbook's
stated post-condition for a step against every chain in scope: record shape, addresses that must have
moved, CREATE2 addresses that must be identical everywhere, `NAV()`/`ADAPTER()` immutable pointers,
role layout, `getAssetCount()`, and per-adapter meta-instance **set** equality against config. It
reads only the deployment records and the chains — no `out/`, no `forge build` — so it is usable
between steps, and an unreachable chain counts as a failure rather than a pass. It deliberately does
not check code identity; that is `bytecode_audit.py`, and `--require-current` gives it the exit code
the acceptance test in runbook 2.2 needs (bare, it prints findings and exits 0, which is correct for
the pre-deploy run where nearly everything is expected to be `STALE`).

**Enumeration is complete by construction.** `chainlib.enumerate_deployed` walks the whole deployment
record — 231 addresses across the 24 chains. `script/verify/sweeps/make_targets.py` covers only
`PriceFeedLib` + the NAV implementation plus feed instances read from **uncommitted** `broadcast/`
logs, so it omits the proxy, `NavRegistryLib`, all 27 balance adapters and the assistants; it is not
usable as the audit's enumerator.
