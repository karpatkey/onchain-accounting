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

    /// @notice The asset has no classification.
    /// @dev Thrown on the READ path ({getAssetKind}, {getAssetKinds}) so reads fail closed rather than defaulting, AND
    ///      on the WRITE path by {clearAssetKind} when the asset was never classified. Both, deliberately — clearing
    ///      something that is not there is a config mistake worth surfacing, not a no-op.
    error AssetNotClassified(address asset);

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
}
