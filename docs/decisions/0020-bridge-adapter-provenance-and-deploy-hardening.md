# 0020 — Bridge adapter provenance + deploy hardening (multi-L2 Superchain, Gnosis mediator auth, initializer guard)

**Status:** accepted

## Context

Bringing the Bridge Escrow ([ADR 0012](0012-bridge-provable-release-rearchitecture.md)) up on mainnet — one
real CCTP bridge plus a static pre-audit of every adapter before risking funds — surfaced three design-level
problems (alongside smaller bug fixes). All three had passed the 250+ test suite because the **mocks encoded
the same wrong assumption as the adapter**, so the tests validated the bug instead of catching it; only a real
protocol message (or a careful audit of the real protocol's message shape) exposed them.

1. **CCTP / Gnosis completion authenticated the wrong protocol field.** Both adapters compared an inbound
   protocol field against the CREATE2 same-address sibling adapter, but the real protocol populates that field
   with its own handler contract:
   - CCTP V2: the message **header recipient** (bytes 76–108) is the destination **TokenMessenger**, not the
     mint recipient — only the message **body** mintRecipient (bytes 184–216) is the adapter. Checking the
     header against the adapter reverted every real Circle message (`InvalidMintRecipient`).
   - Gnosis: `amb.messageSender()` for an inbound Omnibridge transfer is the **source Omnibridge mediator**
     (the contract that called `requireToPassMessage` on the source), never the sibling adapter — so every
     real transfer failed authentication and the delivered tokens stranded on the adapter (the mediator
     swallows the receiver-callback revert).
2. **Superchain could only ever serve one L2.** The L1 adapter stored a single `optimismPortal` /
   `l1Bridge` / `l1ToL2Token`. OP and Base have **distinct** L1 OptimismPortals + standard bridges, and the
   same-address CREATE2 model gives exactly one L1 adapter — so it could route to OP *or* Base, not both. As
   configured (no L1 block) it wasn't deployable at all; naively enabling it on one L2 left the other's
   withdrawals unfinalizable.
3. **The adapter deploy→initialize window was front-runnable.** Adapters deploy via the canonical CREATE2
   factory and `initialize()` in a *separate* tx; `initialize` was caller-unrestricted and granted
   `DEFAULT_ADMIN_ROLE`. The deterministic address is publicly precomputable, so a bot could deploy the
   identical bytecode and initialize it first, capturing/bricking the address. (The Ethereum escrow proxy was
   in fact front-run this way during the first deploy; the escrow uses an atomic deployer, but adapters did
   not.)

## Decision

**1. Authenticate against the field the real protocol actually populates.**
- **CCTP:** verify the **body** mintRecipient equals this adapter, and assert the **header** recipient equals
  the configured **TokenMessenger** (`CctpBridgeAdapter._verifyCctpMessage`).
- **Gnosis:** add a per-source-chain `trustedMediator` mapping (set by `setTrustedMediator`, wired by `06`
  from the remote chain's Omnibridge config); `_authenticateSource` compares `amb.messageSender()` against
  the mediator. Because the auto-path (`onTokenTransfer`) is the only context where `amb.messageSender()` is
  meaningful, it **records** `authenticatedInvoice[invoiceId]` at genuine delivery and then attempts the
  release inside a `try/catch` (so a transient release failure leaves the tokens + provenance recoverable
  rather than reverting and discarding both). The MANAGER fallback (`_completeBridge`) can then complete
  **only** invoices whose provenance was recorded — it cannot re-read the AMB after the fact.

**2. Superchain multi-L2 via per-L2-chainId keyed maps (Option C).** The L1 adapter keys its L1 config by L2
chain id: `l1BridgeForL2`, `optimismPortalForL2`, `l1ToL2TokenForL2`. The deposit leg selects by
`data.destinationChainId`; prove/finalize select by `data.sourceChainId` (the same id flows through both, so
a withdrawal is always finalized on the portal it was proven on). `initialize` drops the two single L1 args;
per-L2 bridges/portals are seeded by `05` from index-aligned config arrays (`l2ChainIds` / `l1Bridges` /
`optimismPortals`). One same-address L1 adapter now serves OP + Base (and future OP-stack chains by config).

**3. Pin the initializer into the adapter bytecode.** `BridgeAdapter` takes an `expectedInitializer`
immutable in its constructor; `_initializeBridgeAdapter` rejects any caller other than that address
(`address(0)` disables the guard, used only in tests). `05` bakes the deployer EOA into each adapter's
`creationCode` — identical on every chain, so the CREATE2 same-address guarantee is preserved — and makes the
init gate idempotent (initialize whenever `bridgeEscrow == 0`, not only on a fresh deploy) so a hostile
pre-deploy cannot leave the adapter uninitialized. A bot that pre-deploys the identical bytecode still cannot
initialize it; only the pinned deployer can.

Smaller fixes landed alongside (not design-level): CCIP defaults to a non-empty `EVMExtraArgsV1{gasLimit}`
(empty is rejected on some lanes; OOO-enforcing lanes set V2 per-lane); the escrow `releaseByInvoiceId`
timestamp guard gained a skew tolerance; and Across gained an optional exclusive-relayer window (see
*Consequences*).

## Consequences

- **Test hygiene:** every affected mock was corrected to reproduce the *real* protocol message/authentication
  (TokenMessenger at the CCTP header slot; the Omnibridge mediator as `messageSender`), and negative tests
  were added, so the "mock mirrors the bug" class is closed for these paths. Validated with unit + fork
  suites against real protocol contracts.
- **Across still needs an operational relayer.** The escrow's funded pass-through pulls exactly `data.amount`
  on the destination, so `outputAmount` must equal `inputAmount` (no shaved relayer margin) — meaning no
  open-market relayer fills the deposit. The fix adds an optional `exclusiveRelayer` + window so a fund-
  designated relayer fills at zero margin; without one, deposits expire and Across refunds the adapter. This
  is an operational requirement, deliberately not an escrow schema change.
- **Storage/redeploy:** these are greenfield contract changes (no bridge adapter is recorded as deployed on
  `main`), so there is no storage migration; every adapter address shifts and the system is redeployed clean
  from a fresh EOA with a front-run-safe atomic flow.
- **Design-sensitive items flagged for review:** the Gnosis fallback shape (record-gated + non-reverting
  auto-release), the Across relayer policy, and Superchain Option C were called out for team review on the
  landing PR.

## Alternatives considered

- **Superchain Option D** (deploy the L1 adapter twice at different salts, one per L2): no contract change,
  but breaks the "one canonical same-address adapter per protocol" model on L1 and doubles the L1 instances
  to authorize/manage. Rejected in favor of the cleaner keyed-map end-state.
- **Gnosis: drop the MANAGER fallback** and rely solely on the auto path: simpler, but an invoice whose
  auto-release failed could only be rescued via `recoverStuckAssets` (never reaching `COMPLETED`). Rejected in
  favor of the recorded-provenance fallback.
- **Initializer front-run: an atomic deploy-and-init factory** (like the escrow's): does not close the window
  on its own — a bot can still pre-deploy the identical unrestricted bytecode and init it first — so it would
  require the `expectedInitializer` guard anyway. The guard alone is sufficient and simpler.
