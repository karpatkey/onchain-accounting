// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title AssetKindRegistry
/// @author KPK
/// @notice MANAGER-governed lookup for the two-axis asset classification — {PegKind} (what the price tracks) and
///         {AccrualKind} (how value accrues). One instance per chain, deployed standalone.
/// @dev **Why this is its own contract and not a field on the NAV.** The classification is STATIC METADATA: it does
///      not change block to block, it does not participate in valuation, and nothing on the NAV read path consumes
///      it. Neither of the two properties that would justify carrying a value inside the NAV read — atomicity with
///      the price, or derivation from live state — applies. A consumer makes two calls and caches the kinds
///      indefinitely. So this contract costs `NAVCalculator` zero bytes, breaks no adapter ABI, and moves neither
///      library pin.
///
///      **It also would not have fit, which is worth recording so nobody re-attempts it.** `NAVCalculator` had 68
///      bytes of EIP-170 headroom when this was designed. Three surfaces were measured on clean builds: two fields on
///      the shared `Asset` struct cost **+189 B** (and would have broken the `IBalanceAdapter` return ABI against
///      every already-deployed, immutable adapter); packing the enums into the existing `AssetPricing` struct plus one
///      MANAGER setter cost **+367 B**; and the irreducible floor — widening `AssetPricing` and its ALREADY-EXISTING
///      getter, with no setter, no new selector and no signature change — still cost **+92 B**, i.e. 24 bytes over,
///      at a shape that is not even a working feature because nothing can set the values. The binding constraint is
///      any new external function (the setter alone was 275 B), NOT struct embedding; and "put the work in the
///      library, its bytes do not count" fails here because the cost is external ABI surface rather than work — the
///      floor variant grew `PriceFeedLib` by 411 B while still overflowing `NAVCalculator`. If kinds are ever wanted
///      inside the NAV, the documented price is moving the verbose label block out to a lens contract first.
///
///      **Immutable except the classification map.** No upgrade path, no proxy. Roles are set once in the
///      constructor: `DEFAULT_ADMIN_ROLE` for role administration, `MANAGER` for classification writes.
contract AssetKindRegistry is AccessControl, IAssetKindRegistry {
    /// @notice One asset's classification.
    /// @dev `classified` is the presence sentinel and is load-bearing: without it, an unclassified asset is
    ///      indistinguishable from `Pegged` + `None`, since both are the zero value. All three members pack into a
    ///      single storage slot, so a read is one SLOAD.
    struct AssetKinds {
        PegKind pegKind;
        AccrualKind accrualKind;
        bool classified;
    }

    mapping(address asset => AssetKinds kinds) private _kinds;

    /// @param admin   Receives `DEFAULT_ADMIN_ROLE` (role administration only — cannot classify).
    /// @param manager Receives `MANAGER` (classification writes).
    constructor(address admin, address manager) {
        if (admin == address(0) || manager == address(0)) revert InvalidArguments();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER, manager);
    }

    /// @inheritdoc IAssetKindRegistry
    function setAssetKind(address asset, PegKind pegKind, AccrualKind accrualKind) external onlyRole(MANAGER) {
        _setAssetKind(asset, pegKind, accrualKind);
    }

    /// @inheritdoc IAssetKindRegistry
    function setAssetKinds(address[] calldata assets, PegKind[] calldata pegKinds, AccrualKind[] calldata accrualKinds)
        external
        onlyRole(MANAGER)
    {
        uint256 length = assets.length;
        if (length != pegKinds.length || length != accrualKinds.length) {
            revert KindArrayLengthMismatch(length, pegKinds.length, accrualKinds.length);
        }
        for (uint256 i; i < length; ++i) {
            _setAssetKind(assets[i], pegKinds[i], accrualKinds[i]);
        }
    }

    /// @inheritdoc IAssetKindRegistry
    function clearAssetKind(address asset) external onlyRole(MANAGER) {
        if (!_kinds[asset].classified) revert AssetNotClassified(asset);
        delete _kinds[asset];
        emit AssetKindCleared(asset);
    }

    /// @inheritdoc IAssetKindRegistry
    function getAssetKind(address asset) external view returns (PegKind, AccrualKind) {
        AssetKinds memory kinds = _kinds[asset];
        if (!kinds.classified) revert AssetNotClassified(asset);
        return (kinds.pegKind, kinds.accrualKind);
    }

    /// @inheritdoc IAssetKindRegistry
    function getAssetKinds(address[] calldata assets)
        external
        view
        returns (PegKind[] memory pegKinds, AccrualKind[] memory accrualKinds)
    {
        uint256 length = assets.length;
        pegKinds = new PegKind[](length);
        accrualKinds = new AccrualKind[](length);
        for (uint256 i; i < length; ++i) {
            AssetKinds memory kinds = _kinds[assets[i]];
            // Fail closed on the FIRST gap rather than zero-filling it — see {IAssetKindRegistry}.
            if (!kinds.classified) revert AssetNotClassified(assets[i]);
            pegKinds[i] = kinds.pegKind;
            accrualKinds[i] = kinds.accrualKind;
        }
    }

    /// @inheritdoc IAssetKindRegistry
    function isClassified(address asset) external view returns (bool) {
        return _kinds[asset].classified;
    }

    /// @dev `address(0)` is rejected: it is this repo's USD-quote sentinel, never a registered asset (native ETH is
    ///      `NATIVE_ADDRESS`), so accepting it would only ever record a classification nothing can read back.
    function _setAssetKind(address asset, PegKind pegKind, AccrualKind accrualKind) private {
        if (asset == address(0)) revert InvalidArguments();
        _kinds[asset] = AssetKinds({pegKind: pegKind, accrualKind: accrualKind, classified: true});
        emit AssetKindSet(asset, pegKind, accrualKind);
    }
}
