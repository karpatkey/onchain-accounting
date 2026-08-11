// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title IAssetKindRegistry
/// @author KPK
/// @notice The two-axis kind classification for assets — what the price tracks ({PegKind}) and how value accrues
///         ({AccrualKind}) — plus the ATOMIC write facade for registering an asset and classifying it in one call.
/// @dev **Only ONE axis is stored.** `AccrualKind` is state; `PegKind` is DERIVED on read from the NAV's
///      `pegToleranceBps`, the switch that enables the absolute-$1 price guard. So there is exactly one authority on
///      whether an asset is worth $1, and a STORED peg claim contradicting the pricing layer is not merely detectable — it is
///      unwriteable, because there is no stored peg. (The narrower true statement: an operator CAN still produce a
///      `Pegged + Appreciating` reading by setting a peg tolerance on an appreciating asset — see {AccrualKind}.) `getAssetKind` still returns both axes, so callers see a complete classification.
///
///      **The facade is the point.** {registerAsset} takes the accrual kind as a parameter of the register action, stores it,
///      and forwards to `NAVCalculator.registerAsset` in the same transaction; {unregisterAsset} is symmetric. So a
///      registered asset is always classified by construction. Callers use the same arguments they used on the NAV plus
///      TWO (the accrual axis and the display labels), and call this address instead.
///
///      **The display labels are a THIRD axis and behave differently from the other two on purpose.** Both kinds are
///      re-settable by their own setters; labels are written by {registerAsset} and replaced by {setAssetLabels}, and
///      by nothing else — {setAssetKind}/{setAssetKinds} still do not take them, because classification and
///      labelling are separate axes. An asset registered without labels has none until {setAssetLabels} gives it
///      some (or it is unregistered and registered again).
///
///      **That boundary USED to be write-once, chosen for parity with the balance adapters. The parity argument is
///      retired.** It ran: adapter labels (`positionLabels()`) are fixed when the adapter is deployed and no role can
///      change them, so letting an ASSET gain labels after registration would demand the same editability for
///      adapters. It was dropped because the two are not the same kind of value — an adapter label is a compile-time
///      constant OF THE CODE, an asset label is operator-supplied DATA — and because the write-once repair path was
///      far more destructive than it looked (see {setAssetLabels}). **Adapter labels are unchanged and remain
///      redeploy-to-change**; only the asymmetry argument is gone. An empty label list remains a legitimate state.
///      See {registerAsset}, {setAssetLabels} and {getAssetLabels}.
///
///      **No roles.** Implementations gate on `NAV.hasRole(MANAGER, msg.sender)` — authority is exactly the NAV's
///      MANAGER set, and this contract has no admin, manager or owner of its own.
/// @dev **Fail-closed by design.** There is no default classification. Reading an asset that has not been classified
///      REVERTS {AssetNotClassified} rather than returning a default, because `AccrualKind.None` is a
///      plausible-looking answer that is wrong for many assets (and note the peg half is DERIVED, so an unguarded read
///      would report `Floating` for an unconfigured asset, not `Pegged`) — a silent default here would
///      be indistinguishable from real data, which is the failure mode the repo's fail-closed guards exist to avoid.
///      Callers that need to probe without reverting use {isClassified}.
///
///      **⚠️ Implementations revert with errors this interface does NOT declare, so this ABI is not a complete error
///      set.** A consumer generating handlers from `IAssetKindRegistry` alone cannot decode them:
///      - `InvalidArguments()` — from `src/errors.sol`, a shared repo-wide error. Thrown by BOTH setters when
///        `asset == address(0)` — including through {registerAsset}, which calls the same internal setter — and by the
///        constructor when `nav` is `address(0)`. Selector:
///        `bytes4(keccak256("InvalidArguments()"))`.
///      - `NotAuthorized()` — from `src/errors.sol`, thrown by the `NAV.hasRole(MANAGER, …)` gate on every mutator.
///        Note the NAV can ALSO revert its own `NotAuthorized()` on the forwarded hop if the REGISTRY has not been
///        granted `MANAGER` on it (`08` does this); the two are indistinguishable by selector.
///        Implementations hold no `AccessControl`, so the OpenZeppelin role errors do NOT appear here.
///
///      This note lives on the interface declaration rather than beside the error list because a NatSpec block that
///      floats between two members attaches to neither and is dropped from `devdoc` entirely — i.e. it would be absent
///      from exactly the generated documentation its audience reads.
interface IAssetKindRegistry {
    /// @notice Emitted when an asset's STORED classification (the accrual axis) is set or changed.
    /// @dev Carries only the stored axis. The peg axis is derived from the NAV on read and can legitimately change
    ///      afterwards, so emitting it here would hand indexers a snapshot that silently goes stale.
    event AssetKindSet(address indexed asset, AccrualKind accrualKind);

    /// @notice Emitted when an asset's classification is removed (e.g. the asset was unregistered upstream).
    event AssetKindCleared(address indexed asset);

    /// @notice Emitted when an asset's display labels are written, by either {registerAsset} or {setAssetLabels}.
    /// @dev **Consumers must NOT infer a re-registration from a repeat.** This event once fired at most once per
    ///      registration, so a second one for the same asset meant it had been unregistered and registered again.
    ///      {setAssetLabels} broke that: a repeat now most likely means a label was CORRECTED in place, with the
    ///      asset's price feeds, monitor feeds and `_assetPricing` (both tolerances, and so the derived `PegKind`)
    ///      completely untouched. An indexer still reading the old contract would invalidate all of that on a typo
    ///      fix. Distinguish the two by watching {AssetKindCleared}/`AssetUnregistered`, not by counting these.
    ///      The payload is the full replacement array, not a delta, in both cases.
    event AssetLabelsSet(address indexed asset, string[] labels);

    /// @notice Emitted when an asset's display labels are dropped, which happens only at {unregisterAsset}.
    /// @dev Separate from {AssetKindCleared} because the two have different lifetimes on purpose: {clearAssetKind}
    ///      ends the CLASSIFICATION and leaves labels alone, while unregistering ends the REGISTRATION and takes the
    ///      labels with it. An indexer that treated the kind event as covering both would keep serving labels for an
    ///      asset the NAV no longer knows about.
    event AssetLabelsCleared(address indexed asset);

    /// @notice Emitted when a balance adapter's `protocolName()` override is written or replaced.
    /// @dev The payload is the full replacement string, never a delta. Absence of an override is not observable from
    ///      this event alone — pair it with {AdapterProtocolNameCleared}.
    event AdapterProtocolNameSet(address indexed adapter, string name);

    /// @notice Emitted when a balance adapter's `protocolName()` override is removed and the adapter's own reply
    ///         becomes authoritative again.
    event AdapterProtocolNameCleared(address indexed adapter);

    /// @notice Emitted when a balance adapter's per-segment `positionLabels()` override is written or replaced.
    /// @dev The payload is the full replacement array, never a delta, and it carries the `""` skip sentinels verbatim
    ///      — an indexer must reproduce the read path's rule (overlay only where the element is non-empty) rather
    ///      than treating every element as a value. Absence of an override is not observable from this event alone;
    ///      pair it with {AdapterLabelsCleared}.
    event AdapterLabelsSet(address indexed adapter, string[] labels);

    /// @notice Emitted when a balance adapter's per-segment label override is removed and every segment reverts to
    ///         what the adapter itself reports.
    event AdapterLabelsCleared(address indexed adapter);

    /// @notice The asset has no classification.
    /// @dev Thrown on the READ path ({getAssetKind}, {getAssetKinds}) so reads fail closed rather than defaulting, AND
    ///      on the WRITE path by {clearAssetKind} when the asset was never classified. Both, deliberately — clearing
    ///      something that is not there is a config mistake worth surfacing, not a no-op.
    error AssetNotClassified(address asset);

    /// @notice A SETTER was called for an address the NAV does not hold as a balance adapter.
    /// @dev Guards the setters only, never the clearers. An override on a typo'd address is dead data that no read
    ///      path would ever consult, so it would fail silently — exactly the class of mistake
    ///      {AssetNotRegisteredForLabels} exists to catch on the asset side. Both plain and meta adapters set the
    ///      NAV's registration map (`NAVRegistryLib._registerAdapter` is shared by `addBalanceAdapters` and
    ///      `addMetaBalanceAdapter`), so this accepts every adapter family.
    ///
    ///      **Deliberately NOT on the clearers.** Guarding those would strand an override whose adapter has since
    ///      been unregistered: unreadable, yet impossible to remove. That is the stranding hazard the asset-label
    ///      path documents at {AssetNotRegisteredForLabels}, avoided here rather than reproduced.
    error AdapterNotRegistered(address adapter);

    /// @notice An override was supplied that would read back as absence: `""` for {setAdapterProtocolName}, or — for
    ///         {setAdapterLabels} — an empty array, or an array whose every element is `""`.
    /// @dev `""` is the MISS sentinel on the read path — {PriceFeedLib} treats an empty reply as "no override" and
    ///      falls back to the adapter. So storing one would be a write that reads back as absence, and a caller
    ///      trying to clear via `set(adapter, "")` would get silence instead of the clear it asked for. Use
    ///      {AssetKindRegistry.clearAdapterProtocolName} / {AssetKindRegistry.clearAdapterLabels} instead.
    ///
    ///      The array case covers both no-op shapes with one exit, because they are the same mistake: an override
    ///      with no non-empty element overlays nothing at any index, so it is indistinguishable from never having
    ///      been set. Note this is NOT a ban on `""` ELEMENTS — those are the per-segment skip sentinel and are the
    ///      normal way to leave a computed leaf alone. It is a ban on an array in which every element is one.
    error EmptyAdapterOverride(address adapter);

    /// @notice More segments were supplied for one adapter's label override than
    ///         {AssetKindRegistry.MAX_ADAPTER_LABEL_SEGMENTS}.
    /// @dev Not a read-path bound: the overlay applies only within the adapter's own reply, so extra segments are
    ///      inert rather than dangerous. This bounds the operator's own gas and this contract's storage.
    error TooManyAdapterLabels(address adapter, uint256 count, uint256 max);

    /// @notice One segment of an adapter's label override is longer than {AssetKindRegistry.MAX_ASSET_LABEL_BYTES}.
    /// @dev `length` is in BYTES, not characters. Carries the `index` — unlike the scalar {AdapterOverrideTooLong} —
    ///      because with eight candidate segments "one of them is too long" is not an actionable error.
    error AdapterLabelTooLong(address adapter, uint256 index, uint256 length, uint256 max);

    /// @notice A label override is longer than {AssetKindRegistry.MAX_ASSET_LABEL_BYTES}.
    /// @dev `length` is in BYTES, not characters. Shares the asset-label bound because it is the same kind of value
    ///      rendered in the same breadcrumb, and because the read path's copy window is sized for it.
    error AdapterOverrideTooLong(address adapter, uint256 length, uint256 max);

    /// @notice A clearer was called for an adapter that has no override of that kind.
    /// @dev Reverts rather than no-oping, matching {clearAssetKind}: clearing something that is not there is a config
    ///      mistake worth surfacing.
    error AdapterOverrideNotSet(address adapter);

    /// @notice Error when {setAssetLabels} is called for an asset the NAV does not hold.
    /// @dev Named distinctly from the shared `AssetNotRegistered(string)` in `src/errors.sol`, which this contract
    ///      imports globally and which keys on symbol rather than address.
    /// @param asset The asset whose labels were being set.
    error AssetNotRegisteredForLabels(address asset);

    /// @notice Error when {setAssetLabels} is called with an empty array.
    /// @dev Clearing labels outright is what {unregisterAsset} does as part of ending a registration; a setter that
    ///      silently did nothing would report success for a request it did not honour.
    /// @param asset The asset whose labels were being set.
    error EmptyAssetLabelSet(address asset);

    /// @notice A batch setter was given arrays of differing lengths.
    error KindArrayLengthMismatch(uint256 assets, uint256 accrualKinds);

    /// @notice More labels were supplied for one asset than {AssetKindRegistry.MAX_ASSET_LABELS}.
    error TooManyAssetLabels(address asset, uint256 count, uint256 max);

    /// @notice One supplied label is longer than {AssetKindRegistry.MAX_ASSET_LABEL_BYTES}.
    /// @dev `length` is in BYTES, not characters — a multi-byte glyph costs more than one.
    error AssetLabelTooLong(address asset, uint256 index, uint256 length, uint256 max);

    /// @notice One supplied label is the empty string.
    /// @dev An empty LIST is legitimate — an asset may simply have no labels. An empty ELEMENT inside a non-empty list
    ///      is a config mistake: it renders as nothing while still occupying an ordered slot, so it silently shifts
    ///      every later label's meaning. Rejected for that reason, not for tidiness.
    error EmptyAssetLabel(address asset, uint256 index);

    /// @notice Registers an asset on the NAV **and** classifies it, atomically, in one call. Gated on the NAV's
    ///         `MANAGER`. This is the intended entry point for adding an asset.
    /// @dev The first four parameters are forwarded verbatim to `NAVCalculator.registerAsset`; the single kind
    ///      parameter is stored here. There is no `try`/`catch` on this path, so if EITHER half reverts the whole transaction
    ///      reverts and neither the registration nor the classification takes effect.
    ///
    ///      Calling `NAVCalculator.registerAsset` directly remains possible for any MANAGER and is not prevented in
    ///      code. Whether it stays possible is a deploy-time role decision (revoking `MANAGER` from humans on the NAV
    ///      makes this facade the only path, and the invariant structural rather than conventional) — deliberately not
    ///      forced here, so the choice stays with the operator at zero cost.
    ///
    ///      **Labels can be set here or by {setAssetLabels}, and nowhere else.** {setAssetKind} and
    ///      {setAssetKinds} still do not take them — classification and labelling are separate axes.
    ///
    ///      **This call remains the place to set them, and the reason is atomicity, not exclusivity.** Carrying
    ///      labels on the registration keeps them in the same transaction as the asset entering the system; a
    ///      separate call is a second transaction that can fail to land while this one does, which is the class of
    ///      silent divergence `08_DeployAssetKindRegistry`'s docstring is largely about. Use {setAssetLabels} to
    ///      CORRECT labels afterwards, not to set them initially.
    ///
    ///      **The old parity argument for making labels write-once is retired, on purpose.** It ran: adapter labels
    ///      (`positionLabels()`) are fixed at deploy time and no role can change them, so letting an asset gain
    ///      labels after registration would demand adapter labels become MANAGER-editable too. That was rejected
    ///      because the two are not the same kind of value — an adapter label is a compile-time constant OF THE
    ///      CODE, an asset label is operator-supplied DATA — and because the write-once repair path was far more
    ///      destructive than it looked: unregister-then-re-register also drops every price feed, every monitor feed
    ///      and all of `_assetPricing` (both tolerances, one of which `PegKind` is derived from), across up to five
    ///      transactions on an EOA MANAGER with the asset absent from NAV throughout. Adapter labels are unchanged
    ///      and remain redeploy-to-change.
    function registerAsset(
        address asset,
        address priceFeed,
        IPrices.PriceType priceType,
        uint256 chainlinkHeartbeat,
        AccrualKind accrualKind,
        string[] calldata labels
    ) external;

    /// @notice Unregisters an asset from the NAV, clears its classification **and drops its labels**, atomically. The
    ///         mirror of {registerAsset}. Gated on the NAV's `MANAGER`.
    /// @dev Idempotent on the kind: an asset registered directly on the NAV has no classification, and this must still
    ///      unregister it, so a missing kind is skipped rather than reverting. Contrast {clearAssetKind}, which DOES
    ///      revert on an unclassified asset because there the clear is the caller's whole intent.
    ///
    ///      **Dropping the labels here keeps the registration and its labels on one lifetime.** It also used to be
    ///      what made the only available repair work: before {setAssetLabels} existed, a wrong label was fixed by
    ///      unregistering and re-registering, and had labels outlived unregistration that repair would have been a
    ///      silent no-op. **Correcting a label no longer needs this path** — use {setAssetLabels}, which leaves the
    ///      asset's price feeds, monitor feeds and `_assetPricing` intact. This path remains correct for ending a
    ///      registration outright.
    function unregisterAsset(address asset) external;

    /// @notice Replaces one registered asset's display labels. MANAGER-gated, like every other write here.
    /// @dev Exists so a wrong label can be corrected WITHOUT unregistering the asset. The previous repair —
    ///      unregister then re-register — also destroyed every price feed, every monitor feed and all of
    ///      `_assetPricing` (divergence AND peg tolerance, the latter being what {getAssetKind} derives `PegKind`
    ///      from), took up to five transactions on an EOA MANAGER, and left the asset absent from NAV in between.
    /// @dev Reverts {AssetNotRegisteredForLabels} if the NAV does not hold `asset`; labels are registration-scoped
    ///      and nothing on this contract could ever clear ones written for an asset it does not hold.
    /// @dev Reverts {EmptyAssetLabelSet} on an empty array — use {unregisterAsset} to end a registration.
    /// @dev The content bounds are the registration ones exactly: {TooManyAssetLabels}, {EmptyAssetLabel},
    ///      {AssetLabelTooLong}. Emits {AssetLabelsSet}, the same event registration emits.
    /// @param asset The registered asset whose labels are being replaced.
    /// @param labels The replacement labels, in significant order. Replaces the existing set wholesale.
    function setAssetLabels(address asset, string[] calldata labels) external;

    /// @notice Classifies one asset. MANAGER-gated. Re-classification is allowed and emits again.
    /// @dev Reverts `InvalidArguments()` if `asset` is `address(0)` — this repo's USD-quote sentinel, never a
    ///      registered asset. That error is not declared in this interface; see the contract-level note.
    ///
    ///      **Deliberately takes no labels.** Classification and labelling are separate axes: labels are written by
    ///      {registerAsset} and {setAssetLabels} only. Re-classifying an asset leaves its labels exactly as they are.
    function setAssetKind(address asset, AccrualKind accrualKind) external;

    /// @notice Classifies many assets in one call. MANAGER-gated. Both arrays must be the same length.
    /// @dev Reverts {KindArrayLengthMismatch} if the lengths differ, and `InvalidArguments()` on the first
    ///      `address(0)` entry. An empty batch is a no-op, not an error.
    ///
    ///      **Deliberately takes no labels**, for the reason given on {registerAsset}. That also means a re-run of
    ///      `08_DeployAssetKindRegistry` cannot disturb them: it re-classifies and never touches a label.
    function setAssetKinds(address[] calldata assets, AccrualKind[] calldata accrualKinds) external;

    /// @notice Removes an asset's classification, so subsequent reads fail closed again. MANAGER-gated.
    /// @dev Reverts {AssetNotClassified} if the asset had no classification to remove.
    ///
    ///      **Labels SURVIVE this call, unlike {unregisterAsset}, and the difference is not an inconsistency.** The two
    ///      look interchangeable from outside and are not: labels are tied to REGISTRATION, not to classification.
    ///      This ends the classification while the asset stays registered on the NAV, so its labels still describe a
    ///      live asset and are kept. {unregisterAsset} ends the registration, so they go. Label lifetime is exactly
    ///      registration lifetime.
    function clearAssetKind(address asset) external;

    /// @notice One asset's classification. Reverts {AssetNotClassified} if it has none.
    function getAssetKind(address asset) external view returns (PegKind pegKind, AccrualKind accrualKind);

    /// @notice One asset's display labels, in significant order. Never reverts — an unlabelled or unclassified asset
    ///         returns an empty array.
    /// @dev **Order is meaningful and the list is not a set.** Index 0 is the protocol or issuer; later indices narrow
    ///      to the product or kind — `["Aave V3", "Savings"]`, `["Lido", "LST"]`. That broad-to-narrow ORDER is how
    ///      `protocolName()` and `positionLabels()` compose, but the CONTENT differs: these labels carry the protocol
    ///      at index 0, which `positionLabels()` never does. The content is FREE TEXT; nothing on-chain parses it.
    ///
    ///      **An empty result is a legitimate answer, not an error.** `positionLabels()` already returns empty arrays
    ///      legitimately, so this has precedent — an asset with no labels is unlabelled, not misconfigured, and this
    ///      getter deliberately does not revert the way {getAssetKind} does. That is the one place the two axes differ:
    ///      there is no defensible default classification, but "no labels" IS the honest answer.
    ///
    ///      **Labels are written by {registerAsset} and replaced by {setAssetLabels}.** An asset registered without
    ///      them stays unlabelled until {setAssetLabels} gives it some.
    ///
    ///      **Repairing a wrong label is one MANAGER call to {setAssetLabels}**, which leaves the asset's price feeds,
    ///      monitor feeds and `_assetPricing` (both tolerances, and so the derived `PegKind`) untouched. This block
    ///      previously sent readers to unregister-then-re-register instead, which is destructive — it drops all of
    ///      that — and is now needed only to END a registration, never to fix a display string.
    function getAssetLabels(address asset) external view returns (string[] memory labels);

    /// @notice One asset's complete public description — both classification axes and its display labels — in a single
    ///         call. Reverts {AssetNotClassified} if the asset has no classification.
    /// @dev **This is the shape the `NAVCalculator` forwards**, so a consumer needs one entry point and one call rather
    ///      than three. `labels` may be empty; that is a real answer, not a gap. The classification half fails closed
    ///      exactly as {getAssetKind} does — an unclassified asset reverts rather than reporting a default, because
    ///      `AccrualKind.None` is a real classification and would be indistinguishable from a configured reply.
    function getAssetInfo(address asset)
        external
        view
        returns (PegKind pegKind, AccrualKind accrualKind, string[] memory labels);

    /// @notice Many assets' classifications, index-aligned with `assets`.
    /// @dev Reverts {AssetNotClassified} naming the FIRST unclassified asset. A batch is all-or-nothing on purpose:
    ///      returning zero values for the gaps would hand the caller the exact silent default this registry refuses.
    function getAssetKinds(address[] calldata assets)
        external
        view
        returns (PegKind[] memory pegKinds, AccrualKind[] memory accrualKinds);

    /// @notice Whether `asset` has a classification. The non-reverting probe for {getAssetKind}.
    function isClassified(address asset) external view returns (bool);

    // ---------------------------------------------------------------------------------------------------------------
    // Balance-adapter display overrides
    //
    // A ≤45-row, per-ADAPTER table that lets an operator correct an adapter's display strings — its protocol name and
    // any segment of its `positionLabels()` breadcrumb — without redeploying and re-registering it.
    //
    // **Any DEPTH is reachable, and `""` is how a segment is left alone.** {setAdapterLabels} takes an array that is
    // index-aligned with the adapter's own reply and overlays element-by-element; `""` at an index means "do not
    // touch that segment". So `["Lending Market", ""]` corrects a meta-adapter's category and leaves its computed
    // leaf derived live, while `["Withdrawal Queue", "Lido stETH"]` replaces both segments of an adapter whose leaf
    // is itself a literal. (The predecessor could only write index 0. It was removed rather than kept alongside this
    // — see {AssetKindRegistry}'s note on `_adapterLabels` for why two stores for one display value was rejected.)
    //
    // **What is possible is wider than what is advisable, and the mechanism does not police the difference.** Two
    // classes of segment should normally be given `""`:
    //
    //   1. **A COMPUTED segment.** 21 of the 33 deployable adapters derive their leaf from live on-chain state
    //      (`UniswapV3PoolsMetaBalanceAdapter` builds `"WETH/USDC 0.05%"` from live `token0()` / `token1()` / `fee()`
    //      probes; `FluidVaultsMetaBalanceAdapter` reads `vaultInfo` plus the registered-asset array). A stored value
    //      freezes a derivation that IS the feature, is stamped onto EVERY instance of a meta-adapter, does not track
    //      `addMetaInstances`, and cannot fix the actual failure mode — a wrong leaf means the DERIVATION is wrong
    //      across every instance, which a per-row override masks one row at a time.
    //   2. **A segment that varies BY POSITION.** These overrides are keyed by ADAPTER precisely so that no
    //      per-position bookkeeping exists to drift, which means a per-adapter row cannot express a per-position
    //      value: one write rewrites every position of that adapter. Exactly one adapter used to be in this state at
    //      a LITERAL segment — the combined `CapBalanceAdapter`, at both indices — and it was split into
    //      `CapStablecoinBalanceAdapter` / `CapSavingsBalanceAdapter` rather than papered over here.
    //
    // `src/balances/BALANCE_ADAPTERS.md` §6.2 carries the per-adapter, per-segment sweep that says which index is
    // which. Neither class is detectable on-chain — this contract sees an array, not the adapter's source — so both
    // are operational guidance, and both are asserted as documented hazards in `AdapterLabelOverrides.t.sol`.
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Overrides what `getAccountPositionsVerbose` reports as `protocolName` for every position of `adapter`.
    /// @dev Additive: with no override set, the read path staticcalls the adapter exactly as before, so **no deployed
    ///      adapter is touched or redeployed**. Gated on the NAV's `MANAGER`. Reverts {AdapterNotRegistered} for an
    ///      address the NAV does not hold, {EmptyAdapterOverride} for `""` (the miss sentinel), and
    ///      {AdapterOverrideTooLong} beyond {AssetKindRegistry.MAX_ASSET_LABEL_BYTES}. Emits {AdapterProtocolNameSet}.
    ///
    ///      ⚠️ **This can break an invariant the code alone previously guaranteed, and nothing on-chain stops it.**
    ///      {IPositionDescribable.protocolName} requires every adapter sharing a `ProtocolIds` protocol id to return
    ///      the SAME string, because consumers group configured adapters by it — the failure it prevents is an adapter
    ///      splitting itself out into a phantom sibling protocol. `test/ProtocolNameConsistency.t.sol` pins that over
    ///      adapter CODE and is unaffected by this override, which is precisely the gap: overriding one adapter of a
    ///      protocol and not its siblings re-creates the phantom-sibling split at the DISPLAY layer, where that test
    ///      cannot see it. This registry cannot check it either — it holds no view of any adapter's protocol id.
    ///      **When a protocol has several adapters, override all of them or none.**
    ///
    ///      **Both NAV display surfaces apply this override, and they agree by construction.** The account path
    ///      (`getAccountPositionsVerbose` / `…ForAssetVerbose` / `getAccountNavVerbose`, via
    ///      {PriceFeedLib.toVerbose}) and the CONFIGURATION path (`NAVCalculator.getAdapterDisplayInfo`, via
    ///      `PriceFeedLib.adapterDisplayInfo`) both resolve precedence through the same private helper, so they
    ///      cannot report different names for one adapter — that is a structural property, not two implementations
    ///      that happen to match.
    ///
    ///      ⚠️ **The one place an override is still invisible: a consumer that BYPASSES the NAV entirely.** If a
    ///      caller lists `IBalances.getAllAdapters()` and then staticcalls `protocolName()` on each adapter itself,
    ///      it is reading the adapter's immutable constant and no override can reach it — nothing on-chain can
    ///      intercept a direct call to a third-party contract. {IPositionDescribable.protocolName} explains why that
    ///      matters: enumerating consumers never see the typed `protocolBrand`/`protocolId`, so the display name is
    ///      the only protocol identity they have, and it is their join key. **The remedy is to call
    ///      `getAdapterDisplayInfo(getAllAdapters())` instead of staticcalling the adapters**, which is exactly why
    ///      that function exists.
    ///
    ///      (An earlier revision of this note said closing the split "would mean a NAV-side forwarding getter
    ///      (+182 B against 455 free — not affordable)". That estimate was wrong in both directions and is recorded
    ///      here so the correction is not lost: the real cost was **+354 B** — the nested `string[][]` return costs
    ///      far more ABI surface than the +182 B floor quoted for a flat forwarding read — and it was nonetheless
    ///      affordable. See {NAVCalculator.getAdapterDisplayInfo} for the current headroom, which is now thin.)
    ///      One operational note that applies to BOTH setters lives on {clearAdapterProtocolName}: overrides are
    ///      lost when the registry is replaced.
    /// @param adapter The balance adapter whose positions should report `name`.
    /// @param name The replacement protocol name, e.g. "Aave V3".
    function setAdapterProtocolName(address adapter, string calldata name) external;

    /// @notice Removes `adapter`'s protocol-name override; its own `protocolName()` becomes authoritative again.
    /// @dev Reverts {AdapterOverrideNotSet} when there is nothing to clear. Not guarded on registration, so an
    ///      override outlives its adapter's deregistration and stays removable. Emits {AdapterProtocolNameCleared}.
    ///
    ///      ⚠️ **Overrides live in the registry, so `NAVCalculator.setAssetKindRegistry` silently drops all of
    ///      them.** The registry is a plain, non-upgradeable contract, so replacing it means deploying a fresh one
    ///      with empty override maps: every corrected label reverts to the adapter's own constant on the next read,
    ///      with no revert, no event and no probe to notice. This is strictly quieter than the classification half,
    ///      which fails CLOSED on the same operation ({getAssetKind} reverts `AssetNotClassified` for an asset the
    ///      new registry has never seen), and the asymmetry is inherent rather than chosen: the read path MUST be
    ///      fail-open, so "no override" and "override lost" are necessarily the same observation. **Re-applying the
    ///      override set is part of replacing the registry**, and is not something the contracts can enforce.
    function clearAdapterProtocolName(address adapter) external;

    /// @notice Overrides `adapter`'s `positionLabels()` breadcrumb **segment by segment**, index-aligned with the
    ///         adapter's own reply. `""` at an index leaves that segment exactly as the adapter computed it.
    /// @dev ```
    ///      setAdapterLabels(morphoMeta, ["Lending Market", ""])            // category replaced, leaf still live
    ///      setAdapterLabels(lidoQueue,  ["Withdrawal Queue", "Lido stETH"]) // both segments are literals: both go
    ///      setAdapterLabels(convexMeta, ["Staking Position", "Curve Pool", ""])
    ///      ```
    ///
    ///      **The overlay applies only for `i < min(reply.length, labels.length)`, and BOTH halves of that bound are
    ///      load-bearing.**
    ///
    ///      - It cannot write past a SHORTER reply. That is not theoretical:
    ///        `ConvexCurveLPStakingMetaBalanceAdapter.positionLabels` returns 2 OR 3 elements depending on whether its
    ///        `rewarderCoinSymbols` probe answers, and most of the meta family returns 0, 1 or 2 depending on whether
    ///        the leaf read succeeded. Writing index `i` of a shorter array is `Panic(0x32)`, which would destroy the
    ///        never-revert property the whole label path is built on.
    ///      - It cannot LENGTHEN a reply either, which is what keeps `NAVCalculator`'s `_MAX_LABEL_ELEMENTS = 8`
    ///        ceiling unreachable from this side. A segment past the adapter's own reply is silently inert; if a
    ///        supplied segment does not appear, the adapter emitted fewer segments than you assumed.
    ///
    ///      **Which segments are safe to write is a property of the ADAPTER, and this contract cannot check it** — see
    ///      the section note above and the per-adapter sweep in `src/balances/BALANCE_ADAPTERS.md` §6.2. The one
    ///      adapter that must be left alone entirely is `ERC20DefaultBalanceAdapter`: its single segment is not a
    ///      category at all but the computed token symbol, so any override there replaces the leaf. It is asserted as
    ///      a documented hazard in `AdapterLabelOverrides.t.sol`, not prevented.
    ///
    ///      **A reply with NO segments is left empty on the POSITION path and GROWN on the CONFIGURATION path, and
    ///      that asymmetry is deliberate** — see `PriceFeedLib.adapterDisplayInfo`, where the reasoning lives. The
    ///      configuration path grows an empty reply to the override's LEADING NON-EMPTY PREFIX, so an override whose
    ///      element 0 is `""` grows nothing rather than shifting a deeper segment up to index 0.
    ///
    ///      Gated on the NAV's `MANAGER`. Reverts {AdapterNotRegistered} for an address the NAV does not hold,
    ///      {EmptyAdapterOverride} for an array with no non-empty element (the empty array included),
    ///      {TooManyAdapterLabels} past {AssetKindRegistry.MAX_ADAPTER_LABEL_SEGMENTS}, and {AdapterLabelTooLong} —
    ///      naming the index — for a segment over {AssetKindRegistry.MAX_ASSET_LABEL_BYTES}. Emits
    ///      {AdapterLabelsSet}. One operational note that applies to BOTH setters lives on
    ///      {clearAdapterProtocolName}: overrides are lost when the registry is replaced.
    /// @param adapter The balance adapter whose breadcrumb segments should be replaced.
    /// @param labels The per-segment replacements, index-aligned with the adapter's reply; `""` skips a segment.
    ///        Replaces the existing override wholesale.
    function setAdapterLabels(address adapter, string[] calldata labels) external;

    /// @notice Removes `adapter`'s per-segment label override; every segment it reports becomes authoritative again.
    /// @dev Reverts {AdapterOverrideNotSet} when there is nothing to clear. Emits {AdapterLabelsCleared}. Not guarded
    ///      on registration, for the same anti-stranding reason as {clearAdapterProtocolName}.
    function clearAdapterLabels(address adapter) external;

    /// @notice `adapter`'s protocol-name override, or `""` when none is set.
    /// @dev `""` is the miss sentinel the read path keys on, and is unambiguous because the setter rejects it.
    ///      **This is the selector {PriceFeedLib} staticcalls** on the verbose read path — changing its signature
    ///      changes that call site.
    function getAdapterProtocolName(address adapter) external view returns (string memory name);

    /// @notice `adapter`'s per-segment label override, or an EMPTY ARRAY when none is set.
    /// @dev An empty array is the miss sentinel here, which is why the setter refuses to store one. Individual `""`
    ///      ELEMENTS are meaningful and are returned verbatim — a caller reproducing the read path must skip them
    ///      rather than render them.
    ///
    ///      **This is the selector {PriceFeedLib} staticcalls** on both display paths (via `_labelOverride`), through
    ///      the same fail-open, gas-capped, output-windowed shim as everything else there — so changing its signature
    ///      changes that call site, and a registry that cannot answer it degrades to "no override".
    function getAdapterLabels(address adapter) external view returns (string[] memory labels);
}
