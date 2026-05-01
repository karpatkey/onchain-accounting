# docs/

Onboarding and reference material that supplements the in-tree per-domain docs (`README.md`, `QUICKSTART.md`, `src/balances/BALANCE_ADAPTERS.md`, `src/bridge/BRIDGE_ADAPTERS.md`, `script/DEPLOYMENT_SUMMARY.md`, `script/deploy/README.md`, `script/config/CONFIG_GUIDE.md`).

| Path | Purpose |
|---|---|
| [`onboarding-claude.md`](onboarding-claude.md) | Architectural walkthrough for a new contributor (or new Claude session). Read before starting any non-trivial PR. |
| [`PRICE_ADAPTERS.md`](PRICE_ADAPTERS.md) | Price feed reference — interface, existing custom feeds, registration. The price-side counterpart to `src/balances/BALANCE_ADAPTERS.md`. |
| [`howto/add-balance-adapter.md`](howto/add-balance-adapter.md) | End-to-end walkthrough: write the adapter + factory + tests + chain config + deploy + register. |
| [`howto/add-price-feed.md`](howto/add-price-feed.md) | End-to-end walkthrough for adding a new custom price feed. |
| [`howto/add-chain.md`](howto/add-chain.md) | End-to-end walkthrough for adding a new chain (config, asset registry, deploy steps). |
| [`howto/refresh-integration-test-blocks.md`](howto/refresh-integration-test-blocks.md) | How to bump the integration-test fork blocks, refresh expected NAVs, and cross-check against Debank. |
| [`decisions/`](decisions/) | Numbered ADRs (Architecture Decision Records). Read when you want the *why* behind a design. |
