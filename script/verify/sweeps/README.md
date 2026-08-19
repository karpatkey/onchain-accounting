# Multi-explorer verification sweeps

Runners used for the ADR 0020 redeploy (2026-07-25): `PriceFeedLib` + the `NAVCalculator`
implementation on 24 chains, plus the 39 re-deployed custom price feeds on chains 1 / 100 / 8453 /
42161 — 87 (chain, address) instances in total.

They live here rather than in a scratch directory because the previous rollout's equivalents were
lost with their tmpdir, and the next migration had to reconstruct them from a session transcript.

## Inputs (generated, not committed)

The per-instance runners read two files from this directory, produced by `make_targets.py` (the three
`PriceFeedLib`-only runners — `etherscan_lib.py`, `blockscout_lib.py`, `blockscout_lib_v2.py` —
hardcode the library address and read neither):

| File | Contents | Derived from |
| --- | --- | --- |
| `targets.json` | `[{chain, addr, name, kind, args?}]` — every (chain, address) to verify | `script/config/deployments/<chainId>.json` for the canonical layer; `broadcast/03_DeployPriceFeeds.s.sol/<chainId>/run-latest.json` for the feeds + their constructor args |
| `paths.json` | `{ContractName: "src/…/File.sol"}` | grep of `src/` for each declaration |

They are regenerated rather than committed because both derive from repo state, and the broadcast
logs they read are themselves untracked. **Run `make_targets.py` on the machine that performed the
deploy** — without those broadcast logs the feed instances are omitted (the script reports what it
skipped rather than failing silently). A runner started without these inputs exits with a pointer
back to the generator instead of a bare traceback — except `tenderly_sweep.py`, which reads them
without that guard.

## Order

```bash
python3 make_targets.py    # FIRST: writes targets.json + paths.json (see Inputs above)
python3 prep.py            # std-JSON per contract type + ABI-encoded ctor args per instance
python3 mkstd_lib.py       # full-deploy-scope std-JSON for PriceFeedLib (see "The library" below)
python3 sourcify_sweep.py  # keyless, exact-match, propagates to Etherscan + Routescan
python3 etherscan_sweep.py "$ETHERSCAN_API_KEY"   # impl + feeds
python3 etherscan_lib.py   "$ETHERSCAN_API_KEY"   # PriceFeedLib, raw HTTP, full-scope payload
python3 blockscout_sweep.py ; python3 blockscout_lib_v2.py
python3 oklink_sweep.py ; python3 routescan_sweep.py
TENDERLY_ENV_FILE=/path/to/.env python3 tenderly_sweep.py   # always PUBLIC
python3 matrix.py "$ETHERSCAN_API_KEY"            # independent READ-based confirmation
```

Paths and toolchain resolve from the checkout (`_paths.py`), with env overrides when you need them:
`NAV_REPO_ROOT`, `SOLC_BIN` (defaults to the svm build for `foundry.toml`'s pin, else `solc` on
PATH), `FOUNDRY_BIN`. Tenderly credentials are read from the environment
(`TENDERLY_ACCOUNT_ID` / `TENDERLY_PROJECT` / `TENDERLY_API_TOKEN`), falling back to a dotenv at
`TENDERLY_ENV_FILE`.

Every script is idempotent and resumable — each keeps a `<backend>_results.json` next to itself and
skips what is already verified, so a killed run just gets re-invoked.

`prep.py` recompiles each std-JSON locally and asserts the bytecode equals the forge artifact. A
`match=False` there means the payload would be rejected by every backend, so fix it before
submitting anything.

## The library is the hard part

`PriceFeedLib` is compiled with `via_ir`, whose whole-unit optimization makes the library's
bytecode depend on the **entire compilation scope**. forge's trimmed import closure (16 sources)
therefore compiles to *different* bytecode than the deploy. `mkstd_lib.py` rebuilds the real scope —
every `src/**` and `script/**` file as a root, imports resolved through remappings (184 roots → 283
sources) — and links both libraries in `settings.libraries`, **including `PriceFeedLib`'s own
self-link**. That reproduces the deployed bytecode exactly. Whitespace-only reduction then brings it
to ~2.60M chars, under Etherscan's hard 3,000,000-char `sourceCode` limit. Do not comment-strip;
whitespace-only is the bytecode-neutral reduction.

Result of that payload across backends (2026-07-25):

| Backend | Library |
| --- | --- |
| Etherscan V2 | ✅ 19/19 on-V2 chains (compiles the full via_ir project server-side, ~1 min/chain) |
| Blockscout | ✅ **but only via the NATIVE v2 route** — see below |
| Sourcify v2 | ❌ `compiler_error` — solc worker OOMs on the full via_ir project |
| OKLink | ❌ `Fail`, with both the reduced and the full payload |
| Tenderly | ❌ upstream request timeout on the 2.6 MB payload (skipped by the runner) |

**Blockscout needs the native endpoint for this library.** Its Etherscan-compatible
`?module=contract&action=verifysourcecode` route accepts the submission and then reports
`Fail - Unable to verify` (`blockscout_lib.py`). The native route — `POST
/api/v2/smart-contracts/<addr>/verification/via/standard-input`, standard-JSON as a multipart file
upload — accepts the same full-scope payload (`PriceFeedLib_full.json`) and verifies
(`blockscout_lib_v2.py`). Use the v2 runner;
`blockscout_lib.py` is kept only to document the dead end. Server-side compilation of the full
via_ir project can take well over 5 minutes per instance, so poll patiently rather than concluding
failure.

Etherscan matters most here regardless, since it is what clears the "contract contains unverified
libraries" banner on the implementation across every `…scan` UI.

**The scope is irreducible — don't try to shrink the payload.** Measured: `src/**` alone (241 files,
2.08 MB reduced) compiles to *different* bytecode; only `src/** + script/**` (283 files, 2.60 MB)
matches. So any backend whose transport ceiling sits below ~2.6 MB cannot take this library at all
(0G's nginx answers `413 Request Entity Too Large`; Tenderly answers `upstream request timeout`).

## Gotchas these runners encode

- `--show-standard-json-input` writes an empty file unless `ETHERSCAN_API_KEY` is set (any value).
- Etherscan `verifysourcecode` needs `chainid` in the URL **query**; in the body alone it silently
  defaults to chain 1.
- Etherscan's constructor-args field is misspelled `constructorArguements`.
- OKLink: keyless but WAF-blocks non-browser UAs; `50026` on submit means **already verified**, and
  `check-verify-result` returns `data` as a bare list of strings, not dicts.
- Sourcify wants the compiler version **bare** (`0.8.34+commit…`); Etherscan/OKLink/Tenderly want it
  `v`-prefixed. Its `externalVerifications` propagation to Etherscan is real but **not reliable** —
  verify explicitly rather than assuming it.
- Tenderly values in `kpk-agents/.env` carry a **leading space**; strip before use.
- Chains off Etherscan V2: 196 xlayer, 16661 0g, 43111 hemi, 57073 ink, 534352 scroll.
- Tenderly does not support chains 204, 999, 16661, 43111.
- `scroll.blockscout.com` 301-redirects the API path — read it with `curl -L`, or a verified
  contract reads back as unverified.
- A freshly deployed contract can read `is_contract: false` on a Blockscout instance whose indexer
  is behind (seen on `explorer.hemi.xyz`); verification cannot succeed until it is indexed, so
  retry rather than treating it as a payload failure.
- There is **no Blockscout API key** anywhere in the org's repos, and none is needed: a Pro key only
  raises rate limits, verification itself is keyless.
- **0G (16661) is verifiable after all.** `chainscan.0g.ai` is a Confluxscan fork: `/api` and
  `/api/v2/...` serve SPA HTML (easy to misread as "no API"), but **`/open/api?module=contract&…`**
  is a full keyless Etherscan-compatible API — `verifysourcecode` → `checkverifystatus` →
  `Pass - Verified`. The NAV implementation is verified there through it. Only the library fails,
  on the 413 above.
- Chain explorers are listed in `script/config/chains/<chainId>.json`; check there before concluding
  a chain has no verification endpoint.

## Final coverage (2026-07-25) — 84 of 87 instances

All 63 implementation + feed instances are verified on every backend that supports their chain
(Sourcify 63/63, Etherscan 58/58 on-V2, Blockscout 48/48, Routescan 30/30, OKLink 51, Tenderly 59) —
zero failures, most on three or four independent explorers.

`PriceFeedLib` is verified on 21 of 24 chains (19 via Etherscan V2, plus ink and scroll via
Blockscout). The three that cannot carry it:

| Chain | Why |
| --- | --- |
| 196 X Layer | off Etherscan V2; OKLink is the only backend and `Fail`s it, Tenderly times out |
| 16661 0G | `/open/api` works for normal contracts, but nginx `413`s the 2.6 MB payload |
| 43111 hemi | Blockscout accepts the job and never completes it (same shape as Sourcify's OOM) |

On all three the NAV implementation — the contract consumers actually read — is verified.
