// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";

/// @title IAssetKindRegistry
/// @author KPK
/// @notice The two-axis kind classification for assets: what the price tracks ({PegKind}) and how value accrues
///         ({AccrualKind}). A standalone, MANAGER-governed lookup, deliberately NOT part of `NAVCalculator`.
/// @dev **Fail-closed by design.** There is no default classification. Reading an asset that has not been classified
///      REVERTS {AssetNotClassified} rather than returning the zero value, because `PegKind.Pegged` +
///      `AccrualKind.None` is a plausible-looking answer that is wrong for most assets — a silent default here would
///      be indistinguishable from real data, which is the failure mode the repo's fail-closed guards exist to avoid.
///      Callers that need to probe without reverting use {isClassified}.
interface IAssetKindRegistry {
    /// @notice Emitted when an asset's classification is set or changed.
    event AssetKindSet(address indexed asset, PegKind pegKind, AccrualKind accrualKind);

    /// @notice Emitted when an asset's classification is removed (e.g. the asset was unregistered upstream).
    event AssetKindCleared(address indexed asset);

    /// @notice The asset has no classification. Reads fail closed rather than defaulting — see the contract note.
    error AssetNotClassified(address asset);

    /// @notice A batch setter was given arrays of differing lengths.
    error KindArrayLengthMismatch(uint256 assets, uint256 pegKinds, uint256 accrualKinds);

    /// @notice Classifies one asset. MANAGER-gated. Re-classification is allowed and emits again.
    function setAssetKind(address asset, PegKind pegKind, AccrualKind accrualKind) external;

    /// @notice Classifies many assets in one call. MANAGER-gated. All three arrays must be the same length.
    function setAssetKinds(address[] calldata assets, PegKind[] calldata pegKinds, AccrualKind[] calldata accrualKinds)
        external;

    /// @notice Removes an asset's classification, so subsequent reads fail closed again. MANAGER-gated.
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
