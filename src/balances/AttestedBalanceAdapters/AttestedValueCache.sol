// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAttestedBalanceAdapter} from "src/balances/IAttestedBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title AttestedValueCache
/// @author KPK
/// @notice Shared base for the **attested** balance-adapter family ({IAttestedBalanceAdapter}, ADR 0022) — the peer
///         of `AssistedCoordCache` in the assisted family, and deliberately shaped after it. It owns everything about
///         an attested adapter that is NOT protocol-specific, so a new member supplies only its proof scheme, its
///         epoch source, and how one asset's value becomes legs.
///
/// @dev **The family invariant this base enforces, and the one it cannot.**
///      *Enforced here:* the cache holds one `(value, epoch)` attestation per `(account, asset)`; every read values
///      the attestation LIVE through {_liveValue}; a cached entry whose `epoch` no longer equals {_liveEpoch} reads
///      **0** rather than being extrapolated; removal is **stale-gated** so no caller can suppress a live entry; and
///      the per-account asset set is capped and duplicate-free, which is the only thing standing between the cache
///      and a double-counted leg.
///      *NOT enforced here — the member's job:* that `value` was ever attested at all. This base never inspects a
///      proof. A member MUST verify its protocol's attestation before calling {_upsertAttestation}, because that is
///      the single point where an unproven number could enter the cache. The base is written so there is exactly one
///      such point rather than several.
///
///      **Why the cache is a VALUE cache and not a coordinate cache.** That is precisely what separates this family
///      from the assisted one. An assisted adapter caches coordinates and re-derives the amount on-chain every read,
///      so it structurally cannot over-report. An attested adapter caches a number that has no on-chain source — so
///      the guarantee is only as good as the per-write proof, which makes it a **procedurally** weaker sibling and
///      is why {_upsertAttestation} is `internal` and loudly documented rather than exposed.
///
///      **Elements are keyed by ASSET address, not by an opaque blob.** `AssistedCoordCache` keys on
///      `keccak256(coord)` because its coordinates are ticket/NFT ids with no natural address. An attested value is
///      always attested *for an asset* — it must resolve through `NAV_CALCULATOR.getRegisteredAsset` to be valued at
///      all — so the asset address IS the natural key. That keeps the hot read path free of the extra hashing and
///      `bytes` copies the coordinate cache pays. A member needing richer per-entry state (Merkl's campaign
///      breakdown) keeps its own mapping keyed by the same `(account, asset)` pair and threads it through the `ctx`
///      parameter of {_assetLegs}.
///
///      **Direction of every failure in this base is UNDER-report.** Legs are dropped, never fabricated: a stale
///      epoch reads 0, an unregistered asset is skipped, a starved element is dropped. Whether dropping is *safe*
///      depends on the member — see {_collectLegs}, which documents why the drop is licensed only for credit-only
///      members and what a debt-emitting member would have to change.
abstract contract AttestedValueCache is IAttestedBalanceAdapter, IPositionDescribable {
    //
    // Type Definitions
    //

    /// @notice One cached attestation per `(account, asset)`.
    /// @param value      The attested figure, in the asset's own units, as proven by the member's attestation
    ///                   scheme (Merkl: the per-token cumulative allocation). Never a NAV value.
    /// @param epoch      The attestation epoch the proof was verified against (Merkl: the Distributor merkle root).
    ///                   Reads return 0 once this no longer equals {_liveEpoch} — conservative stale handling.
    ///                   Also the entry's **presence sentinel**: a stored entry always has `epoch != 0`, because
    ///                   {_upsertAttestation} rejects a zero epoch. Deliberately NOT `attestedAt`, which would rest
    ///                   the anti-double-count guard on `block.timestamp != 0` — true on every live chain, but an
    ///                   incidental property of the environment rather than an invariant this code enforces.
    /// @param attestedAt Timestamp of the most recent successful write. An operator freshness signal ONLY; nothing
    ///                   in this base branches on it.
    struct Attestation {
        uint256 value;
        bytes32 epoch;
        uint64 attestedAt;
    }

    //
    // State
    //

    /// @notice NAVCalculator — resolves the `Asset` metadata every emitted leg carries.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @dev Cached attestations. **`private`, deliberately** — see {_upsertAttestation}. If this were `public`
    ///      (or `internal`) a member could write it directly, and the base's central claim would be enforced by a
    ///      docstring rather than by the compiler. The concrete over-report that buys: a member zeroing an entry's
    ///      `epoch` while the asset is still in `_assetList` makes the next {_upsertAttestation} compute
    ///      `isNew == true` and push the SAME asset a second time, after which the read values it twice and
    ///      `_removeAsset`'s swap-and-pop can only ever remove one copy. `_assetList` / `_assetIdxPlus1` were
    ///      already `private` for exactly this reason; this makes the visibility symmetric. Read access for members
    ///      is {_attestationOf}; there is deliberately no write accessor.
    mapping(address account => mapping(address asset => Attestation)) private _attestations;

    /// @dev Per-account asset enumeration. Attested adapters cannot enumerate their universe ahead of time (the set
    ///      of assets a protocol may attest is open), so {underlyingAssetsSupported} returns empty and the reads are
    ///      driven from this list instead of from an `address(0)` asset filter.
    mapping(address account => address[]) private _assetList;

    /// @dev `idxPlus1` = index of `asset` in `_assetList[account]` plus 1. Zero ⇒ not present.
    mapping(address account => mapping(address asset => uint256)) private _assetIdxPlus1;

    /// @notice The cached attestation for `(account, asset)`: `(value, epoch, attestedAt)`.
    /// @dev ABI-identical to the public mapping this replaced, so no consumer sees a difference. An entry with
    ///      `epoch == 0` is absent; a non-zero `epoch` that no longer equals {_liveEpoch} is stale and reads 0.
    function attestations(address account, address asset)
        external
        view
        returns (uint256 value, bytes32 epoch, uint64 attestedAt)
    {
        Attestation memory a = _attestations[account][asset];
        return (a.value, a.epoch, a.attestedAt);
    }

    /// @dev Read-only accessor for members. There is deliberately NO write accessor: {_upsertAttestation} is the
    ///      only way a value enters the cache.
    function _attestationOf(address account, address asset) internal view returns (Attestation memory) {
        return _attestations[account][asset];
    }

    //
    // Events
    //

    /// @notice Emitted on every `(account, asset)` upsert.
    /// @param submitter The caller that fed this attestation (`msg.sender`). Recorded for off-chain attribution
    ///                  ONLY — this family is submit-on-behalf-of and permissionless, so it is NOT an authorization
    ///                  check and carries no privilege. Integrity comes from the member's proof.
    event AttestationCached(
        address indexed account,
        address indexed asset,
        address indexed submitter,
        uint256 value,
        bytes32 epoch,
        uint64 attestedAt
    );
    event AttestationCleared(address indexed account, address indexed asset);
    event AccountCleared(address indexed account);

    //
    // Errors
    //

    /// @notice The NAVCalculator supplied at construction cannot serve `getRegisteredAsset(address)` — it predates
    ///         that getter, or is not a NAVCalculator at all. Refused at deploy because the failure it would
    ///         otherwise cause is SILENT (see the constructor).
    error NAVCalculatorTooOld(address navCalculator);

    /// @notice {_liveEpoch} returned zero (the attestation source is uninitialized). Rejected rather than stored,
    ///         because a zero epoch would collide with the presence sentinel.
    error UninitializedEpoch();

    /// @notice Adding this asset would exceed {_maxAssetsPerAccount} distinct cached assets for `account`.
    error TooManyAttestations(address account, uint256 count);

    /// @notice A clear was attempted on an entry that still contributes to NAV (its epoch is live AND it values
    ///         non-zero). Clearing is GC for dead entries only — a live entry can only be *refreshed* by a fresh
    ///         attestation, never suppressed. This is what makes permissionless clearing safe.
    error AttestationStillLive(address account, address asset);

    /// @notice A clear was attempted on an `(account, asset)` with nothing cached.
    error NothingToClear();

    /// @notice The same asset appeared more than once in a {previewPositions} payload. The cache path upserts
    ///         (last-writer-wins, no double count), but a stateless preview would emit a leg set per occurrence — an
    ///         over-report, the one direction this family forbids — so it is rejected fail-loud.
    error DuplicateAsset(address asset);

    //
    // Constructor
    //

    /// @param navCalculator_ The NAVCalculator. Must be a contract that can serve `getRegisteredAsset(address)`.
    /// @dev **NAV-VERSION PROBE — why an adapter refuses to be born against a NAVCalculator that is too old.** Every
    ///      read path in this base resolves asset metadata through the O(1) `getRegisteredAsset(address)`, which is
    ///      NEWER than the whole-registry `getRegisteredAssets()` that most plain adapters use via
    ///      `RegisteredAssetLib`. Pinned to a NAVCalculator that cannot serve the selector, the missing-function
    ///      revert lands in the adapter's OWN frame with a tiny `consumed`, so `GasStipendLib.exhausted` reads false,
    ///      `PriceFeedLib._getAdapterPositions` fails OPEN, and the adapter reports ZERO legs — for every account,
    ///      forever, with no error and a green CI. Members are immutable, so the only remedy would be a redeploy
    ///      nobody has been told is needed. Mirrors `MetaBalanceAdapter`'s constructor guard; keep the two in sync.
    ///
    ///      **Success alone proves nothing, which is why the length is checked too.** A contract with a bare
    ///      `fallback() external {}` answers any selector with success and EMPTY returndata. The 192-byte floor is
    ///      the minimum a real `(Asset, bool)` reply can occupy — `Asset` is `(address, string, uint8)`, hence
    ///      dynamic: 2 head words (offset, bool) + 3 words for Asset's head + 1 word for the empty string's length.
    ///      The `address(0)` argument elicits exactly that minimum, since `found == false` zeroes the struct, which
    ///      makes 192 the largest floor with no false positives.
    ///
    ///      **What it does NOT catch**, so the guarantee is not over-read: a UUPS *downgrade* of the NAV
    ///      implementation AFTER construction leaves the guard long since passed (members are immutable and cannot
    ///      re-probe on the hot path), and pointing at a NAVCalculator *implementation* rather than its proxy passes,
    ///      because the implementation serves the selector honestly and merely has empty storage. It binds the
    ///      deploy, not the lifetime.
    constructor(address navCalculator_) {
        if (navCalculator_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        (bool ok, bytes memory ret) =
            navCalculator_.staticcall(abi.encodeWithSelector(INAVCalculator.getRegisteredAsset.selector, address(0)));
        if (!ok || ret.length < 192) revert NAVCalculatorTooOld(navCalculator_);

        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Mutators — clearing (permissionless, stale-gated)
    //

    /// @notice Drop one cached attestation — **stale-gated GC**. Permissionless, but reverts
    ///         {AttestationStillLive} while the entry still contributes to NAV, so a live entry can only ever be
    ///         *refreshed*, never suppressed by a third party.
    /// @dev **Scope, precisely:** this protects entries that are IN the cache. It does not guarantee an entry can
    ///      GET in — admission is capped at {_maxAssetsPerAccount} and fails loud.
    ///
    ///      **"Stale" is not permanent, and this gate is instantaneous — so a clear here can outlive the staleness
    ///      that licensed it.** If the member's epoch source can return to a previous value (Merkl's
    ///      `getMerkleRoot()` does, by design, during a dispute window), an entry cleared while its epoch was not
    ///      live does NOT come back when that epoch does. Direction is under-report and it self-heals on the next
    ///      feed cycle. Retaining stale entries instead would make them un-clearable for the whole window, which is
    ///      the un-evictable-slot condition behind cap-exhaustion outages — trading an under-report that recovers on
    ///      its own for one that wedges until a human intervenes.
    function clearAttestation(address account, address asset) external {
        if (account == address(0) || asset == address(0)) revert InvalidArguments();
        if (_attestations[account][asset].epoch == bytes32(0)) revert NothingToClear();
        if (_valueOf(account, asset) != 0) revert AttestationStillLive(account, asset);
        _deleteAttestation(account, asset);
        _removeAsset(account, asset);
        _deleteMemberState(account, asset); // last: the cache is fully settled before member code runs
        emit AttestationCleared(account, asset);
    }

    /// @inheritdoc IAttestedBalanceAdapter
    /// @dev Stale-gated **bulk** GC: reverts on the first of `account`'s assets that still contributes to NAV, so a
    ///      live set can never be suppressed — it clears only when the whole set is dead.
    function clearAccount(address account) external override {
        if (account == address(0)) revert InvalidArguments();
        address[] memory list = _assetList[account];
        if (list.length == 0) revert NothingToClear();
        for (uint256 i; i < list.length; ++i) {
            if (_valueOf(account, list[i]) != 0) revert AttestationStillLive(account, list[i]);
        }
        for (uint256 i; i < list.length; ++i) {
            _deleteAttestation(account, list[i]);
            delete _assetIdxPlus1[account][list[i]];
        }
        delete _assetList[account];
        // Member hooks LAST, in a second pass, for the ordering reason on {_deleteAttestation}: no member code may
        // run while any part of this account's cache is still half-cleared.
        for (uint256 i; i < list.length; ++i) {
            _deleteMemberState(account, list[i]);
        }
        emit AccountCleared(account);
    }

    //
    // Reads — introspection
    //

    /// @notice Assets currently cached for `account`.
    /// @dev Returned regardless of staleness. Filter at the call site on `attestations(account, asset).epoch`.
    function assetsOf(address account) external view returns (address[] memory) {
        return _assetList[account];
    }

    /// @inheritdoc IERC165
    /// @dev Advertises the family marker plus the two adapter interfaces every member implements. A member adding a
    ///      further interface overrides and `super`s.
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAttestedBalanceAdapter).interfaceId
            || interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Open-universe family: an attested adapter's asset set is not enumerable ahead of time, so this
    ///         returns empty. The interface allows it, and the reads drive off the per-account cache instead.
    function underlyingAssetsSupported() external view virtual override returns (address[] memory) {
        return new address[](0);
    }

    //
    // Reads — IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        virtual
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        return (_valueOf(account, asset), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        virtual
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) return (new address[](0), new uint256[](0), new bool[](0));

        address[] memory list = _assetList[account];
        uint256 n = list.length;
        address[] memory tmpAssets = new address[](n);
        uint256[] memory tmpAmounts = new uint256[](n);
        uint256 count;

        for (uint256 i; i < n; ++i) {
            uint256 bal = _valueOf(account, list[i]);
            if (bal != 0) {
                tmpAssets[count] = list[i];
                tmpAmounts[count] = bal;
                ++count;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
        }
    }

    /// @inheritdoc IBalanceAdapter
    /// @dev Resolves `assetFilter` here so the build frame's only parameters are `(account, assets)` — keeping the
    ///      filter param, which is stack-bottom for this whole body, off the build loop's stack, which would
    ///      otherwise overflow the via_ir limit.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        address[] memory toProcess;
        if (assetFilter != address(0)) {
            if (_assetIdxPlus1[account][assetFilter] == 0) return new INAVCalculator.PositionBalance[](0);
            toProcess = new address[](1);
            toProcess[0] = assetFilter;
        } else {
            toProcess = _assetList[account];
        }

        // Nothing cached (the overwhelmingly common case, since an adapter is registered globally and queried for
        // every account): return before the self-call, so an empty cache pays for neither the extra frame nor the
        // per-asset registry lookups. Those lookups are charged against the per-adapter stipend
        // `PriceFeedLib._getAdapterPositions` forwards.
        if (toProcess.length == 0) return new INAVCalculator.PositionBalance[](0);

        positions = this.buildPositionsSelf(account, toProcess);
    }

    /// @notice External self-call entrypoint for the row-building loop. `msg.sender`-guarded to `address(this)` so
    ///         it is not a usable external surface — it exists only to give the build its own stack frame. `view`,
    ///         so the self-call is a staticcall.
    function buildPositionsSelf(address account, address[] calldata assets)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        return _collectLegs(account, assets);
    }

    //
    // Reads — cache-free preview
    //

    /// @inheritdoc IAttestedBalanceAdapter
    /// @dev The generic half of the preview: guards and the self-call frame. The member owns
    ///      {_verifyPreviewPayload}, which is where its proof scheme lives.
    function previewPositions(address account, bytes calldata data)
        external
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0) || data.length == 0) return new INAVCalculator.PositionBalance[](0);
        return this.previewPositionsSelf(account, data);
    }

    /// @notice External self-call frame for the preview loop — `msg.sender`-guarded to `address(this)`. `view`, so
    ///         the self-call is a staticcall. Mirrors {buildPositionsSelf}.
    /// @dev Fetches the epoch ONCE and hands it to the member, so a payload can never be verified against a
    ///      different epoch than the one its legs are valued under.
    function previewPositionsSelf(address account, bytes calldata data)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (msg.sender != address(this)) revert NotAuthorized();

        bytes32 epoch = _liveEpoch();
        if (epoch == bytes32(0)) revert UninitializedEpoch();

        (address[] memory assets, uint256[] memory values, bytes[] memory ctxs) =
            _verifyPreviewPayload(epoch, account, data);
        // The three are indexed in lockstep below. A member returning ragged arrays would otherwise surface as a
        // bare Panic 0x32; fail loud with an attributable error instead.
        if (values.length != assets.length || ctxs.length != assets.length) revert InvalidArguments();
        if (assets.length == 0) return new INAVCalculator.PositionBalance[](0);
        if (assets.length > _maxAssetsPerAccount()) revert TooManyAttestations(account, assets.length);
        _revertOnDuplicateAsset(assets);

        return _buildVerifiedLegs(account, assets, values, ctxs);
    }

    //
    // Internal — cache mutation
    //

    /// @dev Add or refresh one attestation. **THE SINGLE POINT WHERE A NUMBER ENTERS THE CACHE** — the caller MUST
    ///      have verified its protocol attestation for `(account, asset, value)` against `epoch` before calling.
    ///      This base cannot check that, and it is the whole basis of the family's guarantee.
    ///
    ///      **Upsert, never replace.** Only the named `(account, asset)` is touched; assets omitted by a feeder are
    ///      left alone, so a caller can add or refresh proven data but can NEVER suppress a live entry it omits.
    ///      Removal is only via the stale-gated clears.
    ///
    ///      The new-asset branch keys on `epoch == 0`, NOT on `attestedAt`. That branch is the only thing standing
    ///      between the cache and a DUPLICATE entry in the enumeration list, which would value one asset twice — an
    ///      OVER-report, the one direction this family forbids. `epoch` is a sentinel this contract enforces
    ///      itself (a zero epoch is rejected above), whereas `attestedAt != 0` would rest on `block.timestamp != 0`.
    /// @return isNew True when this call admitted a new asset rather than refreshing an existing one.
    function _upsertAttestation(address account, address asset, uint256 value, bytes32 epoch)
        internal
        returns (bool isNew)
    {
        if (account == address(0) || asset == address(0)) revert InvalidArguments();
        if (epoch == bytes32(0)) revert UninitializedEpoch();

        Attestation storage a = _attestations[account][asset];
        isNew = a.epoch == bytes32(0);
        if (isNew) {
            uint256 n = _assetList[account].length;
            if (n >= _maxAssetsPerAccount()) revert TooManyAttestations(account, n);
            _assetList[account].push(asset);
            _assetIdxPlus1[account][asset] = _assetList[account].length;
        }

        a.value = value;
        a.epoch = epoch;
        a.attestedAt = uint64(block.timestamp);

        emit AttestationCached(account, asset, msg.sender, value, epoch, a.attestedAt);
    }

    /// @dev Erase one attestation's base record. **DELIBERATELY `private`, so it cannot be overridden**, because
    ///      this is the ONLY deletion of `_attestations` in the base and an override that forgot to call `super`
    ///      would permanently wedge the entry — the record would survive while the clear delisted the asset, after
    ///      which re-admission computes `isNew == false` and never re-pushes, leaving the pair invisible to
    ///      {getAdapterPositions}/{getAdapterBalances} while {getAdapterBalanceForAsset} still reported it, and
    ///      unrecoverable because the clear that would reset it now reverts `AttestationStillLive`.
    ///
    ///      **It deliberately does NOT invoke {_deleteMemberState}.** Callers run that LAST, once the record AND
    ///      the enumeration are both settled, because the hook is the one place in a clear where MEMBER code
    ///      executes. Invoking it here — between the record delete and the enumeration update — would expose the
    ///      exact `record absent, asset still enumerated` state that {_upsertAttestation}'s `isNew` branch reads as
    ///      "new": a member whose hook called back into a submit (directly, or by making an external call that
    ///      re-enters) would push the still-enumerated asset a SECOND time, and the read would value it twice.
    ///      That is the duplicate-push OVER-report the `private` mapping closes at the member's own level, and
    ///      ordering is what closes it at the hook's.
    function _deleteAttestation(address account, address asset) private {
        delete _attestations[account][asset];
    }

    /// @notice Drop any extra per-`(account, asset)` state the member keeps alongside the attestation (Merkl's
    ///         campaign breakdown), so it goes in lockstep with the clears. Default: genuinely nothing.
    /// @dev Called by every deletion path in this base, and always **LAST** — after the record has been erased and
    ///      the asset delisted, so member code never observes a half-cleared cache. A member overriding it need NOT
    ///      call `super`: the base's own record is erased by {_deleteAttestation}, which is `private` precisely so
    ///      that guarantee does not depend on the member remembering.
    function _deleteMemberState(address account, address asset) internal virtual {
        account;
        asset;
    }

    /// @dev Swap-and-pop `asset` out of `account`'s enumeration, keeping the index map exact.
    function _removeAsset(address account, address asset) private {
        uint256 idxPlus1 = _assetIdxPlus1[account][asset];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        address[] storage list = _assetList[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            address last = list[lastIdx];
            list[idx] = last;
            _assetIdxPlus1[account][last] = idx + 1;
        }
        list.pop();
        delete _assetIdxPlus1[account][asset];
    }

    //
    // Internal — valuation
    //

    /// @dev The cached attestation's live value, or 0 when nothing is cached or the epoch has moved on.
    ///      **Stale ⇒ 0, never extrapolated** — a new epoch requires a fresh attestation.
    function _valueOf(address account, address asset) internal view returns (uint256) {
        Attestation memory a = _attestations[account][asset];
        if (a.epoch == bytes32(0)) return 0;
        if (a.epoch != _liveEpoch()) return 0;
        return _liveValue(account, asset, a.value);
    }

    /// @dev Values each of `assets` in its own stipended frame and flattens the legs.
    ///
    ///      **PER-ASSET ISOLATION.** Without it, one asset's failure escapes the whole adapter two ways: a plain
    ///      revert bubbles out of {getAdapterPositions} and `PriceFeedLib._getAdapterPositions` fails open, costing
    ///      the account its ENTIRE leg set for this adapter; an out-of-gas bubbles, is classified by
    ///      `GasStipendLib.exhausted`, and `AdapterGasExhausted` takes down the account's WHOLE `getAccountNav`.
    ///
    ///      This bounds per-item FAILURE. It does NOT bound aggregate SIZE — stipends partition cost, they do not
    ///      shrink it — which is what {_maxAssetsPerAccount} times the member's write-enforced per-asset leg cap is for. The two are not
    ///      substitutes: isolation alone still leaves a well-behaved read at the cap unaffordable, and the caps
    ///      alone still lose the whole set to one reverting asset.
    ///
    ///      **The budget is SHARED across the assets still to value, not 63/64 to whoever is first.**
    ///      `GasStipendLib.stipendFrom` alone is right for a SINGLE forwarded call and wrong inside a loop: the
    ///      first asset would take 63/64 of the frame, leaving 1/64 for every remaining asset AND for the final
    ///      array construction — which was measured, on the first member, to revert a read that succeeded without
    ///      the griefing asset present. Dividing by the remaining count bounds each asset to its fair slice; because
    ///      `gasleft()` is re-read every iteration, assets that finish cheaply hand their unused share onward, so
    ///      the healthy path is not starved.
    ///
    ///      **DROPPING a failed asset is licensed here, and that licence is conditional.** It is safe only because
    ///      every leg an attested member emits today is a CREDIT. A dropped leg can then only make reported NAV
    ///      SMALLER, which is the direction this family already guarantees. `AssistedCoordCache` raises
    ///      `CoordinateGasExhausted` instead precisely because a future member of THAT family could emit a debt leg,
    ///      and silently dropping a debt leg makes NAV LARGER — the one direction this codebase forbids.
    ///      **A member that can emit a debt leg MUST override this and raise instead of dropping.**
    ///
    ///      All-or-nothing per asset, mirroring `NAVCalculator._MAX_LABEL_ELEMENTS`: an asset that half-computed
    ///      before exhausting its stipend has its legs discarded as a unit, because a truncated answer reads as a
    ///      complete one.
    function _collectLegs(address account, address[] memory assets)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        // PRE-FILTER to the assets that will actually be VALUED. This is not tidy-up: the stipend denominator below
        // must count only assets that get a frame. Counting assets that are then skipped as unregistered reserves
        // budget nothing ever spends, so an early registered asset is funded as if the skipped ones were still
        // coming and can be dropped for want of gas while most of the frame goes unused.
        //
        // Resolve through the O(1) `getRegisteredAsset(address)`, NOT the O(N) whole-registry `getRegisteredAssets()`
        // copy, whose cost is super-linear in the REGISTRY size rather than in this account's asset count.
        address[] memory live = new address[](assets.length);
        INAVCalculator.Asset[] memory metas = new INAVCalculator.Asset[](assets.length);
        uint256 liveCount;
        for (uint256 i; i < assets.length; ++i) {
            (INAVCalculator.Asset memory meta, bool found) = NAV_CALCULATOR.getRegisteredAsset(assets[i]);
            if (!found) continue;
            live[liveCount] = assets[i];
            metas[liveCount] = meta;
            ++liveCount;
        }
        if (liveCount == 0) return new INAVCalculator.PositionBalance[](0);

        // Per-asset declared leg counts, kept so the copy below can be bounded against THIS asset's own slice
        // rather than against the shared buffer — see the bound in the loop.
        uint256[] memory legCaps = new uint256[](liveCount);
        uint256 cap;
        for (uint256 i; i < liveCount; ++i) {
            legCaps[i] = _cachedLegCount(account, live[i]);
            cap += legCaps[i];
        }

        // COMPLETION RESERVE, held back from every stipend so the loop can always finish: the catch arm and the
        // final allocation-and-copy must stay affordable after the LAST asset consumes everything it was given.
        // Without it the last asset's denominator is 1, so it receives the whole remaining stipend and completion is
        // funded only by `stipendFrom`'s 1/64 slack — a shrinking absolute amount. Scaled by the leg cap because the
        // copy is what it pays for, and that is O(legs).
        uint256 reserve = _completionReservePerLeg() * cap;

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](cap);
        uint256 count;
        for (uint256 i; i < liveCount; ++i) {
            uint256 available = gasleft();
            uint256 budget = available > reserve ? available - reserve : 0;
            uint256 stipend = GasStipendLib.stipendFrom(budget) / (liveCount - i);
            try this.assetLegsSelf{gas: stipend}(account, live[i], metas[i]) returns (
                INAVCalculator.PositionBalance[] memory legs
            ) {
                // BOUND AGAINST THIS ASSET'S OWN SLICE, not against the shared buffer. {_cachedLegCount} is a
                // member hook and the legs come from the unrelated {_assetLegs}; the monolith derived both from
                // one expression so they could not disagree, but here they can, and writing past `tmp` raises
                // Panic 0x32 in THIS frame — outside the per-asset `try`, so the catch below cannot absorb it. It
                // would bubble out of {getAdapterPositions}, `PriceFeedLib` would fail open, and the adapter's
                // ENTIRE leg set would silently leave NAV for every account.
                //
                // The slice is what makes the blast radius honest. An earlier version bounded on
                // `count == tmp.length`, i.e. the ACCOUNT-WIDE buffer: an over-emitting asset then consumed the
                // capacity reserved for the assets after it, and those lost ALL their legs rather than none —
                // "drops only the surplus" was false, and a single-asset test could not see it. Capping each
                // asset at what it declared confines the loss to that asset's own surplus.
                //
                // **This is the SECOND silent-drop site in this function**, and a debt-emitting member must treat
                // it exactly like the `catch` arm below: dropping a DEBT leg makes NAV LARGER. Overriding
                // {_collectLegs} to raise on `catch` while leaving this bound intact would re-open the over-report
                // direction through the quieter of the two doors.
                uint256 taken;
                for (uint256 j; j < legs.length; ++j) {
                    if (taken == legCaps[i]) break;
                    tmp[count++] = legs[j];
                    ++taken;
                }
            } catch {
                // Drop this asset entirely — never revert, and never emit a partial set for it. See the docstring.
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @notice External self-call entrypoint for one asset's legs, enabling the per-asset isolation in
    ///         {_collectLegs}. `msg.sender`-guarded to `address(this)`. `view`, so the self-call is a staticcall.
    ///         Mirrors `AssistedCoordCache.valueCoordSelf`.
    function assetLegsSelf(address account, address asset, INAVCalculator.Asset memory meta)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        uint256 value = _valueOf(account, asset);
        // Early return before the member touches its own storage when there is nothing to value (the common case).
        if (value == 0) return new INAVCalculator.PositionBalance[](0);
        return _assetLegs(account, asset, meta, value, _attestations[account][asset].value, "");
    }

    /// @dev Shared tail of the preview: skip assets NAVCalculator does not price, value each through the SAME
    ///      {_liveValue} and {_assetLegs} the cache path uses — so the two can never diverge — and compact.
    ///      Unlike the cache read this does NOT gas-stipend or try/catch per asset: it is the caller's own
    ///      `eth_call` gas, and a bad proof MUST surface rather than be caught and dropped.
    function _buildVerifiedLegs(address account, address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
        private
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        uint256 cap;
        for (uint256 i; i < assets.length; ++i) {
            cap += _previewLegCount(ctxs[i]);
        }
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](cap);
        uint256 count;

        for (uint256 i; i < assets.length; ++i) {
            (INAVCalculator.Asset memory meta, bool found) = NAV_CALCULATOR.getRegisteredAsset(assets[i]);
            if (!found) continue;
            uint256 live = _liveValue(account, assets[i], values[i]);
            if (live == 0) continue;
            INAVCalculator.PositionBalance[] memory legs =
                _assetLegs(account, assets[i], meta, live, values[i], ctxs[i]);
            // FAIL LOUD here, unlike the cache path. The silent drop in {_collectLegs} is licensed by the NAV
            // read's fail-open behaviour — losing a leg beats losing the account's whole NAV. This path has
            // neither: it is the caller's own `eth_call`, documented fail-loud, and a member whose
            // {_previewLegCount} under-declares is a bug the caller should see rather than a truncated answer
            // that reads as complete.
            if (count + legs.length > tmp.length) revert InvalidArguments();
            for (uint256 k; k < legs.length; ++k) {
                tmp[count++] = legs[k];
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @dev Reverts {DuplicateAsset} if any asset appears twice. O(n²) over ≤ {_maxAssetsPerAccount} entries; the
    ///      preview caller pays its own `eth_call` gas.
    function _revertOnDuplicateAsset(address[] memory assets) private pure {
        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j = i + 1; j < assets.length; ++j) {
                if (assets[i] == assets[j]) revert DuplicateAsset(assets[i]);
            }
        }
    }

    /// @dev Builds one PositionBalance row with the family's conventions: `balanceAdapter` is always
    ///      `address(this)` (the audit trail), `amount` is always positive, and `isDebt` / `isLocked` default false.
    ///      Field-by-field rather than a struct literal to stay under the via_ir stack limit on the hot path.
    function _row(INAVCalculator.Asset memory asset, uint256 amount, bytes memory pid, bytes32 instanceId)
        internal
        view
        returns (INAVCalculator.PositionBalance memory row)
    {
        row.balanceAsset = asset;
        row.balanceAdapter = address(this);
        row.amount = amount;
        row.protocolBrand = _protocolBrand();
        row.protocolId = _protocolId();
        row.protocolSubId = _protocolSubId();
        row.positionId = pid;
        row.positionKind = _positionKind();
        row.positionInstanceId = instanceId;
    }

    //
    // Hooks — the member's protocol
    //

    /// @notice The current attestation epoch (Merkl: `Distributor.getMerkleRoot()`). MUST be cheap: it is read on
    ///         every valuation. Returning zero means "uninitialized" and is rejected fail-loud on writes.
    function _liveEpoch() internal view virtual returns (bytes32);

    /// @notice Turn a cached/verified attested figure into the amount to report NOW, reading live protocol state
    ///         (Merkl: `attestedValue − Distributor.claimed(...)`, floored at 0). Reached only after the epoch has
    ///         been established as live, so it must not re-check staleness.
    /// @dev **POSTCONDITION: the return value SHOULD NOT exceed `attestedValue`.** Nothing here clamps it, and that
    ///      is deliberate — a clamp would be wrong for a member whose live figure can legitimately grow past what
    ///      was attested (an attested principal that accrues on-chain, say). But the family's guarantee is that the
    ///      **attestation bounds the reported number**, so a member that can exceed it has stepped outside that
    ///      guarantee and MUST say so explicitly in its own docs: past that point "under-report only" no longer
    ///      follows from the proof, and the over-report direction is live. Merkl satisfies the postcondition
    ///      trivially — it subtracts a non-negative claimed amount.
    function _liveValue(address account, address asset, uint256 attestedValue) internal view virtual returns (uint256);

    /// @notice Per-account cache cap — the only bound this base enforces.
    /// @dev **It is NOT the read bound on its own.** The leg count is this cap times the member's per-asset leg
    ///      fan-out, and it is that PRODUCT a read budget must be sized against. The base deliberately does not
    ///      declare a `_maxLegsPerAsset` hook: the per-asset cap belongs on the WRITE path, enforced fail-loud by
    ///      the member before the data exists (Merkl's `TooManyCampaigns`), because rejecting at write is what keeps
    ///      the read bounded. A read-side hook would either duplicate that or silently truncate. The base needs only
    ///      {_cachedLegCount}, the ACTUAL count, to size its scratch buffer.
    function _maxAssetsPerAccount() internal pure virtual returns (uint256);

    /// @notice Legs this asset will emit from the CACHE, for scratch-buffer sizing. Default: one. A member that
    ///         splits an asset into sub-positions overrides it.
    /// @dev **MUST be an UPPER BOUND on what {_assetLegs} returns for the same asset.** The two are separate hooks
    ///      that the base cannot reconcile, so under-declaring would write past the scratch buffer. {_collectLegs}
    ///      bounds the copy defensively, so the consequence is the surplus legs being dropped rather than the whole
    ///      read dying — but the legs are lost silently, so get this right rather than relying on the backstop.
    function _cachedLegCount(address account, address asset) internal view virtual returns (uint256) {
        account;
        asset;
        return 1;
    }

    /// @notice Legs a PREVIEW entry will emit, from that entry's `ctx`. Default: one.
    /// @dev Same upper-bound requirement as {_cachedLegCount}, for the preview's buffer.
    function _previewLegCount(bytes memory ctx) internal view virtual returns (uint256) {
        ctx;
        return 1;
    }

    /// @notice Build one asset's legs. Shared by the cache read (which passes an empty `ctx`, so the member reads
    ///         its own storage) and the preview (which passes the caller-supplied breakdown), so both produce
    ///         identical legs from identical inputs.
    /// @param liveValue     What to report — already resolved through {_liveValue}, always non-zero here.
    /// @param attestedValue The attested figure `liveValue` derives from; the denominator for any pro-rata split.
    /// @param ctx           Member-defined per-entry context. **Empty on the cache path**, which members use to
    ///                       decide "read my own storage" vs "use the caller's payload". That convention is
    ///                       load-bearing and easy to break from the preview side: `abi.encode` of an EMPTY array
    ///                       is 64 bytes, not 0, so an empty breakdown still arrives as non-empty `ctx` — but a
    ///                       member that returns a literal `bytes("")` from {_verifyPreviewPayload} for a
    ///                       breakdown-less entry would silently fall through to CACHED state while valuing a
    ///                       caller-supplied amount, mixing the two paths. Never return an empty `ctx` from the
    ///                       preview; encode the empty collection instead.
    function _assetLegs(
        address account,
        address asset,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256 attestedValue,
        bytes memory ctx
    ) internal view virtual returns (INAVCalculator.PositionBalance[] memory);

    /// @notice Decode and VERIFY a preview payload against `epoch`, returning parallel arrays. **This is where the
    ///         member's proof scheme lives, and it MUST be the same verification the write path uses** — otherwise
    ///         the preview and the cache can disagree, which is the one thing the shared valuation tail exists to
    ///         prevent. Fail-loud: an invalid proof MUST revert, not be skipped.
    function _verifyPreviewPayload(bytes32 epoch, address account, bytes calldata data)
        internal
        view
        virtual
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs);

    /// @notice Gas withheld from the per-asset stipends, per leg, so the read can complete after the last asset
    ///         consumes everything it was given. Overridable; the default is the value the first member measured.
    function _completionReservePerLeg() internal pure virtual returns (uint256) {
        return 256;
    }

    //
    // Hooks — typed position identity
    //

    function _protocolBrand() internal pure virtual returns (bytes32);
    function _protocolId() internal pure virtual returns (bytes32);
    function _protocolSubId() internal pure virtual returns (bytes32);

    /// @notice The `PositionKind` every leg carries. **If a member returns a kind that can be a DEBT leg, it must
    ///         also override {_collectLegs} to raise rather than drop** — see that function's docstring.
    function _positionKind() internal pure virtual returns (PositionKind);
}
