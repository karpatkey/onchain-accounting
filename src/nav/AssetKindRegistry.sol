// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title AssetKindRegistry
/// @author KPK
/// @notice MANAGER-governed registry for the two-axis asset classification — {PegKind} (what the price tracks) and
///         {AccrualKind} (how value accrues) — of which it STORES only the accrual axis and DERIVES the peg axis from
///         the NAV. One instance per chain, deployed standalone.
/// @dev **What this contract is FOR: the atomic invariant, not the read.** Registering an asset and classifying it are
///      ONE operation — {registerAsset} stores the kind and forwards to `NAVCalculator.registerAsset` in the same
///      transaction, and {unregisterAsset} is exactly symmetric. So a registered asset is always classified, by
///      construction rather than by an operator remembering two calls.
///
///      **To be blunt about what it is NOT for: nothing on-chain reads this registry.** There is no on-chain consumer
///      today — every reference outside this file is a deploy script or a test. An earlier version of this docstring
///      justified the contract with "a consumer makes two calls and caches the kinds indefinitely"; that was never the
///      point and is not the point now. The value is the invariant on the write path. If an on-chain consumer ever
///      appears, this note should be the first thing revisited.
///
///      **Why it is its own contract and not part of the NAV. Not preference — measured, twice, for two different
///      questions.** `NAVCalculator` sits at 24,508 of 24,576 bytes: **68 bytes** of EIP-170 headroom (re-measured, not
///      inherited).
///
///      *Question 1 — could the NAV hold the atomic register+classify facade?* **No, by a wide margin.** The FLOOR for
///      any NAV-side version is **+123 B**: one immutable registry address plus a single external call, with no
///      signature change and no parameters at all. That is already 55 bytes over, before a single kind parameter
///      exists. The real shapes measured **+371 B** (both axes as parameters of `registerAsset`, plus the forward) and
///      **+335 B** (one axis). Dropping an axis saves only 36 bytes, so the cost is the call-plus-immutable structure,
///      not the parameter count. The facade therefore lives HERE and costs `NAVCalculator` **zero** bytes.
///
///      **It DOES move a library pin, and the earlier claim that it moved neither was wrong.** Not through any
///      dependency — nothing here references `PriceFeedLib` — but because this contract's mere PRESENCE under `src/`
///      tipped the `via_ir` whole-program stack margin and forced the {PriceFeedLib._assignHealthArrays} extraction.
///      That moved `PriceFeedLib` from `0xfc6AE534…` to `0x49C18627665562F4bEbae5208BA6eF7428039614` (it shrank 69
///      bytes, 18,585 -> 18,516). `NAVRegistryLib` is genuinely unchanged and byte-identical. A pin regeneration IS
///      owed for this feature — do not read "costs NAVCalculator zero bytes" as "costs nothing".
///
///      *Question 2 — could the NAV hold the kinds as READ surface (a field on an existing struct)?* Also no. Measured
///      separately, and recorded so nobody re-attempts it: two fields on the shared `Asset` struct cost **+189 B** (and
///      would have broken the `IBalanceAdapter` return ABI against every already-deployed, immutable adapter); packing
///      the enums into `AssetPricing` plus one MANAGER setter cost **+367 B**; and the irreducible floor — widening
///      `AssetPricing` and its ALREADY-EXISTING getter, with no setter, no new selector and no signature change —
///      still cost **+92 B**, i.e. 24 bytes over, at a shape that is not even a working feature because nothing can
///      set the values.
///
///      Two lessons that generalise, from both measurements: the binding constraint is **external ABI surface**, not
///      struct embedding (the setter alone was 275 B), and **"put the work in the library, its bytes do not count"
///      fails when the cost is surface rather than work** — the read-surface floor grew `PriceFeedLib` by 411 B while
///      still overflowing `NAVCalculator`. If kinds are ever wanted inside the NAV, the documented price is moving the
///      verbose label block out to a lens contract first.
///
///      **⚠️ "No roles of its own" is NOT "unprivileged". Read both halves.** This contract holds no `AccessControl`,
///      no admin, no manager and no owner — but it DOES hold `MANAGER` **on the NAV**, granted by
///      `08_DeployAssetKindRegistry`, because {registerAsset} forwards to `NAVCalculator.registerAsset` and the NAV
///      gates on the registry as `msg.sender`. So a bug in this contract can register or unregister assets.
///
///      That is the price of the atomic one-call flow, accepted deliberately rather than discovered: it is a smaller
///      surface than a second `AccessControl` with its own admin to keep in sync, but it is not zero, and nothing here
///      should be read as claiming the system gained a privilege-free component. The ownerless design removed this
///      contract's own role surface; it did not remove privilege from the system. Every mutator gates on `NAV.hasRole(MANAGER, msg.sender)`, so authority is exactly the NAV's
///      MANAGER set — ONE set of humans for the whole system, rather than a second contract with its own governance to
///      keep in sync. That also means there is nothing here to escalate, hand over, or renounce: no admin can grant
///      itself write access, no Safe handover is owed for this contract, and no sequence of renouncements can freeze
///      the classification map.
///
///      **Immutable except the classification map.** No upgrade path, no proxy. The NAV address is set once in the
///      constructor and cannot change.
contract AssetKindRegistry is IAssetKindRegistry {
    /// @notice One asset's STORED classification — the accrual axis only.
    /// @dev **`PegKind` is deliberately NOT stored.** It is derived on read from the NAV's `pegToleranceBps`, so there
    ///      is exactly one authority on whether an asset is worth $1 and nothing to keep in sync. `PegKind` survives as
    ///      a return type, never as state.
    ///
    ///      `classified` remains the presence sentinel and is still load-bearing: `AccrualKind.None` is a REAL
    ///      classification (USDC, WETH) and is also the zero value, so without the sentinel an unclassified asset would
    ///      be indistinguishable from a correctly-classified non-accruing one. Both members pack into one slot.
    struct AssetKinds {
        AccrualKind accrualKind;
        bool classified;
    }

    mapping(address asset => AssetKinds kinds) private _kinds;

    /// @notice The `NAVCalculator` this registry fronts. Source of truth for BOTH the asset registry and authority.
    INAVCalculator public immutable NAV;

    /// @param nav The `NAVCalculator` proxy. Held immutable and used for two things: the target of the forwarded
    ///            register/unregister calls, and the authority oracle — `NAV.hasRole(MANAGER, msg.sender)` is the only
    ///            gate on this contract, so it has no roles of its own to administer.
    constructor(address nav) {
        if (nav == address(0)) revert InvalidArguments();
        NAV = INAVCalculator(nav);
    }

    /// @notice Derives the peg axis from the NAV's per-asset `pegToleranceBps`, the switch that enables
    ///         {PriceFeedLib}'s absolute-$1 guard.
    /// @dev **This is why there is only one authority on peggedness.** A stored `PegKind` would be a second copy of a
    ///      fact the NAV already holds, and two copies of one fact diverge — that is not hypothetical, it already
    ///      happened once in this feature's own documentation. Deriving does not make the divergence easier to catch; it
    ///      makes the contradictory CLAIM unwriteable — there is no stored peg with which to assert one. It does NOT
    ///      make every odd pair unreachable: a peg tolerance on an appreciating asset still reads back
    ///      `Pegged + Appreciating`, but that is a true report of the NAV's configuration rather than a second opinion
    ///      contradicting it.
    ///
    ///      Reads through `IPrices`, not `INAVCalculator`: `INAVCalculator is IBalances` and does NOT inherit `IPrices`,
    ///      so the pricing getter is only reachable via that interface. It is an already-existing external selector, so
    ///      the derivation costs `NAVCalculator` zero bytes.
    function _derivePegKind(address asset) private view returns (PegKind) {
        return IPrices(address(NAV)).getAssetPricing(asset).pegToleranceBps > 0 ? PegKind.Pegged : PegKind.Floating;
    }

    /// @dev The single authority check. Deliberately delegates to the NAV rather than keeping a local role: one set of
    ///      humans governs the whole system, and this contract cannot drift out of sync with it.
    modifier onlyNavManager() {
        if (!IAccessControl(address(NAV)).hasRole(MANAGER, msg.sender)) revert NotAuthorized();
        _;
    }

    /// @inheritdoc IAssetKindRegistry
    function registerAsset(
        address asset,
        address priceFeed,
        IPrices.PriceType priceType,
        uint256 chainlinkHeartbeat,
        AccrualKind accrualKind
    ) external onlyNavManager {
        // Kind first, then the NAV call. Ordering is deliberate: this contract's state is written before the external
        // call, and `NAV.registerAsset` reaches into the asset for `decimals()`/`symbol()`, so a hostile token cannot
        // observe this registry mid-update. Atomicity does not depend on the order — there is no `try`/`catch`
        // anywhere on this path, so if EITHER half reverts the whole transaction reverts and neither takes effect.
        _setAssetKind(asset, accrualKind);
        NAV.registerAsset(asset, priceFeed, priceType, chainlinkHeartbeat);
    }

    /// @inheritdoc IAssetKindRegistry
    function unregisterAsset(address asset) external onlyNavManager {
        // Symmetric with {registerAsset}, and idempotent on the kind ON PURPOSE. An asset registered directly on the
        // NAV — which remains possible for any MANAGER, by design — has no kind, and this function must still be able
        // to unregister it. Using the reverting {clearAssetKind} here would make the facade unusable for exactly those
        // assets, so the clear is skipped when there is nothing to clear rather than treated as an error.
        if (_kinds[asset].classified) {
            delete _kinds[asset];
            emit AssetKindCleared(asset);
        }
        NAV.unregisterAsset(asset);
    }

    /// @inheritdoc IAssetKindRegistry
    function setAssetKind(address asset, AccrualKind accrualKind) external onlyNavManager {
        _setAssetKind(asset, accrualKind);
    }

    /// @inheritdoc IAssetKindRegistry
    function setAssetKinds(address[] calldata assets, AccrualKind[] calldata accrualKinds) external onlyNavManager {
        uint256 length = assets.length;
        if (length != accrualKinds.length) {
            revert KindArrayLengthMismatch(length, accrualKinds.length);
        }
        for (uint256 i; i < length; ++i) {
            _setAssetKind(assets[i], accrualKinds[i]);
        }
    }

    /// @inheritdoc IAssetKindRegistry
    function clearAssetKind(address asset) external onlyNavManager {
        if (!_kinds[asset].classified) revert AssetNotClassified(asset);
        delete _kinds[asset];
        emit AssetKindCleared(asset);
    }

    /// @inheritdoc IAssetKindRegistry
    function getAssetKind(address asset) external view returns (PegKind, AccrualKind) {
        AssetKinds memory kinds = _kinds[asset];
        if (!kinds.classified) revert AssetNotClassified(asset);
        return (_derivePegKind(asset), kinds.accrualKind);
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
            pegKinds[i] = _derivePegKind(assets[i]);
            accrualKinds[i] = kinds.accrualKind;
        }
    }

    /// @inheritdoc IAssetKindRegistry
    function isClassified(address asset) external view returns (bool) {
        return _kinds[asset].classified;
    }

    /// @dev `address(0)` is rejected: it is this repo's USD-quote sentinel, never a registered asset (native ETH is
    ///      `NATIVE_ADDRESS`), so accepting it would only ever record a classification nothing can read back.
    function _setAssetKind(address asset, AccrualKind accrualKind) private {
        if (asset == address(0)) revert InvalidArguments();
        _kinds[asset] = AssetKinds({accrualKind: accrualKind, classified: true});
        // The event carries ONLY the stored axis, deliberately. Emitting the derived `PegKind` too would write a
        // snapshot of a value that can legitimately change afterwards (an operator retuning `pegToleranceBps`), so
        // indexers replaying the log would hold a peg that the chain no longer agrees with — a fresh divergence of
        // exactly the kind deriving was chosen to eliminate. Consumers read the peg; they do not replay it.
        emit AssetKindSet(asset, accrualKind);
    }
}
