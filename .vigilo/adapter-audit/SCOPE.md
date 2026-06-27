# Focused per-component audit — every balance/meta/assisted adapter + custom price feed
Branch: audit/vigilo-fixes
Goal: audit EACH contract individually (not just the subsystem). For every contract: state purpose,
then the concrete bug/risk (or "clean") with file:line. Output per-finding md files.
Prior broad audit (docs/audits/2026-06-vigilo-automated-audit.md) already found: ERC4626 convertToAssets-vs-previewRedeem
(M-4), ankrETH ratio staleness (M-2), Lido negative-rebase overstatement (M-6), Convex cliff over-report (M-7),
Cap leg-vs-combined (M-15), ERC4626 double-count (M-5), Balancer read-only reentrancy (M-13). Corroborate or refute
these per-contract; focus effort on NEW issues. Be skeptical; default to "clean/refuted" unless a concrete path exists.
