# Push-NAV systems: Veda BoringVault, Aera v3, Mellow flexible-vaults

Read-only. Clones in /tmp/nav-research/ (not in repo). Pinned SHAs:
- Veda: Veda-Labs/boring-vault @ cffa9c3f62c70fb80cdae7f95a0be1bf6d0ead2c
- Aera: aera-finance/aera-contracts-public @ 93ce6bea29c0b0da154bf70f035e6843421ca556 (v3/)
- Mellow: mellow-finance/flexible-vaults @ 359c7ed977a78c396a08aec7bf7381833253eedb
[UNVERIFIED] = not read from primary source. [INFERENCE] = reasoned from code, not executed.

## Corrections to state-of-art.md
- §1.3 Veda: accountant logic is L334-621; bounds L505-524 (not "L300+").
- §1.6 Aera: repo path is aera-finance/aera-contracts-public/v3/. Guardian-removal citation BaseVault L140-149 is an older version; current submit L126-151, removeGuardian L160.
- §1.7 Mellow: Subvault is src/vaults/Subvault.sol (not src/accounts/). Verifier is src/permissions/Verifier.sol.

## Current grades (architecture-comparison.json; cells[4]=Veda, [6]=Aera, [7]=Mellow)
declared 0/0/1 · nav 0/0/0 · granularity 2/2/2 · single 0/0/0 · complete 0/0/0 · debt null · isolation null · trust 1/1/1 · readable 0/0/0.
CHANGE marks where proposed grades differ.

---------------------------------------------------------------------
## 1. VEDA BoringVault

### 1.1 Declaration
- No positions declared. Permission = merkle leaf per strategist call: keccak(decoderAndSanitizer, target, valueNonZero, selector, packedAddressArgs). src/base/Roles/ManagerWithMerkleVerification.sol#L285-L286; decoder staticcall #L251; drone target appended #L252-L254.
- Decoders return addresses only (e.g. src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol: supply → (asset, onBehalfOf); borrow/repay → (asset, onBehalfOf)). Amounts never returned.
- Limits: one root per strategist (setManageRoot #L100, owner). No position-count cap; tree size only.

### 1.2 NAV
- Base variant (AccountantWithRateProviders.sol): rate pushed by UPDATE_EXCHANGE_RATE_ROLE, updateExchangeRate #L334-L355. Pusher is off-chain, not in repo [UNVERIFIED].
- Bounds per update, _beforeUpdateExchangeRate #L505-L524: shouldPause = now < last+minDelay OR new > cur*upper/1e4 OR new < cur*lower/1e4. If shouldPause: isPaused=true, fees skipped, but _setExchangeRate still runs, so the out-of-bounds rate is stored. Aggregate drift is unbounded (per-update bounds only).
- Computed at each push, not per deposit/redeem. Read cost O(1).
- Revert handling: getRate #L399 unguarded (returns stored out-of-bounds value); getRateSafe #L407 reverts Paused; getRateInQuote #L418-L433 calls external rateProvider.getRate() unguarded. Teller deposit paths use getRateInQuoteSafe (TellerWithMultiAssetSupport #L587, #L606), so deposits revert while paused. src/helper/ArcticArchitectureLens.sol #L34/#L83/#L95 read raw getRate().
- Yield-streaming variant (AccountantWithYieldStreaming.sol, derived): updateExchangeRate reverts (#L286). Rate derived on-chain: getRate #L369-~380 = (lastSharePrice×supply + pendingVestingGains) × ONE_SHARE / totalSupply. Strategist vestYield(amount, duration) ~#L173-200; duration 1d–7d (#L59, #L65); maxDeviationYield 500 bps/day (#L71), relative to accountant's TWAS estimate, not position value. Min delay enforced only if vestingGains > 0 (#L183-L186): back-to-back vests undelayed [INFERENCE, not verified exploitable].
- Which variant is in production: [UNVERIFIED].

### 1.3 Permissions
- Granularity: target + selector + zero/non-zero value + address args. Amounts unconstrained.
- Who: MANAGER_ROLE on BoringVault (manage #L47-L54, requiresAuth). Path: manageVaultWithMerkleVerification #L133-L162 (MANAGER_INTERNAL / STRATEGIST / MICRO_MANAGER). Root keyed by msg.sender. MULTISIG pause #L110/#L119.
- Batch check #L158: revert if totalSupply changed. Shares only, not NAV; per batch, not per call.
- flashLoan #L172 vault-only; receiveFlashLoan #L193.

### 1.4 Link declaration ↔ accounting
- None. Tree and rate independent. Value can move to a permitted target with amounts the NAV does not yet reflect until the next rate push [INFERENCE].

### 1.5 Debt / readability
- Decoders allow borrow/repay but accountant has no debt field → not valued [INFERENCE].
- Readability: one rate + totalSupply; no per-position data on-chain.

### 1.6 Governance / deployment
- OWNER_ROLE sets delay, upper, lower, fees, payout within constructor bounds (#L155-L192: upper ≥ 1e4, lower ≤ 1e4, delay ≤ 14d, platform ≤ 0.2e4, perf ≤ 0.5e4). MULTISIG pause #L200/#L210.
- setRateProviderData #L299-L303: no on-chain provider validation.
- Upgradeability: not seen [INFERENCE]. Per-vault deploy via script/ArchitectureDeployments/DeploySkeleton.s.sol [UNVERIFIED flow].

### 1.7 Audits / incidents
- Headers: accountant cites audit/0xmacro-veda-92.pdf; manager cites sevenSeas-19; decoder cites sevenSeas-39.
- audit/ holds ~50 PDFs (0xmacro sevenSeas-8..100, arctic-0/1/2, sigma-prime-boring-vault-0, certora boring-vault/swapper). NOT READ [UNVERIFIED].
- No incidents searched [UNVERIFIED].

### 1.8 Proposed grades (Veda)
- declared 0 (no change): merkle leaves are permissions. ManagerWithMerkleVerification.sol#L285-L286.
- nav 0 (no change): pushed bounded rate. AccountantWithRateProviders.sol#L505-L524.
- granularity CHANGE 2→1: leaves fix target/selector/address; amounts never bound. ManagerWithMerkleVerification.sol#L285-L286.
- single 0 (no change): rate and tree independent. #L285; AccountantWithRateProviders.sol#L334.
- complete 0 (no change): any allowed leaf moves value; NAV not checked per call. ManagerWithMerkleVerification.sol#L158.
- debt null, isolation null (no change).
- trust 1 (no change): owner roots, multisig pause, off-chain pusher. ManagerWithMerkleVerification.sol#L100, #L110.
- readable 0 (no change): single rate. AccountantWithRateProviders.sol#L399.

---------------------------------------------------------------------
## 2. AERA v3

### 2.1 Declaration
- No positions. Guardian merkle root per guardian. WHITELIST immutable (src/core/BaseVault.sol#L69). setGuardianRoot #L154 (requiresAuth); _setGuardianRoot #L523-L537 requires non-zero and whitelisted guardian.
- Submit hooks: setSubmitHooks #L183 (requiresAuth). Execution: _executeSubmit #L361, callbacks #L226/#L258.
- Position limits: none read [UNVERIFIED].

### 2.2 NAV
- Unit price pushed by accountant: PriceAndFeeCalculatorV2.sol setAnchorPrice #L171, setDriftPrice #L213 (onlyVaultAccountant).
- Anchor band #L650-L662 (bps tolerance, candidate vs anchor). _shouldPauseAnchor #L605-L620 (min interval, max delay, band). Bad anchor → revert Aera__BadAnchorPriceUpdate unless pauseOnBadAnchorUpdate (default true, set in registerVault #L81).
- Drift outside band → revert (#L233).
- Holdings valued via ORACLE_REGISTRY.getQuoteForUser (_convertTokenToUnits #L500-L515) at spot.
- Fees accrue on each anchor update, _accrueFees #L443-~480, min(price, anchor).
- Computed at anchor/drift push, not per deposit/redeem. Gas scales with holdings count via oracle calls [INFERENCE, not measured].
- Revert handling: paused → *IfActive reverts (#L289-L383 range); unpause #L255 must match anchor exactly. Stale price #L577-L595. Oracle failure propagates as revert [INFERENCE: no try/catch seen].

### 2.3 Permissions
- Granularity: merkle leaf per guardian op + hooks for args. Leaf format not read in detail [UNVERIFIED]; grade kept provisional.
- Who: guardianRoots, submit #L126-L151 (whenNotPaused, nonReentrant; else Aera__CallerIsNotGuardian). Flow: pre-hooks → _executeSubmit → post-hooks → _noPendingApprovalsInvariant → reader.requireAtEndOf(end).
- Pause: onlyAuthOrGuardian #L189 (modifier #L86-L91). Unpause #L195 requiresAuth.
- removeGuardian #L160 (requiresAuth). checkGuardianWhitelist #L169 permissionless: removes root if guardian not whitelisted.

### 2.4 Link declaration ↔ accounting
- None. Guardian roots and price pushes are separate trust roots [INFERENCE].
- Spearbit 2025-06-05 §5.3.2 (Low, acknowledged, "handled operationally"): guardian permission not auto-revoked on whitelist removal; mitigated by atomic checkGuardianWhitelist call.

### 2.5 Debt / readability
- No debt field in read paths → null [INFERENCE].
- Readable: getGuardianRoot #L206, getActiveGuardians #L201, unit price via _getCurrentPrice #L627.

### 2.6 Governance / deployment
- Auth2Step owner/authority; constructor params from factory #L93-L116.
- Oracle registry trust: Spearbit §5.2.7 (no delay on adding oracles), §5.2.8 (owners could accept unexpected oracle).
- Upgradeability and factory details: not read [UNVERIFIED].

### 2.7 Audits (aera/v3/audits/spearbit/, text via pdftotext)
- 2025-06-05 (14 High/Med by grep). Read: §5.3.2 (above); §5.2.7/§5.2.8 (oracles); §5.3.16 fees overcharged by delayed price updates; §5.3.17 front/back-running of price updates (NAV timing); §5.3.9 / §5.2.4 fee change / lost fees; §5.2.10 renounce ownership; §5.3.19 setUnitPrice on pause branch; §5.3.18 rounding.
- 2025-06-25 (4 High/Med) and 2026-04-15 (3 High/Med): grep only [UNVERIFIED].

### 2.8 Proposed grades (Aera)
- declared 0 (no change): no positions; guardian roots only. BaseVault.sol#L126-L151.
- nav 0 (no change): pushed unit price with bands; holdings valued via oracle registry, not positions. PriceAndFeeCalculatorV2.sol#L171, #L605-L620, #L650-L662.
- granularity 2 (no change, PROVISIONAL): merkle + hooks; leaf structure not read [UNVERIFIED].
- single 0 (no change): independent roots (guardian, accountant, oracle registry). BaseVault.sol#L154; PriceAndFeeCalculatorV2.sol#L171.
- complete 0 (no change): pushed price; missing oracle → revert, not silent omission. PriceAndFeeCalculatorV2.sol#L500-L515.
- debt, isolation null (no change).
- trust 1 (no change): owner/authority, guardians, whitelist, oracle registry (§5.2.7/§5.2.8). BaseVault.sol#L523-L537.
- readable 0 (no change): one unit price per vault. PriceAndFeeCalculatorV2.sol#L627.

---------------------------------------------------------------------
## 3. MELLOW flexible-vaults

### 3.1 Declaration
- Layer A, call allow-list: src/permissions/Verifier.sol. Types: ONCHAIN_COMPACT (who, where, selector; #L59-L63 via compactCallHashes), MERKLE_EXTENDED (exact call hash, #L115), MERKLE_COMPACT (who, where, selector, #L119), CUSTOM_VERIFIER (external ICustomVerifier, #L121-L122). allowCalls #L146, disallowCalls #L162, setMerkleRoot #L140.
- Layer B, asset/subvault allow-lists in RiskManager (src/managers/RiskManager.sol): allowSubvaultAssets #L169, disallowSubvaultAssets #L185, setSubvaultLimit #L161, setVaultLimit #L201.

### 3.2 NAV
- Balances are pushed deltas, not read from chain. modifySubvaultBalance #L237-L256 converts change to shares at oracle price at push time (convertToShares #L109-L121); reverts NotAllowedAsset if asset not allowed. Called from VaultModule _pushAssets/_pullAssets (src/modules/VaultModule.sol#L140-L156).
- modifyVaultBalance #L225 and modifyPendingAssets #L207: called by queues (DepositQueue, RedeemQueue, SyncDepositQueue, Signature queues).
- Oracle src/oracles/Oracle.sol: submitReports #L103 (SUBMIT_REPORTS_ROLE). _handleReport #L184-L198: TooEarly within timeout unless suspicious. _validatePrice #L201-L225: first report (prev 0) → suspicious; deviation over max → revert InvalidPrice (#L212-L213); previously suspicious stays suspicious (#L215-L217); over suspicious thresholds → accepted but flagged. acceptReport #L124-L134 clears flag only on exact (price, timestamp).
- convertToShares reverts InvalidReport if suspicious or price 0.
- NAV = accumulated shares from pushes; not re-read from positions [INFERENCE: not fully traced].
- Computed at each push/queue action. Gas: per-subvault state reads, no position loop [INFERENCE].
- Revert handling: suspicious asset → conversions revert for that asset only (per-asset DoS until acceptReport). Out-of-band price → hard revert (fail-closed).

### 3.3 Permissions
- Granularity by type: COMPACT = selector only; MERKLE_EXTENDED = exact calldata; ERC20Verifier (src/permissions/protocols/ERC20Verifier.sol#L17-L43) = approve/transfer, value 0, recipient role-gated, amount UNCONSTRAINED; BitmaskVerifier (src/permissions/BitmaskVerifier.sol) per-byte mask [UNVERIFIED full logic].
- Who: vault CALLER_ROLE (Verifier #L59-L70). CallModule.call #L12-L17 → verifier.verifyCall(_msgSender(), where, value, data, payload).
- Roles via MellowACL: ASSET_ROLE, RECIPIENT_ROLE, CALLER_ROLE.

### 3.4 Link declaration ↔ accounting
- Partial: allowedAssets per subvault gates balance pushes (RiskManager #L247-L249). Asset-level only; no call or amount binding.
- Not linked: ERC20 amounts free within allowed recipients. Whether subvault-initiated transfers always update RiskManager is [UNVERIFIED] (path not traced).
- Unvalued position: an asset needs allowSubvaultAssets + oracle report before share conversion works. Whether a subvault can hold an unreported asset without revert is [UNVERIFIED].

### 3.5 Debt / readability
- No debt field in RiskManager State → null [INFERENCE].
- Readable on-chain: vaultState #L69, subvaultState #L89, allowedAssets #L94, Oracle getReport #L64. Per subvault/asset, in shares.

### 3.6 Governance / deployment
- Initializer pattern (Verifier #L128, Oracle #L84, RiskManager #L143) + src/factories/Factory.sol suggest proxy components per fund [INFERENCE; upgrade admin not read].
- Oracle security params: setSecurityParams #L143 (SET_SECURITY_PARAMS_ROLE).

### 3.7 Audits (audits/)
- 202508_Sherlock (read). H-1 Consensus signer duplicates; H-2 RedeemQueue batch/claim mismatch; H-3 native withdrawal; H-4 protocol fee multi-accrual; H-5 performance fee; H-6 RedeemQueue redeems; M-1 ShareManager whitelist inverted; M-2 ETH via SignatureRedeemQueue; M-3 stETH rounding; M-4 fee compounding; M-5 cancelDepositRequest reverts; M-6 lockup bypass; M-7 redemption DoS; M-8 perpetual lock; M-9 stuck stETH.
- M-1 status: report's flawed line `if (info.canTransfer || !to.canTransfer)` is NOT present. Repo src/managers/ShareManager.sol#L139 reads `if (!info.canTransfer || !toInfo.canTransfer) revert`, which reverts if EITHER side not whitelisted. Report recommends revert only if BOTH not whitelisted. Intent [UNVERIFIED].
- Others not read [UNVERIFIED]: 202509_Nethermind (deployment verification), 202508–202606 Nethermind dirs, 202605_Nethermind NM_0930_MELLOW.pdf, 202607_MixBytes (SyncRedeemQueue).

### 3.8 Proposed grades (Mellow)
- declared 1 (no change): asset allow-lists + call allow-lists, no position declaration. RiskManager.sol#L169; Verifier.sol#L146.
- nav 0 (no change): pushed share deltas at push-time oracle price. RiskManager.sol#L237-L256; Oracle.sol#L184-L226.
- granularity 2 (no change): MERKLE_EXTENDED is exact; COMPACT/ERC20 leave amounts free. Verifier.sol#L115-L119; ERC20Verifier.sol#L17-L43. Weaker than the grade suggests on the compact/custom path.
- single 0 (no change): Verifier and RiskManager separate roles. Verifier.sol#L59; RiskManager.sol#L169.
- complete 0 (no change): pushed balance may not track every value move [UNVERIFIED path]. VaultModule.sol#L140-L156.
- debt, isolation null (no change).
- trust 1 (no change): role-based (CALLER_ROLE, ASSET_ROLE, RECIPIENT_ROLE, SUBMIT_REPORTS_ROLE). Oracle.sol#L103; ERC20Verifier.sol#L17.
- readable CHANGE 0→1: per-subvault and per-asset state readable on-chain, still no per-position data, in shares. RiskManager.sol#L69-L94.

---------------------------------------------------------------------
## 4. Cross-system notes
- All three: declaration ≠ accounting. Permission (merkle/verifier/guardian root) is separate from NAV (pushed rate/price/balance).
- Veda base: rate bounded per update; amounts unconstrained; NAV checked only in aggregate (totalSupply) per batch.
- Aera: price pushed with band; holdings via oracle at spot; missing oracle reverts (fail-closed) [INFERENCE].
- Mellow: NAV accumulated in shares from VaultModule/queues at push-time price. MERKLE_EXTENDED is the strongest per-call control, but compact/custom verifiers leave amounts free.
- FundConfig relevance: none derives permission and accounting from one declaration. Mellow RiskManager allowedAssets is the nearest analogue (asset-level only).

## 5. [UNVERIFIED] register
- Veda: audit/ PDFs unread; production variant (base vs YieldStreaming) unknown; rate-pusher off-chain; incidents not searched.
- Aera: leaf format; 2025-06-25 and 2026-04-15 findings (grep only); upgradeability and factory.
- Mellow: whether subvault transfers always update RiskManager; BitmaskVerifier full logic; M-1 intent; unread Nethermind/MixBytes reports; upgrade admin for proxies.
- No gas measurements run. Gas statements are [INFERENCE].
