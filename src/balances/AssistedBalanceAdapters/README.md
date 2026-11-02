# Assisted balance adapters & assistants

Reference for the **assisted** balance-adapter family and the **assistant** feeder contracts that keep it current. This folder holds the adapters (`*.sol` here), the single shared cache base (`AssistedCoordCache.sol`), and the assistant foundation + concretes (`assistants/`).

- **ADRs:** [0015](../../../docs/decisions/0015-assisted-balance-adapter-family.md) (the family), [0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md) (the assistant-fed variant), [0030](../../../docs/decisions/0030-assisted-adapters-keeper-submit-and-preview.md) (keeper `submitFor`, proof-of-death `removeFor`, cache-free `previewPositions`), [0014](../../../docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) (the original agent-fed queues), [0017](../../../docs/decisions/0017-lp-valuation-instantaneous-amounts.md) (instantaneous LP valuation / async-NAV threat model).

---

## 1. Why the family exists

Most balance adapters derive a position purely from on-chain state (`balanceOf`, a lending pool read, an enumerable set). A few **cannot**: the coordinate needed to value the position isn't discoverable from a `view` call —

- non-enumerable NFTs (Nexus Mutual `StakingNFT`, ether.fi `WithdrawRequestNFT`),
- withdrawal/exit-queue tickets keyed by per-account coordinates the protocol doesn't index (StakeWise V3 exit positions),
- off-chain merkle allocations (Merkl).

For these, a **trusted party feeds the position's coordinate** (a tokenId / requestId / tuple / proof) so the position becomes queryable. This is the third balance-adapter family, peer to plain `BalanceAdapter`s and meta-adapters.

## 2. The family invariant (what makes it safe)

Every member — regardless of who feeds it — upholds one invariant:

> **Cache coordinates only (never amounts). Value every read live on-chain. Re-verify ownership on every read.**

Consequences:

- A faulty or malicious feeder can only ever **under-report, never over-report** NAV. It cannot fabricate a balance, because amounts are always read live from the protocol and a coordinate that isn't (or is no longer) owned by the account values to `0` and is discarded.
- **In production the cache is also COMPLETE, not merely conservative** — so "under-report only" understates the actual guarantee. The portfolio Safes' **roles-modifier allow-list permits these protocol entries only through the assistant contracts**, so a position of these types cannot be active without having been fed. That half is enforced **outside this repository** (see [§5.0](#50-the-assistant-is-the-only-path--enforced-on-chain-by-the-safes-roles-modifier)) — nothing here enforces it, since the owner `submit`/`remove` are `msg.sender`-keyed and the keeper path only adds coverage.
- These adapters are the documented exception to the "adapters are immutable / no mutable storage" rule — the coordinate cache is their only mutable state.

## 3. Feeding: assistant-fed

The family is fed by an on-chain **assistant** contract the owner **delegatecalls** ([ADR 0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)):

- **Owner path** — the typed `submit`/`remove` and `clearAccount` key on `msg.sender`, so a caller can only touch its own set.
- **Keeper path ([ADR 0030](../../../docs/decisions/0030-assisted-adapters-keeper-submit-and-preview.md))** — for positions the owner did NOT open through its assistant (a Safe that entered the protocol directly, a StakeWise remainder ticket after a partial claim). `submitFor(account, coord)` / `submitForBatch` require `SUBMITTER_ROLE` (a keeper; `DEFAULT_ADMIN_ROLE` = the Security Council) and run the same `_validateCoord(account, coord)` as the owner path, so a coordinate is filed only under the account the protocol says owns it. The keeper path stops `OWNER_RESERVE` (32) slots short of the cap, so the owner always keeps at least 32 slots for its Assistant `submit`; `evict(coord)` lets the owner drop one entry of its own set regardless of liveness (selective `clearAccount`). `removeFor(account, coord)` is permissionless but succeeds only when the protocol PROVES the position is gone (`_isDead`; a reverting read never counts). `previewPositions(account, abi.encode(bytes[]))` values caller-supplied coordinates without touching the cache, validating each like a submit and reverting on a bad one.
- Cache base: **`AssistedCoordCache`** (§4). Submit shape: incremental `submit`/`remove`, atomic with the protocol deposit/claim.
- Members: **Nexus, StakeWise, ether.fi** (§6).

> **Historical note.** An earlier **agent-fed** variant existed — an off-chain agent holding `ASSISTANT_ROLE` fed a role-gated base (`AssistantFedBalanceAdapter`) with full-set `submitTokenIds`; its only member was Merkl. That variant (base + marker + Merkl adapter) was **removed in #141**. Merkl was then re-added as its **own separate `attested` family** — `MerklRewardsAttestedBalanceAdapter` in `../AttestedBalanceAdapters/`, [ADR 0022](../../../docs/decisions/0022-attested-balance-adapter-family.md) — because it caches a proof-verified *amount* (not coordinates valued live), so it is NOT part of this assisted family. This assisted family is exactly the assistant-fed coordinate-cache variant described here (with the ADR 0030 keeper path).

---

## 4. The adapter side — `AssistedCoordCache`

`AssistedCoordCache` is the **single** cache base for every assistant-fed adapter. The key idea: a position **coordinate is an opaque `bytes` blob**, so one cache serves every member regardless of coordinate shape.

- A bare `uint256` (NFT tokenId / sequential requestId) is fed as `abi.encode(id)`.
- A tuple (StakeWise `(vault, positionTicket, timestamp)`) is fed as `abi.encode(vault, ticket, timestamp)`.

### 4.1 Storage & CRUD

```solidity
mapping(address => bytes[])                     _coords;    // per-account coordinate blobs
mapping(address => mapping(bytes32 => uint256)) _idxPlus1;  // keccak256(coord) -> index+1 (dedup + O(1) swap-pop)
```

- The owner path (`submit`/`remove`/`clearAccount`/`evict`) is **self-scoped**: it keys on `msg.sender`, so a caller can only ever touch its **own** set. The keeper path (§3) writes another account's set, but only coordinates that account owns, through the same internal admission (`_addEntry`), and with the exact coordinate length each member declares (`_coordLength`, so one position has one cache key).
- **`_submitCoord(bytes coord)`** — re-validates ownership on *every* call (via `_validateCoord`, **before** the dedup early-return, so resubmitting a coordinate you've since transferred away reverts), dedups by `keccak256(coord)`, caps at `_maxCoords()` (`CoordinateCacheFull`), pushes.
- **`_removeCoord(bytes coord)`** — fail-loud: reverts `CoordinateNotCached` if the caller isn't tracking it, `CoordinateStillLive` if `_removable` says it's not yet droppable; else swap-pops.
- **`clearAccount()`** — self-service GC of the caller's whole set; **`evict(coord)`** drops one of the caller's own entries regardless of liveness (ADR 0030).

### 4.2 Valuation — fail-open fan-out

`getAdapterPositions` / the balance getters call `_collect`, which values **each** coordinate behind a per-item `this.valueCoordSelf(...)` **staticcall wrapped in try/catch**:

- A revert in one coordinate's live reads (e.g. Nexus's `StakingViewer.getTokens`) discards **only that coordinate** — it never propagates out of `getAdapterPositions`, where NAVCalculator's per-adapter try/catch would otherwise drop the account's *entire* set.
- **One exception, deliberately loud: gas exhaustion.** Each coordinate is forwarded `GasStipendLib.stipendFrom(gasleft())`, and when the catch arm measures `GasStipendLib.exhausted(stipend, consumed)` the loop reverts `CoordinateGasExhausted(adapter, coordId, stipend, consumed)` rather than recording zero legs — a starved coordinate never answered, and the ~1/64 residue it leaves cannot fund the coordinates after it either. That error is declared **file-local in `AssistedCoordCache.sol`**, not in `src/errors.sol` (both pinned libraries plain-import that file).
- `valueCoordSelf` is `external` (so the self-call is a staticcall giving each coordinate its own revert frame) and guarded `msg.sender == address(this)`.

### 4.3 Single-underlying-asset surface

The base pins `UNDERLYING_TOKEN` + `NAV_CALCULATOR` and implements the full `IBalanceAdapter` getter triad (`underlyingAssetsSupported` / `getAdapterBalanceForAsset` / `getAdapterBalances`) plus `getAdapterPositions`, all derived from the same `_collect`. `getAdapterPositions` drops everything if `UNDERLYING_TOKEN` isn't registered in NAV; the balance getters report it regardless (registration-independent).

### 4.4 Events

```solidity
event CoordSubmitted(address indexed account, uint256 indexed id);  // id = _coordId(coord)
event CoordCleared  (address indexed account, uint256 indexed id);
event AccountCleared(address indexed account);
```

`id` is the human-facing coordinate id (tokenId / requestId / positionTicket) so indexers can filter, matching the legacy per-adapter events.

### 4.5 Hooks a concrete adapter implements

| Hook | Purpose |
|---|---|
| `_maxCoords()` | per-account cache cap (read-loop gas bound) |
| `_maxLegsPerCoord()` | upper bound on legs per coordinate (scratch-buffer sizing) |
| `_coordId(bytes)` | decode → the human id for events/errors |
| `_validateCoord(account, bytes)` | fail-loud write-time hygiene, shared by `submit`, `submitFor` and `previewPositions` — revert `InvalidCoordinate` (malformed/unregistered target) or `CoordinateNotOwned` (not owned by `account`) |
| `_removable(account, bytes)` | may this coordinate be dropped? (see per-member policy below) |
| `_isDead(account, bytes)` | gate for the permissionless `removeFor`: true only when a SUCCESSFUL protocol read proves the position gone (burned / transferred / emptied); a revert is never death (ADR 0030) |
| `_coordLength()` | byte length of the canonical `abi.encode` (32 for a tokenId, 96 for StakeWise's tuple); the keeper path and preview reject any other length |
| `_valueCoord(account, bytes, underlying)` | decode, re-verify ownership live, return the priced legs (may revert — it's isolated) |

Plus the adapter exposes a **typed** `submit`/`remove` that `abi.encode`s its coordinate and routes to `_submitCoord`/`_removeCoord`, and a typed read helper (`tokenIdsOf` for Nexus/ether.fi, `positionsOf` for StakeWise) that decodes `_cachedCoords`.

### 4.6 Marker interface

```solidity
interface IAssistedBalanceAdapter is IAccessControl, IBalanceAdapter {
    function SUBMITTER_ROLE() external view returns (bytes32);
    function submitFor(address account, bytes calldata coord) external;                     // SUBMITTER_ROLE
    function submitForBatch(address[] calldata accounts, bytes[] calldata coords) external;  // SUBMITTER_ROLE
    function removeFor(address account, bytes calldata coord) external;                      // anyone, proof of death
    function previewPositions(address account, bytes calldata data) external view returns (PositionBalance[] memory);
    function clearAccount() external;   // self-service GC; msg.sender-keyed
    function evict(bytes calldata coord) external; // drop one of the caller's own entries, live or not
}
```

The typed `submit`/`remove` stay per member (the coordinate shape differs). The only admin power is granting and revoking `SUBMITTER_ROLE`; the role decides which positions occupy the capped cache, never what they are worth ([ADR 0030](../../../docs/decisions/0030-assisted-adapters-keeper-submit-and-preview.md)).

---

## 5. The assistant side — `assistants/`

An **assistant** is the on-chain feeder that keeps an adapter's cache current, atomically with the protocol action that creates/destroys the position. It is a **stateless logic module the owner Safe `delegatecall`s** — it does *not* wrap the adapter (hence "assistant", not "wrapper").

### 5.0 The assistant is the *only* path — enforced on-chain by the Safe's roles modifier

> **This is not an operational rule the operator could forget. It is an on-chain permission.** These positions exist precisely because their coordinate (tokenId / requestId / tuple) is **not retrievable from on-chain state** — no `balanceOf`, no owner→tokenIds view, no enumeration. The **only** way NAV ever learns the position exists is the coordinate the assistant caches at the moment it is created. Accordingly, **the portfolio Safes' roles-modifier permission set allows these protocol entries only *through the assistant contracts*; the direct protocol entrypoint is not in the allow-list.**

**The invariant this produces — the cache is COMPLETE BY CONSTRUCTION, not merely conservative.** A position of these types **cannot be active without its coordinate having been fed to the adapter**, because the transaction that would create it un-fed is not a permitted call. So the family's guarantee has **two complementary halves**, and neither alone is the full story:

| Level | Property | Enforced by |
|---|---|---|
| **Contract** (this repo) | **Cannot over-report** — coordinates only (never amounts), valued live on-chain, ownership re-verified per read, so a bad or stale coordinate values to `0` and is dropped | `AssistedCoordCache` + each adapter's `_valueCoord` / `_ownerOf` |
| **Roles** (outside this repo) | **Cannot under-report either** — the position cannot come into existence without being fed, so the cached set is complete | the Safe's roles-modifier allow-list |

**Where enforcement lives, and why you cannot see it here.** Nothing in *this repository* enforces the roles half. `AssistedCoordCache`'s owner `submit`/`remove` are `msg.sender`-keyed, the keeper path only adds coverage, and the assistant is *the canonical feeder* rather than a gate — so a reader of those files alone sees a permissionless cache and no completeness guarantee at all. The guarantee is one layer up, in the **Safe's roles configuration**, which is not part of this repo. Read this section as a pointer to that configuration.

**Residual risk, stated accurately.** The risk is *not* "an operator bypasses the process" — that path is not permitted. It is: **a change to the roles permission set adds a path that reaches the protocol without going through the assistant.** After such a change the cache silently misses positions, and **there is no tripwire anywhere in this repository** that would detect it — the adapters would report a smaller-but-internally-consistent set, and every contract-level invariant would still hold. So roles-permission changes touching these protocols are the thing to review.

- **Open via the assistant.** Enforced by roles; the direct entrypoint is not callable. Were it ever reachable, the position would be created on-chain with its coordinate **never cached**, so NAV could not see it — silently **under-counted** until the coordinate is submitted — by the owner Safe after the fact, or by the keeper's `submitFor` (ADR 0030).
- **Close via the assistant.** Claiming/withdrawing through the assistant prunes the cache in the same tx. A direct close would leave a stale coordinate — harmless (it values live to `0` and is discarded on read; `remove`/`evict`/`clearAccount`, or anyone's `removeFor` once the protocol proves it gone, GC it) but it wastes read gas and the cap.
- **The contract-level "under-report only" property is the defence-in-depth that survives if the roles half is ever removed**: bypassing the assistant can only make NAV *miss* a position, never invent one. That is why the two halves are stated together — the roles layer makes the cache complete, and the contract layer bounds the damage if it ever stops being so.

Concretely: instead of `LiquidityPool.requestWithdraw(...)` the Safe delegatecalls `EtherFiWithdrawalQueueAssistant.requestWithdraw(...)`; instead of `vault.enterExitQueue(...)` it delegatecalls `StakeWiseV3ExitQueueAssistant.enterExitQueue(...)`; etc. The assistant forwards to the very same protocol function (same effect on funds) **and** records the coordinate — one atomic transaction, no separate bookkeeping step that could be forgotten or fall out of sync.

### 5.1 Why delegatecall

Running under `delegatecall`, `address(this)` **is the Safe**:

- the protocol sees `msg.sender = Safe` (so the Safe is the position owner / the only one that can claim), and
- the adapter's `msg.sender`-keyed cache records against that **same Safe**.

So there are **no roles, no token custody, and no asset-forwarding** — the Safe holds the funds and owns the position throughout. EOAs can't `delegatecall`, so the intended feeders are Safe/Avatar accounts (which Safe may run an assistant is gated at the Safe/Zodiac layer).

### 5.2 `BalanceAdapterAssistant` (abstract base)

```solidity
abstract contract BalanceAdapterAssistant is IBalanceAdapterAssistant {
    address public immutable SELF;      // this deployment's address, pinned at construction
    address public immutable ADAPTER;   // the assisted adapter it feeds

    modifier onlyDelegateCall() { if (address(this) == SELF) revert NotDelegateCall(); _; }
    function _requireSelf(address account) internal view { if (account != address(this)) revert AssistantAccountMismatch(address(this), account); }
}
```

- **`onlyDelegateCall`** — under `delegatecall`, `address(this) != SELF`; a direct call on the singleton has `address(this) == SELF` and reverts `NotDelegateCall` (fail loud rather than letting the protocol revert obscurely).
- **`_requireSelf(account)`** — for assistants whose forwarded protocol call has an explicit `receiver`/`owner` argument: it must equal `address(this)` (the Safe), else `AssistantAccountMismatch`. Assistants that instead force the receiver to `address(this)` internally don't need it.
- No mutable state (delegatecall-storage-collision safe); no roles.

### 5.3 The flow

Every assistant is two entrypoints:

- **open** (deposit / request-withdraw / enter-queue): optional `forceApprove`, forward to the protocol (receiver pinned to the Safe), then `ADAPTER.submit(coord)`.
- **close** (withdraw / claim): forward to the protocol, then `ADAPTER.remove(coord)`.

Because both run as the Safe, the `submit`/`remove` calls carry `msg.sender = Safe` and land in the Safe's own cache. Ordering matters when a claim burns the coordinate: **claim first, then remove** (the adapter's `_removable` requires the coordinate be gone — see ether.fi below).

---

## 6. Members

| Adapter (`*AssistedBalanceAdapter`) | Coordinate | Legs | `_removable` policy | Assistant entrypoints |
|---|---|---|---|---|
| **NexusMutualStakingPools** | `abi.encode(tokenId)` | up to 2: `Staking` (active+expired) + `Rewards`, NXM | **value-based** — Nexus doesn't burn the `StakingNFT` on withdraw, so "no longer owned" isn't a liveness proxy; removable only when the id is no longer owned by the account OR fully emptied (no stake/rewards), so a partial/rewards-only withdraw keeps a still-live position tracked | `depositTo(pool, amount, tranche, reqId)` → submit; `withdraw(pool, tokenId, …)` → remove (best-effort). Approves NXM to the TokenController |
| **StakeWiseV3ExitQueue** | `abi.encode(vault, positionTicket, timestamp)` | up to 2: claimable + locked `Supplied`, ETH | claimed/consumed → owed 0 | `enterExitQueue(vault, shares)` (receiver forced to the Safe) → submit; `claimExitedAssets(vault, ticket, ts, idx)` → remove (best-effort) |
| **EtherFiWithdrawalQueue** | `abi.encode(requestId)` | 1 `Supplied`, native ETH (`isLocked = !finalized`) | no longer owned — `claimWithdraw` **burns** the NFT | `requestWithdraw(amount)` (approves eETH, recipient = Safe) → submit; `claimWithdraw(tokenId)` (claim burns) → remove (best-effort) |

Each adapter shares a per-position `positionId` (e.g. the WithdrawRequestNFT address for ether.fi, the vault address for StakeWise, or Nexus's staking-pool address) and rides the per-item coordinate id in `positionInstanceId`. Each is paired with a `…Assistant` in `assistants/`.

> **Not a member: Stader.** Stader's withdrawal queue is a **plain** `BalanceAdapter` (`src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol`), not an assisted one: it enumerates an account's live requests on-chain via `getRequestIdsByUser` (claim-pruned, protocol-capped), so it needs no assistant. See ADR 0018 "Consequences" for the rationale.

---

## 7. Error taxonomy (`src/errors.sol`)

Adapter (shared across the whole family):

| Error | When |
|---|---|
| `CoordinateNotOwned(account, id)` | `submit` of a coordinate not owned by the caller |
| `CoordinateCacheFull(account, max)` | `submit` past the per-account cap |
| `CoordinateNotCached(account, id)` | `remove` of a coordinate the caller isn't tracking |
| `CoordinateStillLive(account, id)` | `remove` of a still-owned (live) coordinate — refused so a live position is never dropped |
| `InvalidCoordinate(account, id)` | `submit` of a malformed / unregistered-target coordinate |

Assistant:

| Error | When |
|---|---|
| `NotDelegateCall()` | a delegatecall-only entrypoint was called directly on the singleton |
| `AssistantAccountMismatch(expected, provided)` | a forwarded `receiver`/`owner` arg wasn't the executing Safe |

---

## 8. Adding a new assistant-fed protocol

1. **Adapter** — `contract FooAdapter is AssistedCoordCache, IPositionDescribable`:
   - constructor: `AssistedCoordCache(underlyingToken, navCalculator)` + pin protocol addresses (`AddressCheckLib.requireContract`).
   - typed `submit`/`remove` wrapping `_submitCoord(abi.encode(...))` / `_removeCoord(...)`.
   - implement the six hooks (§4.5); decode the coordinate in each.
   - `protocolName` / `positionLabels` (`IPositionDescribable`) + `supportsInterface` (add `IPositionDescribable`, call `super`).
2. **Assistant** — `contract FooAssistant is BalanceAdapterAssistant`:
   - constructor: `BalanceAdapterAssistant(adapter)` + pin protocol targets.
   - `onlyDelegateCall` open/close entrypoints forwarding to the protocol then `ADAPTER.submit/remove`; pin the receiver to `address(this)` (or `_requireSelf` an explicit owner arg).
3. **Tests** — unit (`FooAdapter` submit/remove/cap/ownership/valuation + `FooAssistant` via an `AssistantDelegateCaller` / `MockSafe` that delegatecalls) and a fork test at a pinned block against a real holder, seeding the cache by pranking the holder and `submit`ting.
4. Register on NAVCalculator (`addBalanceAdapters`) and deploy the assistant (deploy-script wiring).

## 9. Tests

- Unit tests live in `test/balances/AssistedBalanceAdapters/` (adapters) and `test/balances/AssistedBalanceAdapters/assistants/` (assistants; `AssistantDelegateCaller.sol` is the shared delegatecall stand-in).
- Fork tests under the matching `fork/` subdirs seed the cache from real on-chain holders and assert live-valuation parity at a pinned block.
- `forge test --match-path "test/balances/**"` (unit) must stay green; fork tests run under `FOUNDRY_PROFILE=slow` / in CI (RPC-backed).
