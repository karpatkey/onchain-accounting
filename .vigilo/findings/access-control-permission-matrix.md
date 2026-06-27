# Access Control Permission Matrix — onchain-accounting

**Audit date:** 2026-06-27  
**Scope:** `src/**/*.sol`, `script/deploy/*.sol`

---

## Role Legend

| Role | Identifier | Holder (post-deploy) |
|------|-----------|---------------------|
| `DEFAULT_ADMIN_ROLE` | `bytes32(0)` | Security Council Safe |
| `MANAGER` | `keccak256("MANAGER")` | Security Council Safe |
| `ASSISTANT_ROLE` | `keccak256("ASSISTANT_ROLE")` | OIV Safe / designated EOA |
| `ADAPTER_ONLY` | (implicit: `_authorizedAdapters.contains(msg.sender)`) | Authorized BridgeAdapter contracts |
| `ACCOUNT_ONLY` | (implicit: `_authorizedAccounts.contains(msg.sender)`) | Authorized Safe accounts |

---

## NAVCalculator (UUPS Proxy)

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `initialize()` | CRITICAL | None (initializer once) | `initializer` modifier | No (but proxy uninitialized window — see M-07) |
| `_authorizeUpgrade()` | CRITICAL | `DEFAULT_ADMIN_ROLE` | `hasRole(DEFAULT_ADMIN_ROLE, msg.sender)` | None |
| `registerAsset()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `addPriceFeed()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `removePriceFeedAt()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `removePriceFeed()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `addBalanceAdapters()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `removeBalanceAdapters()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `addMetaBalanceAdapter()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `addMetaInstances()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `removeMetaInstances()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `excludeAssetFromDefaultAdapter()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `includeAssetInDefaultAdapter()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `unregisterAsset()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `setChainlinkL2SequencerUptimeFeed()` | HIGH | `DEFAULT_ADMIN_ROLE` | `hasRole(DEFAULT_ADMIN_ROLE, msg.sender)` | None |
| `setChainlinkL2SequencerGracePeriod()` | HIGH | `MANAGER` | `_requireManager()` | None |
| `decodeStringArray()` | LOW | `address(this)` only | `msg.sender != address(this) → revert NotAuthorized` | None |
| `getAccountNav()` | LOW | None | Public view | None |
| `getRegisteredAssets()` | LOW | None | Public view | None |

---

## BridgeEscrow (UUPS Proxy)

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `initialize()` | CRITICAL | None (initializer once) | `initializer` modifier | Proxy window (see M-07) |
| `_authorizeUpgrade()` | CRITICAL | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |
| `depositAndBridge()` | CRITICAL | `ACCOUNT_ONLY` + authorized adapter | `_authorizedAccounts.contains(msg.sender)` + `_authorizedAdapters.contains(adapter)` | None |
| `releaseByInvoiceId()` | CRITICAL | `ADAPTER_ONLY` | `_authorizedAdapters.contains(msg.sender)` | None |
| `cancelInvoice()` | HIGH | `MANAGER_ROLE` | `onlyRole(MANAGER_ROLE)` | None |
| `markInvoiceCompleted()` | HIGH | `MANAGER_ROLE` | `onlyRole(MANAGER_ROLE)` | None |
| `registerAsset()` | HIGH | `MANAGER_ROLE` | `onlyRole(MANAGER_ROLE)` | TOCTOU on re-point (see L-03) |
| `unregisterAsset()` | HIGH | `MANAGER_ROLE` | `onlyRole(MANAGER_ROLE)` | None |
| `authorizeAccount()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |
| `revokeAccount()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Guarded by `_activeInvoices` check |
| `authorizeAdapter()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |
| `revokeAdapter()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | No active invoice guard (see M-04) |
| `pause()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |
| `unpause()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |
| `emergencyWithdraw()` | CRITICAL | `DEFAULT_ADMIN_ROLE` + `whenPaused` | `onlyRole(DEFAULT_ADMIN_ROLE)` + `whenPaused` | Recipient restricted to authorized accounts |

---

## BridgeAdapter (abstract base)

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `initialize()` (concrete) | CRITICAL | None (before init) | `_initialized` bool | Front-run window (see H-02) |
| `setTrustedRemoteAdapter()` | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |
| `completeBridge()` | HIGH | `MANAGER_ROLE` | `hasRole(MANAGER_ROLE, msg.sender)` | State mutation before balance check (see L-05) |
| `bridge()` | HIGH | BridgeEscrow only | `msg.sender != bridgeEscrow → revert` | None |
| `recoverStuckAssets()` | HIGH | `MANAGER_ROLE` | `onlyRole(MANAGER_ROLE)` | Recipient restricted to escrow/authorized accounts |
| `ccipReceive()` (CCIP) | CRITICAL | CCIP Router only | `msg.sender != address(router) → revert` + `_authenticateSource` | None |
| `handleV3AcrossMessage()` (Across) | CRITICAL | SpokePool only | `msg.sender != address(spokePool) → revert` | Weak source auth — chain only, no sender (see M-06) |
| `lzCompose()` (Stargate) | CRITICAL | LZ Endpoint only | `msg.sender != endpoint → revert` + `_authenticateSource` | None |
| `onTokenTransfer()` (Gnosis) | CRITICAL | Omnibridge only | `msg.sender != address(omnibridge) → revert` + `_authenticateSource` | None |
| `completeDeposit()` (Superchain) | CRITICAL | L2 Messenger only | `msg.sender != l2Messenger → revert` + `xDomainMessageSender` check | None |
| `proveWithdrawal()` (Superchain) | HIGH | `MANAGER_ROLE` | `onlyRole(MANAGER_ROLE)` | None |
| Per-adapter config setters | HIGH | `DEFAULT_ADMIN_ROLE` | `onlyRole(DEFAULT_ADMIN_ROLE)` | None |

---

## AssistedBalanceAdapter (abstract base)

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `constructor` grants | HIGH | N/A | `admin != address(0)` | Deployer retains admin (see M-05) |
| `grantRole(ASSISTANT_ROLE, ...)` | HIGH | `DEFAULT_ADMIN_ROLE` | OZ AccessControl | No two-step (see L-04) |
| `revokeRole(ASSISTANT_ROLE, ...)` | HIGH | `DEFAULT_ADMIN_ROLE` | OZ AccessControl | None |
| `renounceRole(DEFAULT_ADMIN_ROLE, ...)` | HIGH | Self | OZ AccessControl | Last-admin renounce possible (see L-04) |

## MerklRewardsBalanceAdapter

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `submitProof()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | Proof verified on-chain; cannot over-report |
| `submitProofBatch()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | Same |
| `clearAllocation()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | None |
| `getAdapterPositions()` | LOW | None | Public view | None |

## EtherFiWithdrawalQueueBalanceAdapter

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `submitTokenIds()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | Ownership re-verified on read; cannot over-report |
| `submitTokenIdsBatch()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | Same |
| `clearTokenId()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | None |
| `clearAccount()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | None |

## StakeWiseV3ExitQueueBalanceAdapter

| Function | Sensitivity | Required Role | Actual Check | Gap? |
|----------|-------------|---------------|--------------|------|
| `submitPositions()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | Ownership verified by `calculateExitedAssets(receiver=account)` |
| `submitPositionsBatch()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | Same |
| `clearPosition()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | None |
| `clearAccount()` | MEDIUM | `ASSISTANT_ROLE` | `onlyRole(ASSISTANT_ROLE)` | None |

---

## Deploy Script Handoff Verification

| Contract | Script 07 Processes? | Deployer Stripped? | Notes |
|----------|---------------------|-------------------|-------|
| NAVCalculatorProxy | Yes | Yes | `_handoff` called |
| BridgeEscrowProxy | Yes | Yes | `_handoff` called |
| CcipBridgeAdapter | Yes | Yes | `_handoff` called |
| AcrossBridgeAdapter | Yes | Yes | `_handoff` called |
| StargateBridgeAdapter | Yes | Yes | `_handoff` called |
| GnosisBridgeAdapter | Yes | Yes | `_handoff` called |
| CctpBridgeAdapter | Yes | Yes | `_handoff` called |
| SuperchainBridgeAdapter | Yes | Yes | `_handoff` called |
| MerklRewardsBalanceAdapter | **No** | **No** | **GAP — see M-05** |
| EtherFiWithdrawalQueueBalanceAdapter | **No** | **No** | **GAP — see M-05** |
| StakeWiseV3ExitQueueBalanceAdapter | **No** | **No** | **GAP — see M-05** |
| NexusMutualStakingPoolsBalanceAdapter | N/A | N/A | No admin (immutable) |
| UniswapV3PoolsMetaBalanceAdapter | N/A | N/A | No admin (immutable) |

---

## Findings Summary

| ID | Severity | Contract | Title |
|----|----------|---------|-------|
| H-02 | High | BridgeAdapter (all concrete) | `initialize()` unprotected — front-run enables adapter takeover |
| M-03 | Medium | BridgeAdapter (all concrete) | No two-step admin transfer — mis-handoff is irrecoverable |
| M-04 | Medium | BridgeEscrow | `revokeAdapter` has no active-invoice guard — can strand in-transit funds |
| M-05 | Medium | AssistedBalanceAdapters (3) | Deploy script 07 does not strip deployer roles from assisted adapters |
| M-06 | Medium | AcrossBridgeAdapter | Source auth binds only chain, not sender — weaker provenance than other adapters |
| M-07 | Medium | UUPSProxy (NAVCalculator, BridgeEscrow) | Uninitialized proxy window enables front-run initialization |
| L-03 | Low | BridgeEscrow | `registerAsset` TOCTOU on symbol re-point |
| L-04 | Low | AssistedBalanceAdapter | No two-step admin — last-admin renounce locks adapter config forever |
| L-05 | Low | BridgeAdapter (CCTP) | Manager path mutates nonce state before balance check |

### Claims Verified (No Gaps Found)

- `ASSISTANT_ROLE` cannot escalate to `DEFAULT_ADMIN_ROLE` (OZ role admin is `DEFAULT_ADMIN_ROLE` for `ASSISTANT_ROLE`; no `_setRoleAdmin` override).
- Merkl `submitProof` cannot fabricate amounts: proof verified against live `Distributor.getMerkleRoot()` on every call; `AmountRegression` guard enforces monotonicity.
- ether.fi adapter cannot over-report: ownership re-verified on every read via `nft.ownerOf(tokenId)`.
- StakeWise adapter cannot over-report: `calculateExitedAssets(receiver=account, ...)` returns 0 for non-matching tuples.
- `NAVCalculator._authorizeUpgrade` correctly requires `DEFAULT_ADMIN_ROLE`.
- `BridgeEscrow.releaseByInvoiceId` is adapter-only (not MANAGER-callable directly) — ADR 0012 claim verified.
- CCIP, Stargate, Gnosis, Superchain adapters authenticate protocol contract + source sender/chain.
- `cancelInvoice` uses stored `invoice.asset` (not re-read from registry) for refund.
- `emergencyWithdraw` restricted to authorized accounts only (not arbitrary address).
- `decodeStringArray` requires `msg.sender == address(this)` — not a public API.
