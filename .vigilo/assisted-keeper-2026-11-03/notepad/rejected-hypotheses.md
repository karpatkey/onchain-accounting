R1 keeper files under wrong account -> over-report: _validateCoord(account) at write + per-read ownership. Refuted (code + existing tests).
R2 non-canonical alias / double count: _requireCanonical length check, abi.decode dirty-address revert, keccak dedupe; StakeWise request key unique. Refuted.
R3 StakeWise remainder wrong ticket / double count: v1.1.0, v2.0.1, v3.0.1 and main all requeue at ticket+exitedTickets, same ts, iff leftTickets>1. The pre-read is the same view the claim runs. PoC partial-claim and single-leftover tests PASS.
R4 removeFor drops a live position via gas choice: PoC sweep 3k..200k gas on all 3 members, 0 drops.
R5 Nexus getTokens reports 0 for a live position (unprocessed expiry): the viewer `require`s instead (revert != death). Refuted (source).
R6 remainder registration silently gas-starved (bare catch{}): PoC sweep 40k..400k, 429 successes, 0 untracked. A starved ~130k SSTORE-heavy child leaves too little for the tail.
R7 empty batch success / roleless: _checkRole before loop. Refuted.
R8 reentrancy: all adapter-side protocol calls are view (STATICCALL); the vault claim follows CEI; a Safe receive has no hook. Refuted.
R9 valueCoordSelf/previewPositionsSelf external abuse: msg.sender==this guard. Refuted.
R10 preview O(n^2) DoS: 14.4M gas at n=256 (eth_call only, not on the NAV path). Acceptable.
R11 attacker-created StakeWise vault (permissionless factory): registry-approved impls; value is real; keeper policy excludes third-party positions; no NAV path for preview. Refuted as over-report.
R12 admin powers: only role admin; no amount/config/upgrade. Refuted.
