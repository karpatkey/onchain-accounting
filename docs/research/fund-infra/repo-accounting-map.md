
# Repo accounting map: NAV registration, assisted adapters, Roles harness

## Summary

- **Accounting registry is global per chain.** One `NAVCalculator` proxy holds one adapter set, one meta-instance set per meta-adapter, and one claimant per coordinate. The `account` argument only filters positions. Nothing in `src/` or `script/` is per-account for adapters or instances.
- **Per-account state exists only in the assisted caches.** `AssistedCoordCache` keys coordinates by account (`coordsOf(account)`). No other per-account config exists.
- **Permission data is absent from the repo.** Zodiac Roles appears only in the fork test harness (`test/utils/AssistantSafeRolesForkBase.sol`) and in docs and ADRs. No `allowTarget` / `scopeAllowFunction` / `FundConfig` / protocol-registry / permission-blueprint / fund-factory hits exist in `src/`, `script/`, or `test/utils/`. Searches covered `src`, `script`, `test/utils`, `script/config`, `script/deploy/preflight`, and `docs/decisions` + `docs/howto`.
- **Consistency today is by convention.** ADR 0015 / 0018 / 0030 state that the roles allow-list permits protocol entries only through the assistants. That is enforced outside this repo.

## Files

| Path | Holds |
|---|---|
| `src/nav/NAVCalculator.sol:78` | `contract NAVCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable, INAVCalculator, Prices, Balances` |
| `src/nav/NAVCalculator.sol:115-137` | `initialize(admin_, chainlinkL2SequencerUptimeFeed_, nativeTokenSymbol_)`. Grants `DEFAULT_ADMIN_ROLE` to `admin_` (L133). Deploys ERC20Default adapter with native address pre-registered (L128-131). |
| `src/nav/NAVCalculator.sol:316-371` | MANAGER-gated mutators: `addBalanceAdapters(address[])`, `addMetaBalanceAdapter(address,bytes32[])`, `removeBalanceAdapters(address[])`, `addMetaInstances(address,bytes32[])` (L365), `removeMetaInstances(address,bytes32[])` (L371), `exclude/includeAssetInDefaultAdapter` |
| `src/nav/NAVCalculator.sol:447` | `getAccountNav(account, quoteAsset)` → `PriceFeedLib.computeNav(… getAllAdapters(), _metaInstanceTotal, account, …)` |
| `src/nav/NAVCalculator.sol:~488` | `getAccountNavForAdapters(account, quoteAsset, adapters[])`, validated via `PriceFeedLib.validateAdapterSlice` |
| `src/nav/NAVCalculator.sol:816` | `_requireManager()` (body not read) |
| `src/constants.sol:14` | `MANAGER = keccak256("MANAGER")` |
| `src/constants.sol:21` | `DEFAULT_ADMIN_ROLE = 0x00` |
| `src/balances/Balances.sol` | Global registry: `_globalAdapters`, `_isAdapterRegistered`, `_adapterTypes`, `_metaInstances[adapter]`, `_claimant[bytes32 coord] → adapter`. `getAdaptersForAsset(asset)` L173, `getMetaInstances(adapter)` ~L283. Internal `_addBalanceAdapters`, `_removeBalanceAdapters`, `_addMetaBalanceAdapter`, `_addMetaInstances`, `_removeMetaInstances`, `_includeAssetIfUnclaimed`. `_metaInstanceTotal` retired but kept for layout. `__balancesGap[47]`. |
| `src/nav/NAVRegistryLib.sol:131` | `addBalanceAdapter` → `_registerAdapter(…, false)` (ERC165 check not read) |
| `src/nav/NAVRegistryLib.sol:315` | `getAdaptersForAsset(globalAdapters, asset)` |
| `src/nav/NAVRegistryLib.sol:355-382` | `addMetaInstances(isAdapterRegistered, metaInstances, claimant, adapter, instances, erc20DefaultAdapter)`. Reverts `InvalidBalanceAdapter` (unregistered), `NotMetaAdapter` (no `IMetaBalanceAdapter` ERC165), `InvalidArguments` (empty). |
| `src/nav/NAVRegistryLib.sol:384-420` | `removeMetaInstances`: swap-and-pop, all-or-nothing, `MetaInstanceNotFound` on absence |
| `src/nav/NAVRegistryLib.sol:464-498` | `_claim`: reverts `DuplicateMetaInstance` (same adapter) or `MetaInstanceClaimedByAnotherAdapter(instance, holder)`. Scans own set (L484-490) because `_claimant` is new storage on upgraded proxies. Sets `claimant[instance]`, pushes, then `_excludeIfAsset`. |
| `src/nav/NAVRegistryLib.sol:502` | `_release`: clears claim only, does NOT re-arm default adapter |
| `src/nav/NAVRegistryLib.sol:549` | `_appendInstances` |
| `src/nav/NAVRegistryLib.sol:591-607` | `includeAssetIfUnclaimed(claimant, erc20Default, asset, revertIfClaimed)`: if claimed, returns (or reverts if `revertIfClaimed`); else `addSupportedAsset` |
| `src/nav/NAVRegistryLib.sol:610-625` | `_excludeIfAsset(erc20Default, instance)`: `removeSupportedAsset(token)` where `token = address(uint160(uint256(instance)))`. Deliberately not fail-open. |
| `src/nav/NAVRegistryLib.sol:631` | `_releaseInstances`: clears all claims in an adapter's set, then deletes the array. Called on re-registration too. |
| `src/prices/PriceFeedLib.sol:597-625` | `validateAdapterSlice(allAdapters, adapters)`: reverts `EmptyAdapterSlice`, `DuplicateAdapterInSlice`, `AdapterNotRegistered`. Checks membership in the registry, not coverage. |
| `src/prices/PriceFeedLib.sol:1119` | `_queryAllAdapters` loops every adapter, calling `_getAdapterPositions` |
| `src/prices/PriceFeedLib.sol:1188-1210` | `_getAdapterPositions`: `try IBalanceAdapter(adapter).getAdapterPositions{gas: stipend}`. On catch: `_reraiseIfInstanceExhausted`, then reverts `AdapterGasExhausted` if exhausted, else returns empty. |
| `src/utils/GasStipendLib.sol:46` | `stipendFrom(available) = available - available/64` (63/64 rule) |
| `src/utils/GasStipendLib.sol:58` | `exhausted(stipend, consumed) = consumed >= stipend - stipend/8` (`SLACK_DIVISOR = 8`) |
| `src/balances/MetaBalanceAdapter.sol:33` | `INAVCalculator public immutable NAV_CALCULATOR` |
| `src/balances/MetaBalanceAdapter.sol:226` | `positionIds()` |
| `src/balances/MetaBalanceAdapter.sol:272-281` | `getAdapterPositions(account, assetFilter)` → `_positionsForInstances(account, NAV_CALCULATOR.getMetaInstances(address(this)), assetFilter)` |
| `src/balances/MetaBalanceAdapter.sol:450-487` | `instancePositions`, `_instancePositions(account, instance, assetFilter)` (hook), `_instanceAssets(instance)` (hook, L487) |
| `src/balances/MetaBalanceAdapter.sol:515,545,582` | `_leg(...)`, `_labels(category, leaf)`, `_instancePositionId(instance)` (default `abi.encode(address)`) |
| `src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol:80,109` | `NAV_CALCULATOR` immutable |
| `src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol:118-168` | `submitFor(account, coord)` L118, `submitForBatch` L124, `removeFor(account, coord)` L136, `clearAccount()` L148, `evict(coord)` L158, `coordsOf(account)` L168 |
| `src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol:64,67,110` | `AccessControl`, `SUBMITTER_ROLE`, admin = `DEFAULT_ADMIN_ROLE` |
| `src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol` | `submit(uint256 tokenId)` L75, `remove` L82, `tokenIdsOf` L87, `_coordId` L158, `_validateCoord` L163 |
| `src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol` | `EXIT_CLAIM_DELAY` immutable L42, `submit(vault, positionTicket, timestamp)` L75, `remove` L81, `positionsOf` L86 |
| `src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol` | `submit(uint256 tokenId)` L71, `remove` L78, `tokenIdsOf` L83, `_validateCoord` L129 |
| `src/balances/AssistedBalanceAdapters/assistants/BalanceAdapterAssistant.sol` | Abstract. Immutables `SELF`, `ADAPTER`. `onlyDelegateCall` reverts `NotDelegateCall` when `address(this)==SELF`. `_requireSelf(account)` reverts `AssistantAccountMismatch`. `_bubbleUnlessCacheRevert` swallows `CoordinateStillLive` / `CoordinateNotCached`. Holds no roles or state. |
| `src/balances/AssistedBalanceAdapters/assistants/EtherFiWithdrawalQueueAssistant.sol` | `requestWithdraw(uint256 amount)`: approves LP, calls `requestWithdraw(address(this), amount)`, then `ADAPTER.submit(requestId)`. `claimWithdraw(uint256 tokenId)`: claims NFT, then best-effort `ADAPTER.remove`. |
| `src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol` | `depositTo(poolAddress, amount, trancheId, requestTokenId)` L55; `withdraw(tokenId, withdrawStake, withdrawRewards, trancheIds[])` L80 (+ overload L106); `depositTo(amount, trancheId, requestTokenId, destination)` L102. Immutables `NXM`, `TOKEN_CONTROLLER`. |
| `src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol` | `enterExitQueue(vault, shares)` L51; `claimExitedAssets(vault, positionTicket, timestamp, exitQueueIndex)` L73 |
| `src/balances/IMetaBalanceAdapter.sol` | `getAdapterPositionsForInstances(account, bytes32[] instances, assetFilter)`, `underlyingAssetsSupportedForInstances(bytes32[])` |
| `src/balances/IBalanceAdapter.sol` | `getAdapterPositions(account, assetFilter)` L18, `getAdapterBalances` L28, `getAdapterBalanceForAsset` L38, `underlyingAssetsSupported()` L46 |
| `src/balances/IPositionEnumerable` / `IPositionDescribable` | `positionIds()` L64; `protocolName()` L37; `positionLabels(bytes)` L55 |
| `src/balances/AssistedBalanceAdapters/IAssistedBalanceAdapter` | Extends `IAccessControl, IBalanceAdapter`. `SUBMITTER_ROLE()` L54, `submitFor` L60, `submitForBatch` L63, `removeFor` L68. |
| `test/utils/AssistantSafeRolesForkBase.sol` (124 lines) | Chain/block not set here (set per concrete test). Constants: `AVATAR_SAFE = 0xdE53bCdA6527D2aa15Ec733352C8d393C2E0eC99`, `MANAGER_SAFE = 0x9953f65e00cE71D7aA5A3f7889f63FEE0f1BA63c`, `ROLES_MODIFIER = 0xCEE06943E829367ff1Bd6B4670cb4a1148636d26` (L60), `TEST_ROLE = bytes32("ASSISTANT_FORK_TEST")`, `NATIVE_ETH = 0xEeee…EEeE`. `IRolesMod` L8-25 exposes `allowTarget(bytes32, address, ExecutionOptions)` (L25), `assignRoles(module, bytes32[], bool[])`, `execTransactionWithRole(to, value, data, Operation, roleKey, shouldRevert)`. Helpers: `_initManagerSafe()` (patches manager Safe as single owner via `SafeOverrides`), `_permitDelegatecall(assistant)` (pranks AVATAR to `allowTarget(TEST_ROLE, assistant, DelegateCall)` L95 and `assignRoles(MANAGER_SAFE)`), `_managerDelegatecall(assistant, data)` (manager Safe `execTransaction` → Roles `execTransactionWithRole` DelegateCall). |
| `test/balances/AssistedBalanceAdapters/assistants/fork/EtherFiWithdrawalQueueAssistantSafeRoles.fork.t.sol` (78 lines) | `FORK_BLOCK = 25_410_000` (L26), `eth-mainnet` via Alchemy (L51). Fork-funded eETH from whale `0xCd5f…b7ee`. Calls `_permitDelegatecall`, then `_managerDelegatecall(…requestWithdraw(9 ether))`. |
| `script/deploy/preflight/seed_assisted.py` | Discovery of Safe positions via call-trace (Roles module + delegatecall assistant). `SAFE_EXEC_SELECTORS` L165. |
| `script/config/chains/<chainId>.json` | `addresses.{admin, manager, securityCouncil}`. `REQUIRED_ROLES` at `preflight_config.py:54`. |

## Architecture

- **Registry (global, per chain):** `NAVCalculator` (UUPS proxy) → `Balances` (adapter list, meta-instance sets, claim map) → `NAVRegistryLib` (external library via DELEGATECALL, enforces claim rules and default-adapter arming). `Prices` / `PriceFeedLib` handle asset pricing.
- **Valuation:** `getAccountNav` → `PriceFeedLib._queryAllAdapters` → per-adapter `try getAdapterPositions{gas: stipend}`. Meta-adapters pull their instance set back from `NAVCalculator.getMetaInstances(self)` and fan out. `account` filters positions, not the adapter or instance set.
- **Default adapter (ERC20Default):** reports every registered asset unless excluded. Taking a coordinate into a meta-adapter removes it from the default adapter (`_excludeIfAsset`). Releasing does not re-add it.
- **Assisted families:** `AssistedCoordCache` (per-account coordinates, `msg.sender`-keyed mutators) is fed by delegatecall assistants that the Safe runs through the Zodiac Roles modifier. Keeper path: `submitFor` gated by `SUBMITTER_ROLE`. Values are read live from the protocol on every call.
- **Permissions path:** Safe (avatar) → Zodiac Roles modifier → `allowTarget(roleKey, assistant, DelegateCall)` + `assignRoles(member)`. Manager Safe is a role member. The repo has no code that writes these permissions. Only the fork harness does.

## Extract 1: NAVCalculator + Balances registry

- **Mutators:** all MANAGER-gated (`_requireManager()` at `NAVCalculator.sol:816`; `MANAGER` at `constants.sol:14`). Admin-only: `_authorizeUpgrade` / DEFAULT_ADMIN_ROLE checks at L416, L785.
- **Registration validation:** `addMetaInstances` requires `isAdapterRegistered` and `supportsInterface(IMetaBalanceAdapter)`. Duplicates fail on the claim map or on the adapter's own set.
- **Removal:** `removeBalanceAdapters(address[])` plural only is exposed. `removeBalanceAdapter` clears the meta instances (#335). Reverts on ERC20Default and on unregistered adapters.
- **Per-account state:** none in NAV. `getAccountNav*` only filter positions by `account`.
- **Storage:** `_metaInstanceTotal` is retired and not consumed. Slot kept for proxy layout. `_claimant` is new storage that starts empty on upgraded proxies; `_claim` scans the own set to compensate.
- **Chains:** NAVCalculator comment (`NAVCalculator.sol`, near L140) says "already deployed on 24 chains." [UNVERIFIED against deployments JSON; not counted]

## Extract 2: Adapter interfaces

- `IBalanceAdapter`: `getAdapterPositions`, `getAdapterBalances`, `getAdapterBalanceForAsset`, `underlyingAssetsSupported`.
- `IMetaBalanceAdapter`: adds the instance-scoped variants. Meta-adapters implement `_instancePositions`, `_instanceAssets`, `_instancePositionId`, `_protocolBrand/_protocolId/_protocolSubId`.
- `IAssistedBalanceAdapter`: `SUBMITTER_ROLE`, `submitFor`, `submitForBatch`, `removeFor`. Marker interface.
- `IAttestedBalanceAdapter`: marker for `MerklRewardsAttestedBalanceAdapter` (not read in this session).
- Identity: `PositionBalance` fields listed in `CLAUDE.md`; schema doc at `docs/howto/position-identity-schema.md` (not re-read).

## Extract 3: Assistants and fork harness

- Assistants are stateless. All entrypoints are `onlyDelegateCall` (checked against `SELF`). The adapter sees `msg.sender = Safe`.
- Fork harness `AssistantSafeRolesForkBase` runs against the LIVE Roles modifier at `ROLES_MODIFIER`, pranking the avatar Safe to grant `DelegateCall` to a freshly deployed assistant for `TEST_ROLE`.
- Fork blocks, all `eth-mainnet`:

| Test | Block | Source |
|---|---|---|
| EtherFi (SafeRoles) | 25_410_000 | `EtherFiWithdrawalQueueAssistantSafeRoles.fork.t.sol:26` |
| Nexus (SafeRoles) | 25_388_000 | `NexusMutualStakingPoolsAssistantSafeRoles.fork.t.sol:32` |
| StakeWise (SafeRoles) | 25_440_928 | `StakeWiseV3ExitQueueAssistantSafeRoles.fork.t.sol:30` |

- The harness uses only three Roles calls: `allowTarget`, `assignRoles`, `execTransactionWithRole`. No function-level scoping (`scopeAllowFunction`) appears in the harness, so the test does not show how production limits selectors. [UNVERIFIED for production]

## Extract 4: Existing per-fund / protocol registry / permission data

- **Per-fund config:** none found.
- **Protocol registry:** none. The closest are `ProtocolIds.sol` constants and `script/config/nav-config/*` (assets, adapters, meta-adapters, per chain). These are chain-level, not fund-level.
- **Permission data:** none in the repo. Roles allow-list is documented as an out-of-repo production property (ADR 0015 amendment; ADR 0018; ADR 0030 S11; `src/balances/AssistedBalanceAdapters/README.md` §5.0).
- **Deployment inputs:** `script/config/contracts-deployment-config/{balance-adapters, meta-balance-adapters}/<chainId>.json` list adapters; `script/config/nav-config/{balance-adapters, meta-balance-adapters}/<chainId>.json` list registrations; `script/config/deployments/<chainId>.json` holds addresses. These are the closest things to a coverage manifest, and they are global per chain.

## Extract 5: Where a FundConfig could hook in

1. **Accounting side.** `06_Configure.s.sol` (EOA broadcast) and the `NAVCalculator` MANAGER mutators are the registration surface. A FundConfig could generate the arguments for `addBalanceAdapters`, `addMetaBalanceAdapter`, and `addMetaInstances`. Caveat: this is global. Adding an instance changes valuation for every account, not just the fund's Safe.
2. **Per-fund valuation.** Options that exist today:
   - `getAccountNavForAdapters(account, quote, adapters[])` restricts the adapter loop, but `validateAdapterSlice` only checks membership, not coverage. Coverage is a caller contract (CLAUDE.md: cover `getAllAdapters()` once).
   - A separate `NAVCalculator` deployment per fund (no code path supports this today).
   - A new per-account selection layer (does not exist).
3. **Permission side.** The Roles modifier is the only place the Safe's permitted calls live. A FundConfig could emit `allowTarget` / `assignRoles` / scoped selectors. Nothing in this repo does that today.
4. **Consistency hook.** The assisted families already rely on the roles allow-list for completeness (ADR 0018). A FundConfig that derives both sides would move that property from out-of-repo to derived-in-repo, but would require a per-fund view of which adapters and instances are active, which the registry does not expose per account.
5. **Upgrade shape.** `NAVCalculator` is a UUPS proxy; `Balances` layout is pinned (`__balancesGap[47]`). Any per-account registry field would need a gap-consistent addition (see the `_gap` note at `NAVCalculator.sol:~94-103`).

## Gaps and unverified items

- `_requireManager` body (`NAVCalculator.sol:816`) not read. Role check assumed from the `MANAGER` constant. [UNVERIFIED]
- `_registerAdapter` ERC165 check (`NAVRegistryLib.sol:264+`) not read. [UNVERIFIED]
- `MetaBalanceAdapter._positionsForInstances` body not read. [UNVERIFIED]
- Production Roles permission set: not in repo. [UNVERIFIED]
- Zodiac `ModuleProxyFactory`, Roles v2 scoping (`scopeAllowFunction`, `scopeTarget`) exist only as external dependencies here. [UNVERIFIED]
- Gas numbers: the stipend math is source-verified (63/64 and 7/8 threshold), but no gas measurements were taken. [UNVERIFIED] for real-world costs.
- Chain count "24" is from a code comment, not from `script/config/deployments`. [UNVERIFIED]

## Blocker

- No write tool is available in this session, so the file `local://repo-accounting-map.md` was not created. The content above is the complete deliverable and should be saved by the main agent, or by a session with write access.