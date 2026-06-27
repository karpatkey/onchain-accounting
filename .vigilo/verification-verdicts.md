# Adversarial Verification Verdicts (Phase 3)

Each Phase-2 finding was re-checked by an independent agent instructed to REFUTE it with code evidence.

| Finding (original) | Original sev | Verdict | Final sev | Key evidence |
|---|---|---|---|---|
| access-control/H-01 + low/L-01 safecast-toInt256 DoS | High/Low | REFUTED — already fixed | — (resolved) | `PriceFeedLib.sol:102` bounds check before cast; commit 887ac32; per-feed isolated |
| access-control/H-02 proxy front-run + M-07 | High/Med | REFUTED | — (invalid) | `AtomicProxyDeployer` constructor deploys+initializes atomically; v1 front-run already remediated by salt bump |
| access-control/H-02 bridge-adapter front-run | High | CONFIRMED, downgraded | Low | adapters CREATE2+init in separate txs (`05_DeployBridgeAdapters`), but escrow auth (`06`) + council handoff (`07`) + salt-bump redeploy mean funds safe; only griefing |
| oracle/H-03 sUSDe-sUSDS share unit | High | REFUTED-INVALID | — (invalid) | feeds use `convertToAssets(10**_vaultDecimals)` and divide by same; correct |
| oracle/H-02 no-staleness-on-rate-sources | High | OVERSTATED | Medium | rETH/wstETH/cbETH/ETHx/rsETH rates are live-computed ratios, not push-stamped; real risk is protocol pause/compromise + no reasonableness bounds |
| oracle/H-01 rate-feed-sentinel-beats-chainlink | High | CONFIRMED but latent | Medium | `PriceFeedLib.sol:110` sentinel `block.timestamp-1` wins freshest-selection; BUT no registered asset currently pairs a rate-only custom feed with Chainlink (config-gated) |
| cross-chain/H-01 across-tautological-auth | High | OVERSTATED | Medium | tautology real but gate is `trustedRemoteAdapter[k]==address(this)` (state) + funded pass-through; needs compromised MANAGER |
| cross-chain/H-04 across-manager-source-from-protocolData | High | CONFIRMED, downgraded | Medium | compromised MANAGER can redirect IN-TRANSIT funds to an AUTHORIZED account; bounded by what Across delivered; duplicate of access-control/M-06 |
| cross-chain/H-03 192-bit-checksum | High | OVERSTATED | Low | second-preimage on 192-bit = 2^192 work (not 2^96); monotonic nonce in preimage; defense-in-depth: widen to 256-bit |
| cross-chain/H-02 superchain-dual-L2 | High | CONFIRMED | High (design) | single L1 adapter w/ same CREATE2 addr can't disambiguate OP vs Base; `trustedRemoteAdapter[10]==[8453]`; no code guard — must deploy separate adapters per L2 + guard `setTrustedRemoteAdapter`. Matches known open issue. |
