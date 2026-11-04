# Vigilo audit — PR #360 (ADR 0030) assisted keeper path @ 31395ae9
Verdict: **GO** (no Critical/High/Medium). One Low (an acknowledged design residual with an operational fix) and three Informational notes.

## Priorities checked
1. Over-report: none found. Keeper/preview/removeFor never touch amounts. Write-time validation is the owner path's. Ownership is re-checked per read. Encodings are canonical and length-fixed. All legs are credit (isDebt=false).
2. Dropping or blocking live positions: removeFor is gated on a successful proof-of-death read in all 3 members; a gas sweep cannot fake it (PoC). Blocking is only via cache saturation (L-01).
3. Access control: SUBMITTER_ROLE is checked before the batch loop (empty batch included). DEFAULT_ADMIN_ROLE = securityCouncil (04 reverts if unset). There is no other admin power.
4. StakeWise remainder: matches claimExitedAssets in v1.1.0, v2.0.1, v3.0.1 and main (requeue at ticket+exitedTickets with the same timestamp iff leftTickets>1; leftTickets==1 rounding). Validated end-to-end against a faithful model. Uncollateralized redemption no longer reverts.
5. Gas: preview(256) = 14.4M gas (eth_call only). The NAV read at the cap is covered by existing tests and CoordinateGasExhausted.
6. Reentrancy: none. All adapter-side calls are STATICCALL.

## Findings
- L-01 OWNER_RESERVE bounds the shared length -> a saturated keeper share plus >=32 owner entries blocks the Assistant entry until `evict` (which needs a roles entry). PoC PASS. Fix: provision a roles entry for `evict` before granting SUBMITTER_ROLE, plus a headroom alert.
- I-01 submitForBatch all-or-nothing + revalidation of cached coords.
- I-02 seed_assisted.py discovery/provenance gaps (under-report only).
- I-03 (pre-existing) StakeWise v2-era tickets valued as shares.

## PoCs: test/vigilo-audit/AssistedKeeperAudit.t.sol (copy in poc/) — 9/9 PASS
`forge test --match-path test/vigilo-audit/AssistedKeeperAudit.t.sol -vv`
- AuditStakeWiseRemainderTest: partialClaim_tracksExactRemainder_noDoubleCount, singleLeftoverTicket_notRegistered, uncollateralized_enter_doesNotRevert_noEntry, gasSweep_noSilentUntrackedSuccess (429 successes / 0 untracked)
- AuditRemoveForGasGriefTest: etherfi/nexus/stakewise gasSweep_neverDropsLive (0 drops)
- AuditOwnerReserveTest: keeperSaturation_ownerKeeps32_then_blocked_until_evict, preview_atCap_gas (14,387,914)

Rejected hypotheses: notepad/rejected-hypotheses.md
