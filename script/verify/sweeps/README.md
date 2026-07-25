# Multi-explorer verification sweeps

Runners used for the ADR 0020 redeploy (2026-07-25): `PriceFeedLib` + the `NAVCalculator`
implementation on 24 chains, plus the 39 re-deployed custom price feeds on chains 1 / 100 / 8453 /
42161 — 87 (chain, address) instances in total.

They live here rather than in a scratch directory because the previous rollout's equivalents were
lost with their tmpdir, and the next migration had to reconstruct them from a session transcript.

## Order

```bash
python3 prep.py            # std-JSON per contract type + ABI-encoded ctor args per instance
python3 mkstd_lib.py       # full-deploy-scope std-JSON for PriceFeedLib (see "The library" below)
python3 sourcify_sweep.py  # FIRST: keyless, exact-match, propagates to Etherscan + Routescan
python3 etherscan_sweep.py "$ETHERSCAN_API_KEY"   # impl + feeds
python3 etherscan_lib.py   "$ETHERSCAN_API_KEY"   # PriceFeedLib, raw HTTP, full-scope payload
python3 blockscout_sweep.py ; python3 oklink_sweep.py ; python3 routescan_sweep.py
python3 tenderly_sweep.py  # always PUBLIC; creds from kpk-agents/.env
python3 matrix.py "$ETHERSCAN_API_KEY"            # independent READ-based confirmation
```

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
upload — accepts the *identical* payload and verifies (`blockscout_lib_v2.py`). Use the v2 runner;
`blockscout_lib.py` is kept only to document the dead end. Server-side compilation of the full
via_ir project can take well over 5 minutes per instance, so poll patiently rather than concluding
failure.

Etherscan matters most here regardless, since it is what clears the "contract contains unverified
libraries" banner on the implementation across every `…scan` UI.

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
