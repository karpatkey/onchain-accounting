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
///      **There is now exactly ONE on-chain consumer, and this note is the revisit it asked for.** It previously read
///      "nothing on-chain reads this registry", with the standing instruction that the first consumer to appear should
///      be recorded here. That consumer is {PriceFeedLib.toVerbose}, which reads the two ADAPTER-override getters —
///      {getAdapterProtocolName} and {getAdapterLabelCategory} — once per distinct adapter on the verbose read path.
///      Note what did NOT change: the CLASSIFICATION half (the kinds and the per-asset labels) still has no on-chain
///      reader, and its value remains the atomic register+classify invariant on the write path, not the read. An
///      earlier version justified the contract with "a consumer makes two calls and caches the kinds indefinitely";
///      that was never the point and is still not.
///
///      The override half is deliberately the LESS privileged half. Be precise about why, because an earlier revision
///      of this paragraph overstated it as "never calls back into the NAV": it DOES call the NAV, twice — the
///      `onlyNavManager` gate reads `hasRole`, and the setters read `isAdapterRegistered`. Both are `view`. What it
///      never does is invoke a STATE-CHANGING NAV function, which is the property that matters: {registerAsset}
///      forwards to `NAVCalculator.registerAsset` and therefore needs this contract to hold `MANAGER` on the NAV,
///      whereas the overrides need no grant of any kind. Adapters keep zero governance surface of their own; nothing
///      here is added to them, and no deployed adapter is touched or redeployed by this feature.
///
///      **Why it is its own contract and not part of the NAV. Not preference — measured, twice, for two different
///      questions.** `NAVCalculator` sits at **24,074 of 24,576 bytes: 502 bytes** of EIP-170 headroom (measured on
///      this tree, not inherited). ⚠️ This line read "24,508 / 68 bytes" and was already stale before the labels work
///      touched it — the `_toVerbose` extraction into `PriceFeedLib` had since returned ~520 bytes. The measurements
///      BELOW are historical, taken against the 68-byte tree, and are left as they were: they are what the decision
///      was made on, and re-stating them against today's headroom would be inventing numbers nobody measured. Read
///      them as "why this is not in the NAV", not as current margins.
///
///      *Question 1 — could the NAV hold the atomic register+classify facade?* **No, by a wide margin.** The FLOOR for
///      any NAV-side version is **+123 B**: one immutable registry address plus a single external call, with no
///      signature change and no parameters at all. That is already 55 bytes over, before a single kind parameter
///      exists. The real shapes measured **+371 B** (both axes as parameters of `registerAsset`, plus the forward) and
///      **+335 B** (one axis). Dropping an axis saves only 36 bytes, so the cost is the call-plus-immutable structure,
///      not the parameter count. The facade therefore lives HERE and costs `NAVCalculator` **zero** bytes.
///
///      **It DOES move a library pin, and the earlier claim that it moved neither was wrong.** Not through any
///      dependency — nothing here references `PriceFeedLib` — but because adding this contract under `src/` coincided
///      with the `via_ir` whole-program stack margin being reached, which is what prompted the
///      {PriceFeedLib._assignHealthArrays} extraction. (Stated as "forced" in an earlier revision. A cold build with
///      the extraction reverted now compiles, so the causal claim is not currently demonstrable — the pin move below
///      is, and is measured.)
///      That moved `PriceFeedLib` from `0xfc6AE534…` to `0x49C18627665562F4bEbae5208BA6eF7428039614` (it shrank 69
///      bytes, 18,585 -> 18,516). ⚠️ Both of those are HISTORICAL readings, kept because they record why the pin
///      moved — neither is the pinned value. **The regeneration that was owed has now been done:** `PriceFeedLib` is
///      pinned at `0xcD6F52F4b5F2e563993d1966C27E7E322281Bb26`, measured from a cold `forge clean && forge build
///      --force` with every submodule at its recorded revision. `NAVRegistryLib` did NOT move and holds at
///      `0x5f5D054E…` — measured, not assumed. Do not take a pin from this sentence either: `foundry.toml` and
///      {LibraryPins} are the only authorities, and `LibraryPinConsistency.t.sol` is what proves they match the tree.
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

    /// @notice One asset's display labels, in significant order. Free text; nothing on-chain parses it.
    /// @dev Kept in its OWN mapping rather than inside {AssetKinds}, because the two have different lifetimes on
    ///      purpose. Labels are tied to REGISTRATION: written by {registerAsset}, dropped by {unregisterAsset}, and
    ///      left alone by {clearAssetKind}, which ends only the classification while the asset stays registered on the
    ///      NAV. Packing them into the struct would tie them to the classification instead and make
    ///      `delete _kinds[asset]` drop them by accident.
    ///
    ///      There is no separate `labelled` sentinel and none is needed: `length == 0` is exactly "no labels", which is
    ///      a legitimate state rather than an absent one, so an empty list and an unset list are the same thing by
    ///      design and nothing has to tell them apart.
    mapping(address asset => string[] labels) private _labels;

    /// @notice One balance adapter's `protocolName()` override. Empty string means "no override".
    /// @dev Keyed by ADAPTER, never by position. That is the whole reason this table is bounded: `protocolName()` is
    ///      a per-adapter constant in all 13 of its definitions (`MetaBalanceAdapter.protocolName` folds
    ///      `ProtocolNames.forProtocolId(_protocolId())` at compile time and no concrete meta-adapter overrides it),
    ///      so one row per adapter covers every position that adapter can ever emit — ≤45 rows for the whole fleet,
    ///      with nothing to re-write when `addMetaInstances` adds an instance.
    mapping(address adapter => string name) private _adapterProtocolName;

    /// @notice One balance adapter's override for segment 0 of `positionLabels()` — the CATEGORY. Empty means none.
    /// @dev Also per-adapter, and for the same reason: the category is a string literal at every one of the 32 call
    ///      sites that have one (`_labels("Market", leaf)`, `_addressLabels(pid, "Vault", false)`, …), while only the
    ///      leaf varies per position. Kept in its own mapping rather than packed with the name above so each can be
    ///      set and cleared independently — an operator correcting a protocol name usually has no reason to touch the
    ///      category, and one mapping would make clearing either one require rewriting both.
    mapping(address adapter => string category) private _adapterLabelCategory;

    /// @notice Most labels one asset may carry.
    /// @dev Mirrors `NAVCalculator`'s `_MAX_LABEL_ELEMENTS = 8` on the READ side, at half the value because these are
    ///      hand-written config rather than an adapter's reply. The read-side cap exists because an unbounded
    ///      `string[]` return expands quadratically in the reader's frame; an unbounded per-asset list hands a caller
    ///      the same hazard from the other direction, so the bound belongs on the write side too.
    ///
    ///      **Public so tooling can read the real bound instead of duplicating it.** That is the #248 lesson — a rule
    ///      that lives only in the config tooling drifts from the rule the chain enforces, and the chain wins.
    uint256 public constant MAX_ASSET_LABELS = 4;

    /// @notice Longest one label may be, in BYTES (not characters — a multi-byte glyph costs more than one).
    /// @dev One EVM word. Keeps per-label storage a single slot and predictable, and no legitimate display label is
    ///      longer. Public for the same reason as {MAX_ASSET_LABELS}.
    uint256 public constant MAX_ASSET_LABEL_BYTES = 32;

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
        AccrualKind accrualKind,
        string[] calldata labels
    ) external onlyNavManager {
        // Kind and labels first, then the NAV call. Ordering is deliberate: this contract's state is written before the
        // external call, and `NAV.registerAsset` reaches into the asset for `decimals()`/`symbol()`, so a hostile token
        // cannot observe this registry mid-update. Atomicity does not depend on the order — there is no `try`/`catch`
        // anywhere on this path, so if ANY part reverts the whole transaction reverts and none of it takes effect.
        _setAssetKind(asset, accrualKind);
        _setAssetLabels(asset, labels);
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
        // **Labels go with the registration: one lifetime, cleared with it.** This also used to be what made the
        // only available repair work — before {setAssetLabels}, a wrong label was fixed by unregistering and
        // re-registering, and had labels outlived unregistration that repair would have been a silent no-op, since
        // {registerAsset} was then the sole writer. Correcting a label no longer requires unregistering anything.
        //
        // Guarded rather than unconditional so an asset that never had labels does not emit a misleading event.
        // Contrast {clearAssetKind}, which leaves labels ALONE: that ends the classification while the asset stays
        // registered, and label lifetime is registration lifetime, not classification lifetime.
        if (_labels[asset].length != 0) {
            delete _labels[asset];
            emit AssetLabelsCleared(asset);
        }
        NAV.unregisterAsset(asset);
    }

    /// @inheritdoc IAssetKindRegistry
    /// @dev **Both edge cases are rejected explicitly rather than left to fall out of `_setAssetLabels`.**
    ///
    ///      *Unregistered asset* → {AssetNotRegisteredForLabels}. Labels are registration-scoped, and the only thing
    ///      that clears them is {unregisterAsset} — which calls `NAV.unregisterAsset` and therefore REVERTS for an
    ///      asset the NAV does not hold. So labels written to an unregistered asset could never be cleared by any
    ///      path on this contract: they would be permanent orphans. This guard stops the SETTER from creating one.
    ///
    ///      **It does not stop one arising, and this note previously over-claimed that it did.** A MANAGER calling
    ///      `NAVCalculator.unregisterAsset` DIRECTLY — which the design permits on purpose — strands whatever labels
    ///      this contract holds: the facade's {unregisterAsset} then reverts inside `NAV.unregisterAsset`, and a later
    ///      re-registration through the facade with an empty array does not clear them either, because
    ///      `_setAssetLabels` returns early on an empty list. That state is reachable on the pre-setter code too, via
    ///      {registerAsset} alone, so this change neither creates nor widens it.
    ///
    ///      **Be precise about what the setter does and does not remedy — an earlier revision of this note was not.**
    ///      While the asset is OUT of the NAV, {setAssetLabels} reverts {AssetNotRegisteredForLabels}; it is not a
    ///      remedy for the stranded state itself, and `test_RevertIf_setAssetLabels_afterUnregistration` pins that.
    ///      It remedies the SUCCESSOR state: once the asset is re-registered (through the facade, with an empty array
    ///      that leaves the stale labels in place), one call replaces them — which is what previously could not be
    ///      done. `_setAssetLabels`'s own note on the absent write-once guard describes the same path from the other
    ///      side.
    ///
    ///      Two capabilities are genuinely NEW, both benign and both intentional: an asset registered directly on the
    ///      NAV and never classified can now be labelled (and stays clearable, because the facade's
    ///      {unregisterAsset} is idempotent on the kind), and `NATIVE_ADDRESS` — pre-registered by `initialize` and so
    ///      never registerable through {registerAsset} — becomes labellable for the first time.
    ///
    ///      *Empty array* → {EmptyAssetLabelSet}. `_setAssetLabels` treats an empty list as a silent no-op, which is
    ///      right for {registerAsset} (an asset may legitimately have none) and wrong here: a caller asking to clear
    ///      labels would get silence and believe it worked. Clearing is not a repair — it is what {unregisterAsset}
    ///      does as part of ending a registration — so the setter refuses rather than pretending. This check sits in
    ///      the setter, NOT in `_setAssetLabels`, so the registration path keeps its behaviour byte for byte.
    ///
    ///      The three content bounds ({MAX_ASSET_LABELS}, non-empty elements, {MAX_ASSET_LABEL_BYTES}) are inherited
    ///      unchanged from `_setAssetLabels`, so a label set that could not be registered cannot be set either.
    function setAssetLabels(address asset, string[] calldata labels) external onlyNavManager {
        if (!NAV.isAssetRegistered(asset)) revert AssetNotRegisteredForLabels(asset);
        if (labels.length == 0) revert EmptyAssetLabelSet(asset);
        _setAssetLabels(asset, labels);
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
    function setAdapterProtocolName(address adapter, string calldata name) external onlyNavManager {
        _requireRegisteredAdapter(adapter);
        _requireValidOverride(adapter, name);
        _adapterProtocolName[adapter] = name;
        emit AdapterProtocolNameSet(adapter, name);
    }

    /// @inheritdoc IAssetKindRegistry
    function clearAdapterProtocolName(address adapter) external onlyNavManager {
        if (bytes(_adapterProtocolName[adapter]).length == 0) revert AdapterOverrideNotSet(adapter);
        delete _adapterProtocolName[adapter];
        emit AdapterProtocolNameCleared(adapter);
    }

    /// @inheritdoc IAssetKindRegistry
    function setAdapterLabelCategory(address adapter, string calldata category) external onlyNavManager {
        _requireRegisteredAdapter(adapter);
        _requireValidOverride(adapter, category);
        _adapterLabelCategory[adapter] = category;
        emit AdapterLabelCategorySet(adapter, category);
    }

    /// @inheritdoc IAssetKindRegistry
    function clearAdapterLabelCategory(address adapter) external onlyNavManager {
        if (bytes(_adapterLabelCategory[adapter]).length == 0) revert AdapterOverrideNotSet(adapter);
        delete _adapterLabelCategory[adapter];
        emit AdapterLabelCategoryCleared(adapter);
    }

    /// @inheritdoc IAssetKindRegistry
    function getAdapterProtocolName(address adapter) external view returns (string memory) {
        return _adapterProtocolName[adapter];
    }

    /// @inheritdoc IAssetKindRegistry
    function getAdapterLabelCategory(address adapter) external view returns (string memory) {
        return _adapterLabelCategory[adapter];
    }

    /// @dev Setters only — see {IAssetKindRegistry.AdapterNotRegistered} for why the clearers deliberately skip this.
    ///      `isAdapterRegistered` is an O(1) mapping read on the NAV, so this costs one `staticcall` on a MANAGER
    ///      write path and nothing at all on the read path.
    function _requireRegisteredAdapter(address adapter) private view {
        if (!NAV.isAdapterRegistered(adapter)) revert AdapterNotRegistered(adapter);
    }

    /// @dev Both overrides share one validator because they are the same kind of value: a short display string that
    ///      lands in the same breadcrumb, read through the same fixed copy window in {PriceFeedLib}.
    function _requireValidOverride(address adapter, string calldata value) private pure {
        uint256 len = bytes(value).length;
        // `""` is the read path's MISS sentinel, so storing one would read back as absence — see
        // {IAssetKindRegistry.EmptyAdapterOverride}.
        if (len == 0) revert EmptyAdapterOverride(adapter);
        if (len > MAX_ASSET_LABEL_BYTES) revert AdapterOverrideTooLong(adapter, len, MAX_ASSET_LABEL_BYTES);
    }

    /// @inheritdoc IAssetKindRegistry
    function getAssetLabels(address asset) external view returns (string[] memory) {
        return _labels[asset];
    }

    /// @inheritdoc IAssetKindRegistry
    function getAssetInfo(address asset) external view returns (PegKind, AccrualKind, string[] memory) {
        AssetKinds memory kinds = _kinds[asset];
        if (!kinds.classified) revert AssetNotClassified(asset);
        return (_derivePegKind(asset), kinds.accrualKind, _labels[asset]);
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

    /// @dev Writes `asset`'s display labels. Two callers: {registerAsset} and {setAssetLabels}.
    ///
    ///      **Registration is no longer the only chance, and the parity argument that made it so has been retired
    ///      deliberately.** Labels were originally fixed at registration for parity with the balance adapters, whose
    ///      `positionLabels()` are fixed at deploy time and editable by no role. That parity was dropped on the
    ///      grounds that the two are not the same kind of value: an adapter label is a compile-time constant OF THE
    ///      CODE, while an asset label is operator-supplied DATA. Making the latter repairable does not imply making
    ///      the former editable.
    ///
    ///      ⚠️ **The trailing half of that argument — "and adapter labels remain redeploy-to-change" — is no longer
    ///      true, and the distinction above survives only in a narrowed form.** {setAdapterProtocolName} and
    ///      {setAdapterLabelCategory} now make an adapter's two CONSTANT segments correctable without a redeploy.
    ///      What still holds, and is the line that matters, is that only the constants moved: the computed LEAF is
    ///      untouched and still derived live on every read, because 21 of the 33 deployable adapters build it from
    ///      on-chain state and a stored table has no finite key for a computed value. So an adapter label is still
    ///      not operator-supplied data in general — only the part of it that was already a literal is. The repair
    ///      this replaces was
    ///      unregister-then-re-register, which also destroys every price feed, every monitor feed and the whole of
    ///      `_assetPricing` (both tolerances) — up to five transactions on an EOA MANAGER with the asset absent from
    ///      NAV in between.
    ///
    ///      **An empty `labels` writes nothing and is not an error — HERE.** An asset may legitimately have none, and
    ///      `positionLabels()` returns empty arrays legitimately too, so registration accepts one silently.
    ///      {setAssetLabels} rejects it instead, before calling this, because a caller asking a SETTER to clear and
    ///      getting silence is a different and worse thing than a registration with nothing to say. This function's
    ///      behaviour is unchanged.
    ///
    ///      **There is deliberately NO write-once guard here, and adding one would be a defect rather than belt-and-
    ///      braces.** It would be unreachable on the intended path — {unregisterAsset} deletes `_labels`, and
    ///      {registerAsset} can only succeed for an asset the NAV does not already hold, so `_labels[asset]` is empty
    ///      whenever this runs through the facade. But it would be REACHED on a real one: an asset unregistered
    ///      DIRECTLY on the NAV, bypassing this contract, leaves its labels behind here, and a later re-registration
    ///      through the facade would then hit the guard and either revert or keep the stale labels. Overwriting is the
    ///      correct behaviour for that path, because registration is what defines an asset's labels.
    ///
    ///      An earlier revision carried that guard plus an identical-content comparison, both needed only because
    ///      labels could once be supplied by `setAssetKind`/`setAssetKinds`. They no longer can, so both are gone.
    ///
    ///      **All three bounds are enforced HERE, in the setter, not only in preflight.** #248 is the standing
    ///      precedent for what happens when validation lives in config tooling alone: nothing enforced `accrualKind`,
    ///      and the gap was invisible until someone went looking. Tooling that wants the same bounds reads
    ///      {MAX_ASSET_LABELS} and {MAX_ASSET_LABEL_BYTES} off this contract rather than restating them.
    function _setAssetLabels(address asset, string[] calldata labels) private {
        uint256 length = labels.length;
        if (length == 0) return;
        if (length > MAX_ASSET_LABELS) revert TooManyAssetLabels(asset, length, MAX_ASSET_LABELS);

        for (uint256 i; i < length; ++i) {
            uint256 labelBytes = bytes(labels[i]).length;
            // An empty LIST is legitimate; an empty ELEMENT is not. It renders as nothing while still occupying an
            // ordered slot, so it silently shifts the meaning of every label after it — and order is significant here
            // (index 0 is the protocol, later indices narrow to the product).
            if (labelBytes == 0) revert EmptyAssetLabel(asset, i);
            if (labelBytes > MAX_ASSET_LABEL_BYTES) {
                revert AssetLabelTooLong(asset, i, labelBytes, MAX_ASSET_LABEL_BYTES);
            }
        }

        // Validate, then write. The ordering is behaviourally irrelevant against the loop above — every exit from it
        // reverts, and a revert rolls the whole transaction back — so a mutant that hoists this line is EQUIVALENT and
        // the matrix records it as a deliberate survivor. What it buys is not paying for an `SSTORE` that is about to
        // be discarded, plus a body that reads in the order it reasons.
        _labels[asset] = labels;
        emit AssetLabelsSet(asset, labels);
    }
}
