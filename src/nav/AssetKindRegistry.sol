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
///      **There are now TWO on-chain consumers, and this note is the revisit it asked for.** It previously read
///      "nothing on-chain reads this registry", with the standing instruction that the first consumer to appear should
///      be recorded here. Those consumers are {PriceFeedLib.toVerbose} (the ACCOUNT read path, once per distinct
///      adapter) and `PriceFeedLib.adapterDisplayInfo` (the CONFIGURATION read path behind
///      `NAVCalculator.getAdapterDisplayInfo`, once per listed adapter). Both read the same two ADAPTER-override
///      getters — {getAdapterProtocolName} and {getAdapterLabels} — through ONE shared precedence helper each, and
///      both overlay the label array through one shared `_applyLabelOverride`, so the two display surfaces cannot
///      disagree **about a segment they both emit**. A third consumer, if one is ever added, must use those helpers
///      too.
///
///      ⚠️ **That guarantee is about CONTENT, not about SHAPE, and an earlier revision of this sentence stated it
///      without the qualifier.** The two surfaces deliberately differ on emptiness: the ACCOUNT path leaves an empty
///      reply empty, while the CONFIGURATION path grows it to the override's leading non-empty prefix.
///
///      The divergence needs an adapter whose reply is EMPTY (every meta-adapter, which answers `positionLabels("")`
///      with `[]`) and an override with a NON-EMPTY leading segment. Measured: `["Cat", ""]` on such an adapter
///      yields `["Cat"]` on the configuration surface and `[]` on the account path. Against an adapter that DOES
///      reply, the two agree exactly. (An earlier revision illustrated this with `["", "X"]`, which demonstrates no
///      divergence at all: the leading `""` stops the prefix scan, so an empty-replying adapter yields nothing on
///      EITHER surface, and a replying adapter gets `X` at index 1 on BOTH. An example added to walk back an
///      over-broad claim, that showed the opposite of the claim it was correcting.) Both behaviours are intended —
///      see `PriceFeedLib._overridePrefix`.
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
///      questions.** `NAVCalculator` runs against the EIP-170 limit; **{NAVCalculator}'s own header is the single
///      authority for the current margin and this line no longer restates it** — it carried "24,508 / 68 bytes",
///      which was already stale when written, and a second stale copy is worse than none. The measurements
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
///      moved — neither is the pinned value. **The regeneration that was owed has been done, and redone three times
///      since** as `toVerbose`, then `adapterDisplayInfo`, then the meta-adapter category fix each changed
///      `PriceFeedLib`'s bytecode. ⚠️ **This sentence deliberately no longer names the current address.** It named
///      one, and that literal went stale the very next time the pin was regenerated — a docstring asserting an
///      address that is not the deployed one. The failure was a doc that duplicates an authority instead of pointing
///      at it, so: **`foundry.toml` and {LibraryPins} are the only authorities, and `LibraryPinConsistency.t.sol`
///      proves they match the tree.** Every regeneration is measured from two INDEPENDENT cold
///      `forge clean && forge build` runs that must agree before the value is written. `NAVRegistryLib` has not
///      moved through any of it and holds at
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
    ///      so one row per adapter covers every position that adapter can ever emit — at most one row per DEPLOYED
    ///      adapter. **Two different figures, and an earlier revision used them interchangeably: 34 deployable
    ///      CONTRACTS in the tree, and 46 enabled DEPLOYMENTS across the 6 chains that configure any adapter.** Both
    ///      moved by one when the Cap split replaced one contract, and one chain-1 deployment, with two.
    ///
    ///      ⚠️ Neither figure is the row bound, and an earlier revision quoted 46 as if it were. The 46 counts only
    ///      adapters enabled in `nav-config`; `ERC20Default` is registered by `initialize()` on every chain and
    ///      appears in no nav-config file, yet it is an overridable adapter like any other and can hold a row. It is
    ///      present in all 24 deployment records. So the bound is 46 + one per chain — the exact number is not worth
    ///      pinning in a comment that has already gone stale twice; treat it as "one row per registered adapter per
    ///      chain, and ERC20Default counts",
    ///      with nothing to re-write when `addMetaInstances` adds an instance.
    mapping(address adapter => string name) private _adapterProtocolName;

    /// @notice One balance adapter's per-SEGMENT override of its `positionLabels()` reply, index-aligned with that
    ///         reply. `""` at an index means "leave that segment alone"; an EMPTY ARRAY means "no override at all".
    /// @dev Also per-adapter, and for the same reason as the name above: after the combined `CapBalanceAdapter` was
    ///      split into {CapStablecoinBalanceAdapter} / {CapSavingsBalanceAdapter}, **every literal label segment in
    ///      `src/balances/` is a compile-time constant of its adapter and the same for every position that adapter can
    ///      emit** — so one row per adapter covers them all, and nothing has to be re-written when `addMetaInstances`
    ///      adds an instance. The segments that still vary per position are the COMPUTED ones, and `""` is how an
    ///      operator declines to touch those. `src/balances/BALANCE_ADAPTERS.md` §6.2 carries the per-adapter,
    ///      per-segment sweep that says which index is which.
    ///
    ///      **This REPLACED a scalar `_adapterLabelCategory` that could only rewrite index 0, and the scalar was
    ///      removed rather than kept alongside.** `setAdapterLabels(a, ["X"])` is byte-for-byte the old
    ///      `setAdapterLabelCategory(a, "X")` on both display surfaces, so the scalar was a strict special case, not a
    ///      complement. Keeping both would have meant two stores writing one display value with no principled
    ///      precedence between them — and two mechanisms that must agree about one display value is precisely the
    ///      failure this feature has already hit twice (the `protocolName` phantom-sibling split, and the empty-reply
    ///      divergence that left the two surfaces disagreeing for 21 of the 34 adapters). Migration cost was zero:
    ///      `AssetKindRegistry` appears in no `script/config/deployments/*.json`, so no chain has ever had one and
    ///      `setAdapterLabelCategory` was never callable in production.
    ///
    ///      Kept in its own mapping rather than packed with the name above so each can be set and cleared
    ///      independently — an operator correcting a protocol name usually has no reason to touch the breadcrumb, and
    ///      one mapping would make clearing either one require rewriting both.
    mapping(address adapter => string[] labels) private _adapterLabels;

    /// @notice Most labels one asset may carry.
    /// @dev Mirrors `NAVCalculator`'s `_MAX_LABEL_ELEMENTS = 8` on the READ side, at half the value because these are
    ///      hand-written config rather than an adapter's reply. The read-side cap exists because an unbounded
    ///      `string[]` return expands quadratically in the reader's frame; an unbounded per-asset list hands a caller
    ///      the same hazard from the other direction, so the bound belongs on the write side too.
    ///
    ///      **Public so tooling can read the real bound instead of duplicating it.** That is the #248 lesson — a rule
    ///      that lives only in the config tooling drifts from the rule the chain enforces, and the chain wins.
    uint256 public constant MAX_ASSET_LABELS = 4;

    /// @notice Most SEGMENTS one adapter's label override may carry.
    /// @dev **Deliberately 8, not {MAX_ASSET_LABELS}' 4, and the difference is not an inconsistency.** An asset's
    ///      labels are standalone hand-written content, so a tight bound costs nothing. This array is INDEX-ALIGNED
    ///      with an adapter's `positionLabels()` reply and must be able to address every segment the NAV will accept:
    ///      `NAVCalculator`'s `_MAX_LABEL_ELEMENTS = 8` is exactly that ceiling, so a lower bound here would leave the
    ///      deepest addressable segments permanently uncorrectable.
    ///
    ///      It cannot be used to LENGTHEN a reply ON THE ACCOUNT PATH. `PriceFeedLib` overlays only
    ///      `i < min(reply.length, override.length)`, so a segment past the adapter's own reply is inert there — the
    ///      longest reply anywhere in `src/balances/` today is 3 (`ConvexCurveLPStakingMetaBalanceAdapter`). This bound
    ///      therefore protects the operator's own gas and this contract's storage, not the read path's element cap.
    ///
    ///      ⚠️ **"Inert" is true of the ACCOUNT path only, and an earlier revision said "on both display surfaces".**
    ///      `PriceFeedLib.adapterDisplayInfo` grows an EMPTY reply to the override's leading non-empty prefix, so on
    ///      the configuration surface segments past the (zero-length) reply are emitted, not inert — that is how a
    ///      meta-adapter gets a breadcrumb on a configuration page at all. Segments beyond the prefix, and segments
    ///      past a NON-empty reply, are inert on both.
    uint256 public constant MAX_ADAPTER_LABEL_SEGMENTS = 8;

    /// @notice Longest one label may be, in BYTES (not characters — a multi-byte glyph costs more than one).
    /// @dev One EVM word. Keeps per-label storage a single slot and predictable, and no legitimate display label is
    ///      longer. Shared by the asset labels and the per-adapter label override, which land in the same breadcrumb
    ///      and are read through the same fixed copy window in {PriceFeedLib}. Public for the same reason as
    ///      {MAX_ASSET_LABELS}.
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
    /// @dev The three checks below are the array analogue of {_requireValidOverride}, which cannot be reused per
    ///      element: it rejects `""`, and `""` is this setter's SKIP sentinel rather than an error.
    function setAdapterLabels(address adapter, string[] calldata labels) external onlyNavManager {
        _requireRegisteredAdapter(adapter);
        uint256 length = labels.length;
        if (length > MAX_ADAPTER_LABEL_SEGMENTS) {
            revert TooManyAdapterLabels(adapter, length, MAX_ADAPTER_LABEL_SEGMENTS);
        }
        bool anySet;
        for (uint256 i; i < length; ++i) {
            uint256 labelBytes = bytes(labels[i]).length;
            if (labelBytes > MAX_ASSET_LABEL_BYTES) {
                revert AdapterLabelTooLong(adapter, i, labelBytes, MAX_ASSET_LABEL_BYTES);
            }
            if (labelBytes != 0) anySet = true;
        }
        // An array whose every element is `""` overrides NOTHING, so it would read back as absence — the same
        // write-that-reads-as-a-miss the scalar setters reject `""` for, and the reason a caller trying to CLEAR must
        // use {clearAdapterLabels} instead of being told "done" by silence. The empty array falls out of the same
        // check (`anySet` is false), so both no-op shapes take one exit.
        if (!anySet) revert EmptyAdapterOverride(adapter);
        // Validate, then write — same ordering rationale as {_setAssetLabels}: every exit above reverts, so hoisting
        // the write would be behaviourally equivalent, but it would pay for `SSTORE`s that are about to be discarded.
        _adapterLabels[adapter] = labels;
        emit AdapterLabelsSet(adapter, labels);
    }

    /// @inheritdoc IAssetKindRegistry
    function clearAdapterLabels(address adapter) external onlyNavManager {
        if (_adapterLabels[adapter].length == 0) revert AdapterOverrideNotSet(adapter);
        delete _adapterLabels[adapter];
        emit AdapterLabelsCleared(adapter);
    }

    /// @inheritdoc IAssetKindRegistry
    function getAdapterProtocolName(address adapter) external view returns (string memory) {
        return _adapterProtocolName[adapter];
    }

    /// @inheritdoc IAssetKindRegistry
    function getAdapterLabels(address adapter) external view returns (string[] memory) {
        return _adapterLabels[adapter];
    }

    /// @dev Setters only — see {IAssetKindRegistry.AdapterNotRegistered} for why the clearers deliberately skip this.
    ///      `isAdapterRegistered` is an O(1) mapping read on the NAV, so this costs one `staticcall` on a MANAGER
    ///      write path and nothing at all on the read path.
    function _requireRegisteredAdapter(address adapter) private view {
        if (!NAV.isAdapterRegistered(adapter)) revert AdapterNotRegistered(adapter);
    }

    /// @dev The scalar-override validator. Used by {setAdapterProtocolName} only — {setAdapterLabels} spells the same
    ///      two bounds out per element, because this one rejects `""` and `""` is that setter's SKIP sentinel.
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
    ///      {setAdapterLabels} make an adapter's label segments correctable without a redeploy.
    ///
    ///      ⚠️ **An earlier revision of this note said "only the CONSTANTS moved: the computed LEAF is untouched".
    ///      That stopped being true when {setAdapterLabels} replaced the segment-0-only scalar setter** — an override
    ///      can now be written at ANY index, a computed leaf included. What holds instead, and is the line that
    ///      matters, is that the leaf is not overridden BY DEFAULT and the mechanism is opt-in per segment: `""` at an
    ///      index leaves that segment derived live, and it is the value an operator is told to pass for every
    ///      computed index (see the sweep in `src/balances/BALANCE_ADAPTERS.md` §6.2). Overriding a computed leaf is
    ///      possible and is documented as a hazard rather than prevented: 23 of the 34 deployable adapters build the
    ///      leaf from on-chain state, so a stored value freezes a derivation across every instance, does not track
    ///      `addMetaInstances`, and masks a broken derivation one row at a time.
    ///
    ///      The repair this replaces was
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
