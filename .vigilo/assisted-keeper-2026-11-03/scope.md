# Scope — PR #360 (feat/assisted-submitfor-preview @ 31395ae9), diff origin/main...HEAD
Primary:
- src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol
- src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol
- src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol
- src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol
- src/balances/IAssistedBalanceAdapter.sol
- src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol
Context: other assistants, BalanceAdapterAssistant, script/deploy/04 (admin wiring), script/deploy/preflight/seed_assisted.py (S13 provenance)
Spec: docs/decisions/0030-assisted-adapters-keeper-submit-and-preview.md (S1-S15)
External semantics checked: stakewise/v3-core VaultEnterExit @ v1.1.0, v2.0.1, v3.0.1, main; ExitQueue lib @ main; NexusMutual StakingViewer @ master.
