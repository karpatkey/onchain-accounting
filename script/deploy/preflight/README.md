# Deploy preflight tooling

Read-only tooling for preparing and verifying a from-scratch NAV redeploy. Nothing here broadcasts to
a real chain; the one script that broadcasts at all — `rehearse_fork.sh` — refuses any RPC that is not
loopback.

The ordered procedure these support is [`../REDEPLOY_RUNBOOK.md`](../REDEPLOY_RUNBOOK.md).

| tool | what it does |
| --- | --- |
| `chainlib.py` | shared library: repo paths, RPC resolution + probing, batched JSON-RPC, deployment-record enumeration |
| `snapshot_production.py` | captures the full live NAV state of every deployed chain to `snapshots/<tag>/` |
| `diff_snapshots.py` | diffs two snapshots; addresses are expected to move, shape is not |
| `bytecode_audit.py` | proves every deployed address does (or does not) run code from the current build |
| `preflight_config.py` | validates every per-chain config the deploy reads, before a tx is sent |
| `reset_deployment_records.py` | archives + clears the deployment records so `03`/`04` actually redeploy |
| `deployer_balances.py` | deployer-EOA balance vs estimated gas per chain; emits a top-up list |
| `rehearse_fork.sh` | runs the real deploy sequence end-to-end against a local anvil fork |

## Typical order

```bash
# before the deploy
python3 preflight_config.py                       # config must be clean
python3 snapshot_production.py --out pre          # irreplaceable — the old NAV is abandoned after this
python3 deployer_balances.py --json topup.json
./rehearse_fork.sh 1                              # dress rehearsal on a mainnet fork
python3 reset_deployment_records.py --apply --tag pre-redeploy

# … deploy per the runbook …

# after the deploy
forge clean && forge build
python3 bytecode_audit.py --self-test
python3 bytecode_audit.py --json post-bytecode.json      # every address must be CURRENT
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
`ConfigReader.sol:759` exactly (`$ALCHEMY` → `ALCHEMY_API_KEY`, `$FOO` → env). `probe_rpc` then adds
what the deploy does in practice: a URL *resolving* is not a URL *working* — the Alchemy app behind
`ALCHEMY_API_KEY` has most networks disabled and only says so on a real request. `probe_rpc` tries the
configured endpoint, then the per-chain `*_URL` var, then a public fallback, and reports which ones
were rejected and why.

**Batched JSON-RPC.** Providers meter per request, not per call. Mainnet's snapshot is ~200 calls; run
one at a time against a throttled endpoint it takes over 15 minutes, batched it takes ~70 seconds.

**The bytecode audit matches by code, not by name.** Deployment-record keys are operator shorthand
(`AaveV3InstancesMeta`, `sDAI`) that does not map mechanically onto artifact names
(`AaveV3InstancesMetaBalanceAdapter`, `sDAI_CustomPriceFeed`). Rather than maintain a name table, the
audit indexes every artifact by its immutable-masked runtime code and looks the on-chain code up. Run
`--self-test` first: it verifies on real artifacts that masking recovers a contract whose immutables
differ, that a byte flipped outside the immutable ranges does *not* match, and that garbage and
truncated code match nothing.

**Enumeration is complete by construction.** `chainlib.enumerate_deployed` walks the whole deployment
record — 231 addresses across the 24 chains. `script/verify/sweeps/make_targets.py` covers only
`PriceFeedLib` + the NAV implementation plus feed instances read from **uncommitted** `broadcast/`
logs, so it omits the proxy, `NavRegistryLib`, all 27 balance adapters and the assistants; it is not
usable as the audit's enumerator.
