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
///      re-settable; labels are write-once — they can be ADDED to an asset that has none, never CHANGED once set.
///      *You can fill a blank, never change a value.* An empty label list is a legitimate state, and an empty label
///      ARGUMENT means "leave them alone". See {getAssetLabels} for the full rule and the repair path.
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

    /// @notice Emitted when an asset's display labels are written. Fires ONCE per asset for the lifetime of the
    ///         registry — labels cannot be changed, so there is never a second event for the same asset.
    event AssetLabelsSet(address indexed asset, string[] labels);

    /// @notice The asset has no classification.
    /// @dev Thrown on the READ path ({getAssetKind}, {getAssetKinds}) so reads fail closed rather than defaulting, AND
    ///      on the WRITE path by {clearAssetKind} when the asset was never classified. Both, deliberately — clearing
    ///      something that is not there is a config mistake worth surfacing, not a no-op.
    error AssetNotClassified(address asset);

    /// @notice A batch setter was given arrays of differing lengths.
    error KindArrayLengthMismatch(uint256 assets, uint256 accrualKinds);

    /// @notice A batch setter was given a label array whose outer length does not match `assets`.
    /// @dev Separate from {KindArrayLengthMismatch} rather than folded into it: the two arrays fail for different
    ///      operator mistakes (a missed kind vs a missed label row) and a shared error would not say which.
    error LabelArrayLengthMismatch(uint256 assets, uint256 labels);

    /// @notice An attempt to CHANGE labels that are already set.
    /// @dev **The write-once rule, as an error rather than a silent overwrite.** Labels can be ADDED to an asset that
    ///      has none; they can never be CHANGED once set. See {getAssetLabels} for why, and for the repair path.
    ///
    ///      Thrown only when the supplied labels DIFFER from the stored ones. Re-supplying identical labels is a
    ///      no-op, which is what keeps `08_DeployAssetKindRegistry`'s idempotent re-run — the documented recovery for
    ///      a classification batch that never landed — from reverting the moment labels exist in config.
    error AssetLabelsAlreadySet(address asset);

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
    ///      **`labels` rides this call rather than arriving through a setter of its own, and that is a deliberate
    ///      operational choice, not an API-shape preference.** `08_DeployAssetKindRegistry` already broadcasts THREE
    ///      sequential transactions — `new AssetKindRegistry`, `grantRole(MANAGER, registry)`, `setAssetKinds` — any of
    ///      which can land while the others do not, and the silent divergence between them is the single
    ///      most-documented hazard in that script (`grantRole` failing while the classification succeeds leaves a
    ///      fully classified registry with a DEAD facade, script exiting 0, nothing detecting it). A separate
    ///      `setAssetLabels` would make it FOUR transactions and add a fresh "labels never landed" partial state to
    ///      exactly the script whose docstring is mostly about that failure mode. Carrying labels on the classify call
    ///      keeps them atomic with the classification and adds no new partial-failure state. **Do not "tidy" this into
    ///      a separate setter without re-reading that argument.**
    function registerAsset(
        address asset,
        address priceFeed,
        IPrices.PriceType priceType,
        uint256 chainlinkHeartbeat,
        AccrualKind accrualKind,
        string[] calldata labels
    ) external;

    /// @notice Unregisters an asset from the NAV **and** clears its classification, atomically. The mirror of
    ///         {registerAsset}. Gated on the NAV's `MANAGER`.
    /// @dev Idempotent on the kind: an asset registered directly on the NAV has no classification, and this must still
    ///      unregister it, so a missing kind is skipped rather than reverting. Contrast {clearAssetKind}, which DOES
    ///      revert on an unclassified asset because there the clear is the caller's whole intent.
    function unregisterAsset(address asset) external;

    /// @notice Classifies one asset, optionally writing its labels. MANAGER-gated. Re-classification is allowed and
    ///         emits again.
    /// @dev Reverts `InvalidArguments()` if `asset` is `address(0)` — this repo's USD-quote sentinel, never a
    ///      registered asset. That error is not declared in this interface; see the contract-level note.
    ///
    ///      **An EMPTY `labels` means "leave the labels alone", not "clear them".** That is what lets re-classification
    ///      work: an operator correcting an `AccrualKind` passes `new string[](0)` and the asset keeps the labels it
    ///      already had. It is also why a bare-registered asset can be labelled later — see {getAssetLabels}.
    function setAssetKind(address asset, AccrualKind accrualKind, string[] calldata labels) external;

    /// @notice Classifies many assets in one call, optionally writing their labels. MANAGER-gated. All three arrays
    ///         must be the same length.
    /// @dev Reverts {KindArrayLengthMismatch} or {LabelArrayLengthMismatch} if the lengths differ, and
    ///      `InvalidArguments()` on the first `address(0)` entry. An empty batch is a no-op, not an error. Any inner
    ///      `labels[i]` may be empty, which leaves that asset's labels untouched.
    function setAssetKinds(address[] calldata assets, AccrualKind[] calldata accrualKinds, string[][] calldata labels)
        external;

    /// @notice Removes an asset's classification, so subsequent reads fail closed again. MANAGER-gated.
    /// @dev Reverts {AssetNotClassified} if the asset had no classification to remove.
    ///
    ///      **Labels SURVIVE this call, and that is what makes write-once actually hold.** If clearing dropped them,
    ///      `clearAssetKind` followed by `setAssetKind` would be an edit path, and "labels cannot be changed" would be
    ///      true only of the shortest route. Labels outlive the classification for the life of the registry.
    function clearAssetKind(address asset) external;

    /// @notice One asset's classification. Reverts {AssetNotClassified} if it has none.
    function getAssetKind(address asset) external view returns (PegKind pegKind, AccrualKind accrualKind);

    /// @notice One asset's display labels, in significant order. Never reverts — an unlabelled or unclassified asset
    ///         returns an empty array.
    /// @dev **Order is meaningful and the list is not a set.** Index 0 is the protocol or issuer; later indices narrow
    ///      to the product or kind — `["Aave v3", "Savings"]`, `["Lido", "LST"]`. This mirrors the house rule stated in
    ///      `ProtocolNames.sol`: `protocolName()` names the PROTOCOL, never the product, and what distinguishes the
    ///      product is `positionLabels()`. The content is FREE TEXT; nothing on-chain parses it.
    ///
    ///      **An empty result is a legitimate answer, not an error.** `positionLabels()` already returns empty arrays
    ///      legitimately, so this has precedent — an asset with no labels is unlabelled, not misconfigured, and this
    ///      getter deliberately does not revert the way {getAssetKind} does. That is the one place the two axes differ:
    ///      there is no defensible default classification, but "no labels" IS the honest answer.
    ///
    ///      **Write-once, stated precisely, because the imprecise version is false.** Labels can be ADDED to an asset
    ///      that has none; they can never be CHANGED once set. *You can fill a blank, never change a value.* So this is
    ///      not "immutable" — a bare-registered asset can be labelled afterwards without a re-registration, which is
    ///      the property that stops a missing label from costing an asset its pricing config. What is immutable is a
    ///      label that already exists.
    ///
    ///      **Repairing a wrong label therefore means replacing the registry**, not editing it: deploy a new
    ///      `AssetKindRegistry`, re-classify into it, and point the NAV at it with one MANAGER-gated
    ///      `setAssetKindRegistry` call. That path was costed against the alternatives and chosen — a NAV-side label
    ///      store would make a typo fix a `unregisterAsset`/`registerAsset` round trip, i.e. taking a live asset out of
    ///      the NAV and putting its price feeds back, to repair a string. Nothing here touches the NAV's implementation
    ///      or its asset registry.
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
