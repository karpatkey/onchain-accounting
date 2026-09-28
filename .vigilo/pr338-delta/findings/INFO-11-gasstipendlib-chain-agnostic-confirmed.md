# INFO-11: `GasStipendLib`/`StaticCallLib` gas-metering is chain-agnostic by construction — no chain-specific fail-open/fail-closed divergence found across the 8 asset chains

## Summary
`src/utils/GasStipendLib.sol`'s `stipendFrom`/`exhausted` pair, which the new gas-metered fan-out in
`MetaBalanceAdapter` relies on to fail closed on genuine gas exhaustion (rather than silently dropping legs),
is built entirely on **EIP-150's 63/64 call-forwarding rule** — an opcode-level EVM property that is identical
on every full EVM-equivalent chain, independent of gas *price*, L1 data-availability fees, or block-gas-limit
policy (all of which genuinely do vary across the 8 asset chains: 1, 10, 56, 100, 137, 8453, 42161, 5042). No
chain-specific divergence in this classifier's behavior was found.

## Analysis

### What varies per chain, and why it does not matter here
- File: `src/utils/GasStipendLib.sol`, lines 38-60.
- `stipendFrom(available) = available - available/64` and `exhausted(stipend, consumed) = consumed >= stipend -
  stipend/8` both operate purely on **gas units** read via `gasleft()` before and after a call — never on
  `tx.gasprice`, `block.basefee`, or any L1-fee/L2-fee-scalar concept. Optimism/Base's L1 data fee, Arbitrum's
  L1 calldata pricing, and Polygon/BSC/Gnosis's differing base gas prices all affect the **cost** of a
  transaction, not the **unit accounting** `gasleft()` reports inside a single EVM execution — which is what
  this library reasons about exclusively.
- EIP-150's 63/64 forwarding rule (the rule `stipendFrom` explicitly mirrors, per its own comment "Exactly what
  the EVM would forward on its own (63/64)") is a **base-layer EVM semantics rule**, live on Ethereum mainnet
  since Tangerine Whistle (2016) and inherited unmodified by every general-purpose EVM-equivalent chain in the
  8-chain asset scope: Optimism/Base (OP Stack, EVM-equivalent by design), Arbitrum (Nitro, EVM-equivalent),
  Gnosis Chain, Polygon PoS, BSC, and Arc (confirmed EVM-equivalent with the pinned `cancun` evm_version via the
  fleet-wide CREATE2 address match documented in INFO-10). None of these chains customize call-gas forwarding.

### Cross-checked against the existing narrower finding
LOW-03 (already filed) identifies a real, but explicitly **chain-agnostic**, residual: `SLACK_DIVISOR = 8`
narrows rather than closes the exhaustion-classification window for deeply nested calls, independent of which
chain the contract runs on — the library's own docstring frames this purely in terms of EVM call-nesting depth,
never chain identity. This finding does not overlap with LOW-03; it specifically confirms there is no
**additional**, chain-specific instance of misclassification (e.g. a chain with a different EIP-150 fraction, a
different PUSH0/opcode-gas-cost schedule that would shift `LABEL_LEAF_GAS`'s measured headroom, or a different
gas-refund policy that could distort `consumed` in `exhausted`'s comparison).

### `StaticCallLib.probeWordMetered` and `LABEL_LEAF_GAS`
Both are likewise gas-unit-only mechanisms (fixed gas ceilings passed as `{gas: ...}` to a `staticcall`/`try
this.<leaf>()` boundary), not gas-price-based, and not documented or observed to assume any chain-specific
opcode pricing beyond standard EVM gas costs. `MetaBalanceAdapter.sol`'s own `LABEL_LEAF_GAS` derivation
(lines 35-75) is measured against worst-case protocol state (Balancer V2 gauges at 50 tokens, Fluid vaults
against the registered-asset count), not against any chain's gas schedule — the margin discussion is entirely
about EVM opcode cost and registered-asset growth, never chain identity.

## Conclusion
No finding. The PR #338 gas-metering redesign is architecturally chain-agnostic; its correctness properties
(fail-closed classification, the SLACK_DIVISOR residual already tracked in LOW-03) hold identically on all 8
asset chains, including Arc.
