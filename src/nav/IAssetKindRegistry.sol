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
///      ONE (the accrual axis), and call this address instead.
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

    /// @notice The asset has no classification.
    /// @dev Thrown on the READ path ({getAssetKind}, {getAssetKinds}) so reads fail closed rather than defaulting, AND
    ///      on the WRITE path by {clearAssetKind} when the asset was never classified. Both, deliberately — clearing
    ///      something that is not there is a config mistake worth surfacing, not a no-op.
    error AssetNotClassified(address asset);

    /// @notice A batch setter was given arrays of differing lengths.
    error KindArrayLengthMismatch(uint256 assets, uint256 accrualKinds);

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
    function registerAsset(
        address asset,
        address priceFeed,
        IPrices.PriceType priceType,
        uint256 chainlinkHeartbeat,
        AccrualKind accrualKind
    ) external;

    /// @notice Unregisters an asset from the NAV **and** clears its classification, atomically. The mirror of
    ///         {registerAsset}. Gated on the NAV's `MANAGER`.
    /// @dev Idempotent on the kind: an asset registered directly on the NAV has no classification, and this must still
    ///      unregister it, so a missing kind is skipped rather than reverting. Contrast {clearAssetKind}, which DOES
    ///      revert on an unclassified asset because there the clear is the caller's whole intent.
    function unregisterAsset(address asset) external;

    /// @notice Classifies one asset. MANAGER-gated. Re-classification is allowed and emits again.
    /// @dev Reverts `InvalidArguments()` if `asset` is `address(0)` — this repo's USD-quote sentinel, never a
    ///      registered asset. That error is not declared in this interface; see the contract-level note.
    function setAssetKind(address asset, AccrualKind accrualKind) external;

    /// @notice Classifies many assets in one call. MANAGER-gated. Both arrays must be the same length.
    /// @dev Reverts {KindArrayLengthMismatch} if the lengths differ, and `InvalidArguments()` on the first
    ///      `address(0)` entry. An empty batch is a no-op, not an error.
    function setAssetKinds(address[] calldata assets, AccrualKind[] calldata accrualKinds) external;

    /// @notice Removes an asset's classification, so subsequent reads fail closed again. MANAGER-gated.
    /// @dev Reverts {AssetNotClassified} if the asset had no classification to remove.
    function clearAssetKind(address asset) external;

    /// @notice One asset's classification. Reverts {AssetNotClassified} if it has none.
    function getAssetKind(address asset) external view returns (PegKind pegKind, AccrualKind accrualKind);

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
