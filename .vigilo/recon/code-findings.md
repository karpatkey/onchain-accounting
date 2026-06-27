# Phase 1 Reconnaissance: onchain-accounting

**Date**: 2026-06-27  
**Scope**: 124 contracts under `src/`, 12 deploy scripts under `script/deploy/`  
**Protocol Type**: Portfolio NAV accounting (read-mostly oracle aggregation) + cross-chain bridge (escrow/lock-release)

---

## 1. Project Architecture

### 1.1 Core Components

| Component | Files | Purpose | Mutable? |
|-----------|-------|---------|----------|
| **NAVCalculator** | `src/nav/NAVCalculator.sol`, `src/nav/INAVCalculator.sol`, `src/nav/NAVRegistryLib.sol` | UUPS-upgradeable core: registers assets, price feeds, balance adapters; computes portfolio NAV | Yes (proxied, MANAGER + DEFAULT_ADMIN control) |
| **Prices** | `src/prices/Prices.sol`, `src/prices/IPrices.sol`, `src/prices/PriceFeedLib.sol` | Oracle aggregation: multiple feeds per asset, Chainlink staleness gates, L2 sequencer uptime | Yes (abstract base; storage in NAVCalculator) |
| **Balances** | `src/balances/Balances.sol`, `src/balances/IBalances.sol` | Balance adapter registry: plain adapters + meta-adapters (ADR 0010) | Yes (abstract base; registry in NAVCalculator) |
| **BridgeEscrow** | `src/bridge/BridgeEscrow.sol`, `src/bridge/IBridgeEscrow.sol` | UUPS-upgradeable escrow: holds assets in transit, tracks invoices, authenticated releases | Yes (proxied, DEFAULT_ADMIN/MANAGER) |
| **BridgeAdapter base** | `src/bridge/BridgeAdapter.sol`, `src/bridge/IBridgeAdapter.sol` | Non-upgradeable: protocol-specific bridge logic (CCIP, Across, CCTP, Stargate, Gnosis, Superchain) | Immutable post-deploy |

### 1.2 Inheritance & Type Hierarchy

```
AccessControl (OZ)
├── NAVCalculator (extends Initializable, UUPSUpgradeable, AccessControlUpgradeable, Prices, Balances)
├── BridgeEscrow (extends AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard, PausableUpgradeable)
├── BridgeAdapter (abstract; extended by CcipBridgeAdapter, CctpBridgeAdapter, etc.)
├── AssistedBalanceAdapter (abstract; extended by MerklRewardsBalanceAdapter, EtherFiWithdrawalQueueBalanceAdapter, etc.)
└── ERC20DefaultBalanceAdapter (immutable singleton, auto-deployed)

IBalanceAdapter (interface)
├── ERC20DefaultBalanceAdapter
├── MetaBalanceAdapter (abstract; extended by AaveV3InstancesMetaBalanceAdapter, MorphoVaultsMetaBalanceAdapter, etc.)
└── Individual plain adapters (LidoWithdrawalQueueBalanceAdapter, etc.)

IPositionDescribable (interface; labels source)
├── MetaBalanceAdapter
├── ERC20DefaultBalanceAdapter
├── MerklRewardsBalanceAdapter
└── Protocol-specific adapters

Library (DELEGATECALL, deterministic CREATE2)
├── PriceFeedLib (price selection, NAV compute, health checks)
├── NAVRegistryLib (asset & adapter registry mutations, ERC20Default factory)
├── InvoiceDataLib (bridge invoice encode/decode/checksum)
```

### 1.3 Balance Adapter Categories

#### Plain Adapters (124 files → ~17 plain + 25 meta + 6 assisted)
- **Simple ERC20**: `ERC20DefaultBalanceAdapter` (singleton, registered auto at NAVCalculator.initialize)
- **Wrapped tokens**: `ERC4626WrapBalanceAdapter`, `EthenaCooldownBalanceAdapter` (LST unstaking queues: Lido, Stader, Kelp)
- **Protocol-specific**: `SparkLendBalanceAdapter`, `AaveV3SafetyModuleBalanceAdapter`, `CapBalanceAdapter` (stablecoin CDP)

#### Assisted Adapters (mutable per ADR 0007 & 0014)
- **MerklRewardsBalanceAdapter**: Caches per-(user, token) cumulative allocations; verified against live Merkl Distributor root. Mutable storage: `allocations[user][token]` (CachedAllocation: amount, root, submittedAt). Access: ASSISTANT_ROLE. Trust model: assistant feeds proof, on-chain verification prevents over-reporting.
- **EtherFiWithdrawalQueueBalanceAdapter**: Caches per-account request *coordinates* (not amounts). Values live on-chain + re-verified per read. Mutable: request queue indices. Access: ASSISTANT_ROLE.
- **StakeWiseV3ExitQueueBalanceAdapter**: Same as ether.fi — coordinate-only cache, live valuation per read.
- **NexusMutualStakingPoolsBalanceAdapter**: Pool-level data cache (mutable, ASSISTANT_ROLE gated).

#### Meta-Adapters (one immutable adapter → N instances, ADR 0010)
- Instances are *governed* via `NAVCalculator.addMetaInstances` / `removeMetaInstances` (MANAGER-gated; mutable on NAVCalculator storage, not adapter itself)
- Examples: `AaveV3InstancesMetaBalanceAdapter`, `MorphoVaultsMetaBalanceAdapter`, `CompoundV3CometsMetaBalanceAdapter`, `FluidVaultsMetaBalanceAdapter`, `UniswapV2PoolsMetaBalanceAdapter`, `UniswapV3PoolsMetaBalanceAdapter` (assisted), `BalancerV2PoolsMetaBalanceAdapter`, etc.
- Adapters themselves are immutable; instance set lives on NAVCalculator

### 1.4 External Libraries & Dependencies
- **@openzeppelin/contracts-upgradeable**: UUPSUpgradeable, AccessControlUpgradeable, Initializable, ReentrancyGuard, PausableUpgradeable
- **@openzeppelin/contracts**: ERC165Checker, EnumerableMap, EnumerableSet, SafeERC20, IERC20 (standard interfaces)
- **@chainlink/**: AggregatorV3Interface (latestRoundData), L2 uptime feed
- **Custom feeds**: `BaseCustomPriceFeed.sol` extended by 28 protocol-specific feeds (wstETH, stETH cross-rate, sDAI, sUSDs, osToken, NXM, cbETH, rsETH, weETH, etc.)

---

## 2. Main Execution Flows

### 2.1 NAV Computation Entry → Exit Flow

#### Entry (User Queries NAV)
```
User → getAccountNav(account, quoteAsset)
       ↓
NAVCalculator.getAccountNav
  ↓ DELEGATECALL
  PriceFeedLib.computeNav(
    _priceOracles,          // asset → [PriceFeedConfig]
    _assetIndex,            // asset → 1-based index
    _registeredAssets,      // [Asset(address, symbol, decimals)]
    getAllAdapters(),       // [adapter addresses]
    _metaInstanceTotal,     // NAV buffer sizing
    account,
    quoteAsset,
    _isSequencerDown(),     // L2 uptime check
    _nativeTokenSymbol
  )
```

#### Process (PriceFeedLib — DELEGATECALL, heavy lifting)
1. **Fetch balances per adapter**:
   - Loop `getAllAdapters()` → for each adapter:
   - Call `adapter.getAdapterPositions(account, assetFilter)` → returns `PositionBalance[]`
   - PositionBalance: `{ balanceAsset, balanceAdapter, amount, isDebt, protocolId, positionId, positionKind }`
   - Extract unique assets from all positions

2. **Cache prices** (feed selection per asset):
   - For each unique asset call `_selectFeed(asset)`:
     - Loop asset's `_priceOracles[asset][]` (multiple PriceFeedConfig per asset for redundancy)
     - Per feed: fetch latest price + check staleness (Chainlink heartbeat gate)
     - Return freshest non-stale feed; if all stale, return first + stale=true
     - Add L2 sequencer downtime check (`checkL2SequencerUptime()`)

3. **Compute NAV**:
   - For each PositionBalance:
     - Look up asset price (cached)
     - Multiply amount × price → value
     - Sum by positionKind (Supplied/Staking = +NAV; Borrowed/Debt = −NAV)
   - If quoteAsset ≠ USD (address(0)): convert USD value → quote asset value (fallback to USD if quote feed stale)
   - Return NAV struct: `{ value, quoteAsset, timestamp, stalePriceAssets[], sequencerDown, quoteAssetStale }`

#### Exit (Return to Caller)
- NAV value, quote asset, staleness flags, sequencer status
- Full Position[] available via `getAccountPositions` (enriches PositionBalance[] with pricing)

#### Key Invariants
- **balanceAsset always positive**: isDebt flag implies sign
- **Adapters are immutable post-deploy** (except assisted adapters' ASSISTANT_ROLE-gated caches & NAVCalculator's meta-instance gov)
- **Price feeds backed by Chainlink + custom feeds**: multiple feeds → redundancy via freshest non-stale

---

### 2.2 Bridge Flow (Assets Across Chains)

#### Deposit & Bridge (Source Chain)
```
User → BridgeEscrow.depositAndBridge(
  destinationChainId,
  assetSymbol (bytes6),
  amount,
  adapter (e.g. CCIPBridgeAdapter)
)
  ↓
BridgeEscrow._depositAndBridge (nonReentrant, whenNotPaused)
  1. Pull funds from sender (ERC20.safeTransferFrom or msg.value for native)
  2. Fee-on-transfer safe: measure balBefore/balAfter
  3. Assign per-account nonce (monotonic, unique invoice identity)
  4. InvoiceDataLib.encode → invoice struct: (sourceChainId, destinationChainId, account, asset, amount, nonce, timestamp, checksum24)
  5. Store invoice: invoices[invoiceHash] = Invoice(status=BRIDGING, ...)
  6. Track in-transit balance: _inTransitBalances[account][asset] += amount
  7. Hand funds to adapter.bridge(messagePayload) (funds + protocol-specific message)
  ↓
BridgeAdapter._bridge (adapter-specific implementation)
  • CCIP: send message via router.ccipSend()
  • Across: call SpokePool.deposit()
  • Stargate: call Router.swap()
  • etc.
```

#### Release (Destination Chain)
```
Bridge protocol → BridgeAdapter.receiveMessage(...) or similar
  ↓ (adapter authenticates inbound message + source sender)
  ↓
BridgeAdapter.completeBridge(messagePayload) [MANAGER-gated]
  1. Adapter protocol-specific: _completeBridge(...) decodes/validates
  2. Call BridgeEscrow.releaseByInvoiceId(messagePayload)
  ↓
BridgeEscrow.releaseByInvoiceId (external, ADAPTER_ONLY, funded pass-through per ADR 0012)
  1. Validate checksum + replay guard (completedInvoices[invoiceHash])
  2. Validate destination chain matches
  3. Adapter must supply funds in SAME call:
     - For ERC20: adapter.call IERC20(asset).transferFrom(adapter, escrow, amount)
     - For native: msg.value == amount, then transfer to account
  4. Forward funds to account: account.call{value}() or safeTransferFrom
  5. Mark completedInvoices[invoiceHash] = true (replay prevention)
  ↓
Account receives funds
```

#### Key Invariants (ADR 0012)
- **Funded pass-through**: Escrow never pays from pre-existing balance; adapter supplies funds per-invoice per-call
- **Replay guard**: completedInvoices[hash] prevents double-release
- **No fallback dispatcher**: No unauthenticated payable(). releaseByInvoiceId ONLY callable by authorized adapter (prevents C1 forged-payload drain)
- **Checksum verification**: Encodes invoiceId, amount, timestamp, nonce → 24-byte checksum; verified on-chain

---

### 2.3 Asset & Price Feed Registration (MANAGER-gated)

```
MANAGER → NAVCalculator.registerAsset(asset, priceFeed, priceType, chainlinkHeartbeat)
  1. Fetch asset decimals/symbol (ERC20Metadata or native)
  2. Store in _registeredAssets, _assetIndex
  3. Add first price feed via NAVRegistryLib.registerPriceFeed
  4. Add asset to ERC20DefaultBalanceAdapter inclusion list
  5. Emit AssetRegistered

MANAGER → NAVCalculator.addPriceFeed(asset, priceFeed, priceType, chainlinkHeartbeat)
  1. Validate priceFeed address non-zero
  2. Add feed to _priceOracles[asset][new]
  3. Prevent duplicates (reverts PriceFeedAlreadyRegistered)

MANAGER → NAVCalculator.addBalanceAdapters(adapters[])
  1. Validate each adapter implements IBalanceAdapter (ERC165)
  2. Reject if meta-adapter (implements IMetaBalanceAdapter) → use addMetaBalanceAdapter
  3. Register in _globalAdapters, _adapterTypes[Custom]
  4. Emit BalanceAdapterAdded

MANAGER → NAVCalculator.addMetaBalanceAdapter(adapter, instances[])
  1. Validate adapter implements IMetaBalanceAdapter
  2. Register adapter
  3. Seed instances in _metaInstances[adapter] = instances[]
  4. Check for duplicates (revert DuplicateMetaInstance)

MANAGER → NAVCalculator.addMetaInstances(adapter, newInstances[])
  1. Validate adapter is registered meta-adapter
  2. Append instances (check duplicates + within-batch repeats)

MANAGER → NAVCalculator.removeMetaInstances(adapter, instances[])
  1. Remove from _metaInstances[adapter]
```

---

### 2.4 Assisted Adapter Update Flow (Merkl Example)

```
ASSISTANT_ROLE (OIV Safe) → MerklRewardsBalanceAdapter.submitProof(
  user,
  token,
  cumulativeAmount,
  merkleProof[]
)
  1. Fetch Distributor.getMerkleRoot() (live on-chain)
  2. Verify merkleProof against current root
  3. Check amount ≥ cached amount (monotonic invariant)
  4. Store allocations[user][token] = CachedAllocation(cumulativeAmount, root, uint64(now))
  5. Track user's tokens for enumeration
  6. Emit AllocationCached

User → NAVCalculator.getAccountNav(user, quoteAsset)
  → PriceFeedLib.computeNav
    → MerklRewardsBalanceAdapter.getAdapterPositions(user, assetFilter)
      1. Enumerate _userTokens[user]
      2. For each token: check allocations[user][token].root == Distributor.getMerkleRoot()
      3. If root stale: return 0 (conservative)
      4. Claimed = Distributor.claimed(user, token)
      5. Pending = cached.cumulativeAmount − claimed
      6. Return PositionBalance[] with amount=pending, isDebt=false, positionKind=Rewards
```

**Trust model**: Assistant can only *under-report* (cache stale, root changes → 0 returned; proof fraud → revert)

---

## 3. Asset Custody & Fund Movement

### 3.1 Where Real Funds Live
| Contract | Custody | Immutable? | Access Control |
|----------|---------|-----------|-----------------|
| **BridgeEscrow** | Holds ERC20/native in transit during bridge (source & dest) | No (UUPS proxy) | DEFAULT_ADMIN_ROLE, MANAGER_ROLE |
| **Balance adapters** | Read-only views; no custody | Yes (except assisted caches) | None (read-only) or ASSISTANT_ROLE (cache update) |
| **Price feeds** | Read-only; no custody | Yes | None (view-only) |
| **NAVCalculator** | None; proxy-only orchestration | No (UUPS) | DEFAULT_ADMIN_ROLE, MANAGER_ROLE |

### 3.2 Fund Flow
1. **Deposit**: User → BridgeEscrow (escrow becomes temp custodian) → BridgeAdapter (hands off to bridge protocol)
2. **Bridge transit**: Bridge protocol (e.g., Aave Portal, Portal Token, Stargate Router)
3. **Release**: BridgeAdapter receives inbound message → calls BridgeEscrow.releaseByInvoiceId → User gets funds

### 3.3 Mutable State Summary
| Contract | Mutable State | Purpose | Gated By |
|----------|---------------|---------|----------|
| NAVCalculator | _registeredAssets, _priceOracles, _globalAdapters, _metaInstances | Registry mutations | MANAGER |
| BridgeEscrow | invoices[], completedInvoices[], _inTransitBalances, _assetRegistry | Invoice tracking, replay guard, in-transit accounting | MANAGER, authorized adapters |
| MerklRewardsBalanceAdapter | allocations[] | Proof cache | ASSISTANT_ROLE (verified on-chain) |
| EtherFiWithdrawalQueueBalanceAdapter | Request queue indices | Queue coordinates (not amounts) | ASSISTANT_ROLE (values read live) |
| ERC20DefaultBalanceAdapter | _supportedAssets (EnumerableSet) | Inclusion list (asset filter) | NAVCalculator only |

---

## 4. Trust & Privilege Surface

### 4.1 Role Model

#### DEFAULT_ADMIN_ROLE (Strongest — Security Council Safe)
- **NAVCalculator**: `initialize()`, `setChainlinkL2SequencerUptimeFeed()`, `_authorizeUpgrade()` (UUPS)
- **BridgeEscrow**: `initialize()`, `pauseUnpause()`, `_authorizeUpgrade()`
- **BridgeAdapter**: `setTrustedRemoteAdapter()`, `_authorizeUpgrade()`
- **AssistedBalanceAdapter**: `grantRole(ASSISTANT_ROLE, ...)` / `revokeRole(...)`

#### MANAGER Role (Operational — Security Council Safe post-deploy 07)
- **NAVCalculator**: `registerAsset()`, `addPriceFeed()`, `addBalanceAdapters()`, `addMetaBalanceAdapter()`, `addMetaInstances()`, `removeMetaInstances()`, `excludeAssetFromDefaultAdapter()`, `includeAssetInDefaultAdapter()`, `unregisterAsset()`, `setChainlinkL2SequencerGracePeriod()`, `removePriceFeedAt()`, `removePriceFeed()`, `removeBalanceAdapters()`
- **BridgeEscrow**: `cancelInvoice()`, `recoverStuckAssets()`, `registerAsset()`, `authorizeAccount()`, `revokeAccount()`, `authorizeAdapter()`, `revokeAdapter()`
- **BridgeAdapter**: `completeBridge()`, `recoverStuckAssets()`, `proveWithdrawal()`, `setTrustedRemoteAdapter()` (in BridgeAdapter, same as DEFAULT_ADMIN—needs review)

#### ASSISTANT_ROLE (Data-feeding — OIV Safe or delegated account)
- **MerklRewardsBalanceAdapter**: `submitProof()`, `clearAllocation()`
- **EtherFiWithdrawalQueueBalanceAdapter**: `submitWithdrawalRequest()`, `clearWithdrawalRequest()`
- **StakeWiseV3ExitQueueBalanceAdapter**: `submitExitRequest()`, `clearExitRequest()`

### 4.2 Access Control Risks (Phase 2 focus)

#### High-Touch Mutations (MANAGER)
1. **Asset registration**: `registerAsset()` — can register any ERC20 as portfolio-trackable
2. **Price feed swaps**: `removePriceFeed()` — can remove last feed (reverts), but can remove N−1; if sole feed malicious, exploiter can orphan asset
3. **Adapter addition/removal**: `addBalanceAdapters()` — can add arbitrary adapter; if contract at address is malicious IBalanceAdapter, could return forged PositionBalance[]
4. **Meta-instance governance**: `addMetaInstances()` — can add arbitrary instance coordinates; adapter's `_instancePositions` must handle gracefully (fail isolated per-instance)

#### Assisted Adapter (ASSISTANT_ROLE)
1. **Merkl cache**: submitProof verifies against live Distributor root on-chain → cannot over-report; stale cache → under-report. Risk: cache not updated → NAV under-counts
2. **Queue adapters (ether.fi, StakeWise)**: caches only *coordinates*, not amounts. Amounts read live per-call + ownership re-verified. Risk: if oracle/queue contract broken, cache can report stale/wrong queue position
3. **Trust assumption**: Assistant is honest; if compromised, can under-report but not over-report (or flood with requests if queue adapter)

### 4.3 Upgrade Surface

- **NAVCalculator**: UUPS proxy at `NAVCalculatorProxy`. Upgrade path: DEFAULT_ADMIN_ROLE calls `upgradeTo(impl)`. Old impl discarded, new impl initializer skipped (already initialized). Storage layout preserved via 50-slot gap.
- **BridgeEscrow**: UUPS proxy at `BridgeEscrowProxy`. Same UUPS pattern.
- **LibraryPins**: `PriceFeedLib`, `NAVRegistryLib` are deterministic CREATE2 contracts (pinned in `foundry.toml`), not proxies. If new version needed, new deploy + redeploy NAVCalculator to reference new address.

---

## 5. Protocol Type & External Integrations

### 5.1 Protocol Type
**Hybrid**:
- **Portfolio NAV aggregation**: Multi-adapter balance fetching + multi-feed price oracle + summation → NAV snapshot
- **Cross-chain bridge**: Lock-release pattern with escrow, invoices, replay guards, per-protocol adapters

### 5.2 External Read Dependencies (Adapters — View-Only)

| External Contract | Adapter | Type | Risk |
|-------------------|---------|------|------|
| Merkl Distributor | MerklRewardsBalanceAdapter | On-chain merkle root verification | Root can change; stale cache returns 0 (conservative) |
| Aave V3 Pool / DataProvider | AaveV3InstancesMetaBalanceAdapter | Direct reserve queries | Broken or removed pool → isolated per-instance fail |
| Morpho lending contracts | MorphoVaultsMetaBalanceAdapter, MorphoMarketsMetaBalanceAdapter | Direct vault/market queries | Malicious vault → forged PositionBalance (adapter can't prevent) |
| Curve pools & gauges | CurvePoolsMetaBalanceAdapter, CurveGaugesMetaBalanceAdapter | Direct reserves + gauge balances | Pool code can lie about reserves |
| Uniswap V3 PositionManager | UniswapV3PoolsMetaBalanceAdapter (assisted) | NFT balances + fee calculations | Malicious pool → wrong fee estimation |
| Balancer pools & gauges | BalancerV2PoolsMetaBalanceAdapter, BalancerV3PoolsMetaBalanceAdapter | Direct reserve queries + weight calculations | Malicious pool → wrong balance calculation |
| Compound V3 Comet | CompoundV3CometsMetaBalanceAdapter | Direct comet queries | Broken comet → isolated fail |
| Chainlink oracles | Prices.latestPrice via _selectFeed | Price + timestamp via AggregatorV3Interface.latestRoundData() | Stale/malicious feed: multi-feed redundancy gates it; heartbeat staleness checks |
| Custom price feeds (28 feeds) | BaseCustomPriceFeed extensions | Custom protocol-specific pricing logic | Logic bugs in feed → price wrong; if sole feed → NAV wrong |
| L2 sequencer uptime | Prices.checkL2SequencerUptime | Chainlink uptime feed (L2 only) | Uptime feed down → sequencerDown=true flagged (defensive) |

### 5.3 External Write Dependencies (Bridge Adapters — Call Out)

| External Protocol | Bridge Adapter | Flow | Risk |
|-------------------|----------------|------|------|
| Aave Portal | AcrossBridgeAdapter | Calls SpokePool.deposit() | Spoke misconfigured; message routing issues |
| Chainlink CCIP Router | CcipBridgeAdapter | Calls router.ccipSend() | CCIP message routing; callback authentication |
| Circle CCTP Messenger | CctpBridgeAdapter | Calls messenger.depositForBurn() + relay.receiveMessage() | CCTP domain/nonce tracking |
| Stargate Router | StargateBridgeAdapter | Calls router.swap() | Pool imbalance; slippage; cross-chain messaging |
| Gnosis Arbitrary Message Bridge (AMB) | GnosisBridgeAdapter | Calls AMB.requireToPassMessage() | Gnosis side-chain state; bridge validator set |
| Superchain Messenger (OP/Base) | SuperchainBridgeAdapter | Calls L1CrossDomainMessenger.sendMessage() | OP/Base cross-chain message queue |

**Key Risk**: Bridge adapter must authenticate inbound protocol message + source sender. If adapter's `_completeBridge` does not verify message proof (CCIP finality, CCTP attestation, Stargate relayer, etc.), attacker can forge payloads → drain escrow.

---

## 6. Notable Patterns & Hot Spots

### 6.1 Replay Guards & Invoice Tracking
- **Location**: `src/bridge/BridgeEscrow.sol:56–93` (invoice storage), `src/bridge/InvoiceDataLib.sol` (checksum)
- **Pattern**: Per-invoice checksum (24-byte hash of invoiceId + amount + timestamp + nonce); `completedInvoices[invoiceHash]` tracks completion
- **Risk**: If checksum collision possible or InvoiceDataLib.calculateChecksum() logic wrong, replay attack
- **Phase 2 check**: Verify InvoiceDataLib.calculateChecksum() uniqueness (likely keccak256 truncation; ok if collision unlikely at practical scale)

### 6.2 Assisted Adapter Mutable Cache (Trust-Minimized but Not Immutable)
- **Location**: `src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol:56`, `src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueBalanceAdapter.sol` (similar)
- **Pattern**: ASSISTANT_ROLE-gated state mutations; verifiable on-chain (Merkl: proof + root check; exit-queues: live value + ownership re-check)
- **Risk**: If assistant account compromised → stale cache → under-reported NAV (acceptable per ADR 0007); if assistant never updates → NAV drift
- **Phase 2 check**: Verify assistant _cannot_ over-report (proof verification logic, queue coordinate validation)

### 6.3 Multi-Feed Redundancy + Staleness
- **Location**: `src/prices/PriceFeedLib.sol:62–150` (selectFeed core)
- **Pattern**: Loop asset's feeds; pick freshest non-stale; if all stale → return first + stale=true; `chainlinkHeartbeat` gate + L2 sequencer uptime check
- **Risk**: If Chainlink feed offline + custom feed malicious + adapter stale → NAV computed on stale/wrong price
- **Phase 2 check**: Verify `_selectFeed` correctly compares timestamps + applies heartbeat gate (likely sound but needs manual audit)

### 6.4 Meta-Adapter Instance Per-Instance Isolation
- **Location**: `src/balances/MetaBalanceAdapter.sol:136–161` (_positionsForInstances fan-out with try-catch)
- **Pattern**: Try-call each instance's `_instancePositions()`; catch errors and continue. One bad instance does NOT zero whole batch
- **Risk**: If bad instance's catch absorbs *all* reverts (including SELFDESTRUCT or intentional panic), batch silently loses that instance's positions → under-reported NAV
- **Phase 2 check**: Verify catch scope (should catch all, including low-level reverts)

### 6.5 DELEGATECALL Libraries for EIP-170 Budget
- **Location**: `src/nav/NAVCalculator.sol:250` (PriceFeedLib.computeNav call), `src/nav/NAVRegistryLib` (registry mutations)
- **Pattern**: NAVCalculator stays <24KB by delegating heavy loops (adapter scanning, price caching, position aggregation) to external library
- **Risk**: If library storage layout or assumptions misaligned → state corruption (though library is deterministic CREATE2, so address stable)
- **Phase 2 check**: Verify DELEGATECALL storage mutability is intended (libraries should read/write same slots as NAVCalculator)

### 6.6 Bridge Adapter Message Authentication
- **Location**: `src/bridge/adapters/CcipBridgeAdapter.sol`, `src/bridge/adapters/CctpBridgeAdapter.sol` (protocol-specific)
- **Pattern**: Adapter receives protocol callback; validates message + source sender; calls `BridgeEscrow.releaseByInvoiceId(messagePayload)`
- **Risk**: If adapter's message validation is weak (e.g., missing source chain check, insufficient nonce tracking), attacker can forge/replay messages → escrow release on dest chain without matching deposit
- **Phase 2 check**: Verify each adapter's `_completeBridge` validates protocol message proof + source

### 6.7 ERC20DefaultBalanceAdapter Inclusion List Gate
- **Location**: `src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol:58–76`
- **Pattern**: Only reports balances for assets in `_supportedAssets` EnumerableSet; mutated via `addSupportedAsset` (NAVCalculator-only external, checks `isAssetRegistered`)
- **Risk**: If asset not in set → wallet balance not reported (under-count); if asset is compromised ERC20 (reentrant, non-standard), adapter still reports (but that's user's problem, not adapter's)
- **Phase 2 check**: Verify NAVCalculator always adds asset to default adapter on `registerAsset` (line 110 does this)

### 6.8 Deploy Script Role Handoff (07_TransferAdminToSecurityCouncil)
- **Location**: `script/deploy/07_TransferAdminToSecurityCouncil.s.sol:70–111`
- **Pattern**: Deployer EOA (temp holder) grants DEFAULT_ADMIN_ROLE + MANAGER to Security Council Safe, then revokes + renounces
- **Risk**: If script skipped or fails mid-way → deployer retains admin (centralization risk); if Safe address wrong → admin handed to wrong account
- **Phase 2 check**: Verify all 7 deploy scripts are idempotent and script 07 verifies Safe address is non-zero + ≠ deployer

### 6.9 Custom Price Feeds (28 Contracts)
- **Location**: `src/prices/protocols/` (wstETH, sDAI, CrossRate, NXM, osToken, etc.)
- **Pattern**: Each extends BaseCustomPriceFeed; implements custom logic (e.g., stETH/wstETH ratio, sDAI/DAI rate, ETH/osToken)
- **Risk**: Logic bugs in feed (e.g., wrong ratio calculation, division by zero, infinite loop) → price wrong → NAV wrong
- **Phase 2 check**: Audit each feed's `getLatestPrice()` logic (likely straightforward but field-specific risk)

### 6.10 Pause Gates (ReentrancyGuard + PausableUpgradeable)
- **Location**: `src/bridge/BridgeEscrow.sol:31–36` (PausableUpgradeable, ReentrancyGuard)
- **Pattern**: `depositAndBridge` and `releaseByInvoiceId` both `whenNotPaused + nonReentrant`
- **Risk**: If paused → no bridge deposits/releases (good for emergency); MANAGER can pause/unpause
- **Phase 2 check**: Verify pause is MANAGER-gated + can be toggled to resume

---

## 7. Deployment & Configuration

### 7.1 Deploy Script Sequence

| Script | Stage | What | Broadcast | Dependencies |
|--------|-------|------|-----------|--------------|
| `01_DeployImplementations.s.sol` | Impl layer | Deploy NAVCalculator impl, PriceFeedLib, NAVRegistryLib (CREATE2) | Deployer EOA | foundry.toml salts |
| `01_2_DeployNAVImplementation.s.sol` | Impl layer (alt path) | Deploy NAVCalculator impl (separate script if needed) | Deployer EOA | same |
| `02_DeployProxies.s.sol` | Proxy layer | Deploy UUPSProxy (or atomic deployer pattern) for NAVCalculator, BridgeEscrow; initialize | Deployer EOA | impl addresses |
| `02_2_DeployNAVProxy.s.sol` | Proxy layer (alt) | Deploy NAVCalculator proxy (separate if atomic) | Deployer EOA | impl address |
| `03_DeployPriceFeeds.s.sol` | Feeds | Deploy custom price feeds (28 contracts) | Deployer EOA | NAVCalculator address |
| `04_DeployBalanceAdapters.s.sol` | Adapters | Deploy plain adapters + meta-adapters + assisted adapters (CREATE, not CREATE2) | Deployer EOA | NAVCalculator address |
| `05_DeployBridgeAdapters.s.sol` | Bridge | Deploy bridge adapters (Across, CCIP, CCTP, Stargate, Gnosis, Superchain) (CREATE) | Deployer EOA | BridgeEscrow address |
| `06_Configure.s.sol` | Config | Register assets, price feeds; add balance adapters; authorize bridge adapters (idempotent) | Deployer EOA | all deployed addresses |
| `07_TransferAdminToSecurityCouncil.s.sol` | Governance | Hand DEFAULT_ADMIN_ROLE + MANAGER to Security Council Safe; deployer renounces | Deployer EOA | deployed proxy addresses |

### 7.2 Config Files
| Path | Contains | Mutable? |
|------|----------|----------|
| `script/config/chains/<chainId>.json` | Chain meta + role addresses (admin, manager, securityCouncil) | Deployment input |
| `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` | Plain adapter ctor args | Deployment input |
| `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` | Meta adapter ctor args + initial instances | Deployment input |
| `script/config/contracts-deployment-config/custom-price-feeds/<chainId>.json` | Price feed ctor args | Deployment input |
| `script/config/contracts-deployment-config/bridge-adapters/<chainId>.json` | Bridge adapter ctor args | Deployment input |
| `script/config/nav-config/assets-and-price-feeds/<chainId>.json` | Assets to register + feeds to add | Post-deploy config input |
| `script/config/nav-config/balance-adapters/<chainId>.json` | Plain adapters to register on NAVCalculator | Post-deploy config input |
| `script/config/nav-config/meta-balance-adapters/<chainId>.json` | Meta adapters + instances to register | Post-deploy config input |
| `script/config/deployments/<chainId>.json` | Deployed addresses (outputs, append-only) | Deployment output |

### 7.3 Key Roles
- **Deployer EOA**: Holds DEFAULT_ADMIN_ROLE + MANAGER during deploy; strips itself in script 07
- **chainConfig.manager**: EOA or account; receives MANAGER role (can be same as admin or separate)
- **chainConfig.securityCouncil** (Safe): Receives DEFAULT_ADMIN_ROLE + MANAGER after deploy 07 (sole admin/manager thereafter)
- **ASSISTANT_ROLE holders** (per-adapter): Typically OIV Safe or delegated account for Merkl/queue cache updates

---

## 8. Test Architecture (Out of Scope but Context)

- **Unit tests**: `test/**/` mirrors `src/**`; mock-only tests for adapters
- **Fork tests**: `test/**/fork/` against real holders at pinned blocks (e.g. `FORK_BLOCK` env var)
- **Integration tests**: `test/integration/accounts.json` (JSON-driven, per-chain, pinned blocks)
- **CI Profile**: `forge build --sizes` (EIP-170 check), `forge test` (unit + fork with `FOUNDRY_PROFILE=slow`)

---

## 9. Key Files for Phase 2 Auditors

### Core Logic
1. **NAV Computation**: `src/nav/NAVCalculator.sol`, `src/prices/PriceFeedLib.sol` (DELEGATECALL engine)
2. **Balance Registry**: `src/balances/Balances.sol`, `src/nav/NAVRegistryLib.sol` (registry mutations)
3. **Price Feed Selection**: `src/prices/PriceFeedLib.sol:62–150` (_selectFeedCore)
4. **Bridge Escrow**: `src/bridge/BridgeEscrow.sol` (funded pass-through, invoice tracking, replay guard)
5. **Bridge Adapters**: `src/bridge/adapters/*.sol` (protocol-specific message authentication)

### Access Control
1. **NAVCalculator roles**: `src/nav/NAVCalculator.sol:87–230` (mutator gates)
2. **BridgeEscrow roles**: `src/bridge/BridgeEscrow.sol:113–250` (adapter/account auth)
3. **Assisted adapters**: `src/balances/AssistedBalanceAdapter.sol`, `src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol`
4. **Deploy script 07**: `script/deploy/07_TransferAdminToSecurityCouncil.s.sol` (role handoff)

### Oracle Aggregation
1. **Multi-feed redundancy**: `src/prices/PriceFeedLib.sol:62–150`
2. **L2 sequencer check**: `src/prices/Prices.sol:43–53`, `src/prices/PriceFeedLib.sol:199–230`
3. **Custom feeds**: `src/prices/protocols/*.sol` (28 contract instances)
4. **Staleness gating**: `src/prices/PriceFeedLib.sol:87–130` (heartbeat checks)

### Bridge Flows
1. **Deposit**: `src/bridge/BridgeEscrow.sol:141–192`
2. **Release**: `src/bridge/BridgeEscrow.sol:202–241`
3. **Checksum/replay**: `src/bridge/InvoiceDataLib.sol` (encode/decode/verify)
4. **Adapter callbacks**: `src/bridge/adapters/CcipBridgeAdapter.sol` (example protocol validation)

### Adapters (Multi-Instance)
1. **MetaBalanceAdapter base**: `src/balances/MetaBalanceAdapter.sol` (per-instance fan-out, isolation)
2. **ERC20Default**: `src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol` (inclusion list)
3. **Assisted (Merkl)**: `src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol` (proof cache)
4. **Assisted (exit-queues)**: `src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueBalanceAdapter.sol`, `src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol` (coordinate cache)

### Deployment
1. **Role handoff**: `script/deploy/07_TransferAdminToSecurityCouncil.s.sol`
2. **Config orchestration**: `script/deploy/06_Configure.s.sol` (idempotent adapter/asset registration)
3. **Impl/proxy setup**: `script/deploy/01_DeployImplementations.s.sol`, `script/deploy/02_DeployProxies.s.sol`

---

## 10. Preliminary Risk Hot Spots (No Analysis, Locations Only)

| Area | Location | Why Notable |
|------|----------|-------------|
| **Feed staleness + sequencer** | `src/prices/PriceFeedLib.sol:87–230` | Multi-feed selection logic; staleness gates + L2 sequencer check; if logic wrong, NAV computable on stale prices |
| **Bridge replay guard** | `src/bridge/InvoiceDataLib.sol`, `src/bridge/BridgeEscrow.sol:227–228` | Checksum uniqueness; if collision, invoiceHash can repeat → replay |
| **Assisted adapter over-reporting** | `src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol:130–160` | Proof verification logic; if skipped or weakened, over-report possible |
| **Meta-adapter instance isolation** | `src/balances/MetaBalanceAdapter.sol:136–161` | Try-catch per-instance; if catch too narrow, bad instance not isolated → zeros batch |
| **Bridge adapter message auth** | `src/bridge/adapters/CcipBridgeAdapter.sol`, `src/bridge/adapters/CctpBridgeAdapter.sol` | Each adapter must validate protocol message proof + source; if weak, forged messages drain escrow |
| **NAV calculation rounding** | `src/prices/PriceFeedLib.sol:150–200` (value summation) | Large arrays, decimals, rounding; if accumulation has truncation loss, NAV drifts |
| **DELEGATECALL storage assumptions** | `src/nav/NAVCalculator.sol:250` (PriceFeedLib.computeNav call) | Libraries operate on NAVCalculator's storage via DELEGATECALL; if storage layout mismatched, state corruption |
| **Custom price feed logic** | `src/prices/protocols/*.sol` (28 feeds) | Each has custom ratio/conversion; logic bugs (e.g., wrong decimals, division by zero) → price wrong |
| **ERC20 transfer safety** | `src/bridge/BridgeEscrow.sol:164–167` | Fee-on-transfer balance diff; if overwritten by hook, escrow amount wrong; `safeTransferFrom` should mitigate |
| **Deploy script idempotency** | `script/deploy/06_Configure.s.sol` | Adapter registration may fail if already registered; script must skip gracefully |

---

## Summary

**onchain-accounting** is a sophisticated portfolio NAV aggregator + cross-chain bridge. 

**Core strengths**:
- Multi-adapter balance fetching with per-instance isolation (MetaBalanceAdapter pattern)
- Multi-feed price redundancy with Chainlink staleness + L2 sequencer uptime checks
- Bridge escrow with invoice-based replay guards + funded pass-through (no standing balance drain risk)
- Mutable-cache adapters (Merkl, exit-queues) with on-chain verification or live re-valuation (cannot over-report)

**Core risks** (Phase 2 audit scope):
- Access control mutations (MANAGER can add/remove assets, adapters, feeds; must validate inputs)
- Oracle/feed logic correctness (feed selection, staleness gates, custom feeds, decimal handling)
- Bridge adapter message authentication (each protocol has different callback/proof validation)
- Assisted adapter cache freshness + over-report prevention (Merkl proof verification, queue coordinate + live-value model)
- DELEGATECALL library storage consistency + EIP-170 code layout
- Deploy script completeness + role handoff atomicity

**Audit recommendation**: Focus on flows 2.1–2.4, sections 4.2 & 5.2–5.3, and hot-spots in section 10. Each bridge adapter's `_completeBridge` implementation varies; requires protocol-specific message validation review.
