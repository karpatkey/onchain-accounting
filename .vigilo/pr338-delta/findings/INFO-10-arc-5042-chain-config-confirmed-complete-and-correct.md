# INFO-10: Arc (5042) chain-specific config audited — confirmed complete, correct, and consistent with the fleet pattern

## Summary
Cross-checked `script/config/chains/5042.json`, `script/config/deployments/5042.json`, and Arc's
contracts-deployment-config / nav-config trees against the 7 pre-existing asset chains (1, 10, 56, 100, 137,
8453, 42161). No gap or chain-specific misconfiguration found. Recorded as a confirmation per the audit brief's
requirement to explicitly state clean results.

## Analysis

### Governance addresses (item 4 in the audit brief)
`script/config/chains/5042.json`:
```json
"addresses": {
  "securityCouncil": "0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537",
  "admin": "0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72",
  "manager": "0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72"
}
```
`securityCouncil` is byte-identical to every other chain checked (1, 10, 56, 100, 137, 8453, 42161 all carry
`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`), which is the load-bearing property `DeploySalts.TIMELOCK_CONTROLLER`
depends on for a fleet-wide `TimelockController` address. `admin`/`manager` are the deployer EOA
(`0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72`), matching the documented pre-`07` deploy pattern explicitly called
out in `script/config/chains/56.json`'s inline comment ("admin+manager = deployer EOA ... securityCouncil is the
end-state admin that step 07 transfers to"). No zero-address, no divergent Safe.

### L2 sequencer uptime feed
`"chainlinkSequencerFeed": "0x0000000000000000000000000000000000000000"` — zero, same as chains 1, 56, 100,
137 (i.e. every non-Optimism/Arbitrum/Base chain in the fleet; only 10, 42161, 8453 carry a real Chainlink L2
uptime feed address). `Prices.sol`/`PriceFeedLib.checkSequencerUptime` treats `address(0)` as "no sequencer feed
configured" and returns `stale = false` (`PriceFeedLib.sol:467`, "Pass address(0) for uptimeFeed on L1 — returns
false"), which is the correct, fail-open-only-when-genuinely-absent behavior for a chain Chainlink has not
published an L2 sequencer-uptime feed for. This matches the same pattern already accepted for Gnosis, Polygon,
BSC, and mainnet, so Arc's zero value is consistent with the fleet, not an outlier.

### Fleet-wide CREATE2 consistency (proves EVM/Cancun/PUSH0 equivalence, item 3)
`deployments/5042.json`:
```json
"NAVCalculatorImplementation": "0x40e4134849308d53F85A8B685324E2189b13ff7D",
"balanceAdapters": { "MorphoVaultsMeta": "0x64e1ba8B12ee2bFdBDdFd4E0863EdfaaE824C86a" }
```
Both addresses are byte-identical to the values recorded for chain 1 (`deployments/1.json`) and, for
`MorphoVaultsMeta`, chain 42161 (`deployments/42161.json`). Since these are CREATE2 addresses derived from
`(creationCode, ctorArgs, salt)` via the canonical Arachnid deployer, an identical address on Arc proves Arc
compiled and deployed byte-identical bytecode to the other chains under the CURRENT toolchain (`solc 0.8.34`,
`evm_version = cancun`) — i.e. Arc supports every opcode this repo's contracts use, including `PUSH0`, with no
chain-specific EVM divergence. The per-chain config comment corroborates this was measured, not assumed
("confirmed FREE on Arc 2026-09-17 before deploying").

### wARS custom feed (Arc-specific asset)
`contracts-deployment-config/custom-price-feeds/5042.json` registers `wARS` via
`InvertedChainlinkCustomPriceFeed`, mirroring the identical registration already live on chain 1 (same token
address `0x0DC4F92879B7670e5f4e4e6e3c801D229129D90D` on both chains, same feed direction guard via
`rateFeedGuard` pinning both the Chainlink pair `"USD / ARS"` and a `[100, 100000]` (1e18-scaled) rate band). The
heartbeat (86400s) is asserted to equal Chainlink's own declared value for this feed on Arc, per ADR 0025's
equality rule, with the config's own comment flagging the observed staleness margin (17.76h against a 24h
heartbeat) as thin-but-currently-safe. No inversion, pair, or heartbeat mismatch found.

### Native asset modeling
Arc pays gas in USDC, modeled as `NATIVE_ADDRESS` (`0xEeee…EEeE`) at 18 decimals per
`nav-config/assets-and-price-feeds/5042.json`, explicitly distinguished in-comment from 6-decimal ERC-20 USDC to
prevent a 1e12 mispricing if the latter is ever also registered. This is a documented, deliberate modeling choice
consistent with how every other chain's native asset is registered (ETH/xDAI/BNB/POL all at 18 decimals via the
same sentinel), not an Arc-specific gap.

## Conclusion
No finding. Arc (5042) is fully wired for the standard redeploy+swap+heartbeat sequence with nothing
chain-specific mis-set, and its fresh, current-toolchain deploy independently corroborates EVM-equivalence
(Cancun/PUSH0) with the other 7 asset chains.
