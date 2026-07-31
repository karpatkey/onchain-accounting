// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice One cached coordinate ran out of the gas the valuation fan-out forwarded it, so the account's reported
///         total is missing that coordinate — and, because the residue left to the loop cannot fund the ones after
///         it, very likely every coordinate behind it too.
/// @dev The sibling of `INAVCalculator.InstanceGasExhausted`, one family over. Reports `_coordId` — the
///      concrete adapter's human-facing tokenId / requestId / positionTicket — rather than the internal
///      `keccak256(coord)` dedup key, matching every other `Coordinate*` error in `src/errors.sol`. That hook
///      exists precisely so an operator can act on the error without reversing a hash. Deliberately declared HERE rather
///      than in `src/errors.sol`: both pinned libraries (`PriceFeedLib`, `NAVRegistryLib`) plain-import that file,
///      so adding to it would put this symbol inside both CREATE2 compilation closures for no benefit — nothing
///      outside this family raises or catches it. Keeping it file-local keeps this change provably pin-neutral.
error CoordinateGasExhausted(address adapter, uint256 coordId, uint256 stipend, uint256 consumed);

/// @title AssistedCoordCache
/// @author KPK
/// @notice The single cache base for the **permissionless, assistant-fed** assisted balance-adapter family. A position
///         *coordinate* is an opaque `bytes` blob, so ONE cache serves every member regardless of coordinate shape:
///         a bare `uint256` NFT tokenId / withdrawal requestId (`abi.encode(id)`) or a richer tuple (StakeWise V3 exit
///         positions, `abi.encode(vault, positionTicket, timestamp)`). It holds the per-account coordinate-record cache
///         (blobs deduped by their keccak key) and its `msg.sender`-keyed CRUD, plus the single-underlying-asset
///         {IBalanceAdapter} getter surface and the per-coordinate fail-open valuation fan-out. The concrete adapter
///         exposes a *typed* `submit`/`remove` that `abi.encode`s its coordinate and routes to {_submitCoord}/
///         {_removeCoord}, and implements {_valueCoord} (decode + value live), {_validateCoord} (fail-loud write-time
///         hygiene), {_removable}, {_coordId}, {_maxCoords}, {_maxLegsPerCoord}.
/// @dev Permissionless & self-scoped: no roles; all mutators key on `msg.sender`, so a caller can only ever touch its
///      OWN set. The canonical feeder is a {BalanceAdapterAssistant} the owner Safe delegatecalls (so `msg.sender` is the
///      Safe). The family invariant holds — coordinates only, valued live, ownership re-verified per read → under-report
///      only.
///
///      **WHAT THIS FILE CANNOT SHOW YOU — the cache is COMPLETE in production, not merely conservative.** Read on its
///      own, this contract is a permissionless cache with no completeness guarantee whatsoever: anyone may `submit`
///      their own coordinates, nobody is obliged to, and the assistant is the *canonical feeder* rather than a gate. So
///      "under-report only" is the honest reading of THIS code — and it understates the deployed system. The portfolio
///      Safes' **roles-modifier permission set allows the corresponding protocol entries only through the assistant
///      contracts; the direct protocol entrypoint is not in the allow-list.** A position of these types therefore
///      cannot be active without its coordinate having been fed here. Two complementary halves: *contract level* (this
///      file) → cannot **over**-report; *roles level* (**outside this repository**) → cannot **under**-report either.
///      Enforcement is in the Safe's roles configuration, which is not part of this repo — treat this as a pointer to
///      it, not as an operational rule someone must remember. **Residual risk:** not a bypass by an operator (not
///      permitted), but a **change to the roles permission set adding a path that reaches the protocol without the
///      assistant** — after which this cache silently misses positions and nothing in this repository would detect it,
///      because every invariant above still holds. See `AssistedBalanceAdapters/README.md` §5.0 and ADRs 0015 / 0018.
///
///      Uses a `bytes[]` array + `key → idxPlus1` map for dedup and O(1) swap-pop removal. Reads isolate each
///      coordinate behind a self-`staticcall` ({valueCoordSelf}), so a revert-prone valuation (e.g. Nexus's
///      `StakingViewer.getTokens`) only drops that one coordinate, never the account's whole set.
abstract contract AssistedCoordCache is IAssistedBalanceAdapter {
    /// @notice The single asset this adapter reports. Must be a registered NAV asset for {getAdapterPositions} to count
    ///         it; the balance getters report it regardless (registration-independent).
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered underlying-asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Cached coordinate blobs per account (the only thing the feeder supplies). Each is an `abi.encode` of the
    ///         concrete adapter's tuple.
    mapping(address account => bytes[] coords) private _coords;

    /// @dev `idxPlus1` = index of the coordinate in `_coords[account]` plus 1, keyed by `keccak256(coord)`. Zero ⇒ not
    ///      present (dedup + O(1) removal).
    mapping(address account => mapping(bytes32 key => uint256)) private _idxPlus1;

    /// @notice `id` is the concrete adapter's human-facing coordinate id ({_coordId}: a tokenId / requestId /
    ///         positionTicket) — indexed so consumers can filter, matching the legacy per-adapter events.
    event CoordSubmitted(address indexed account, uint256 indexed id);
    event CoordCleared(address indexed account, uint256 indexed id);
    event AccountCleared(address indexed account);

    /// @param underlyingToken_ The reported underlying asset. Must be non-zero.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    constructor(address underlyingToken_, address navCalculator_) {
        if (underlyingToken_ == address(0) || navCalculator_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Writes (permissionless — each account feeds/cleans its own cache, keyed on msg.sender)
    //

    /// @inheritdoc IAssistedBalanceAdapter
    function clearAccount() external {
        bytes[] storage list = _coords[msg.sender];
        for (uint256 i; i < list.length; ++i) {
            delete _idxPlus1[msg.sender][keccak256(list[i])];
        }
        delete _coords[msg.sender];
        emit AccountCleared(msg.sender);
    }

    //
    // Reads
    //

    /// @notice Candidate coordinate blobs currently cached for `account` (display/debug; not staleness-filtered).
    function coordsOf(address account) external view returns (bytes[] memory) {
        return _cachedCoords(account);
    }

    /// @dev The cached coordinate blobs for `account`, for the concrete adapter's typed read helpers / valuation.
    function _cachedCoords(address account) internal view returns (bytes[] memory) {
        return _coords[account];
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view virtual override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        virtual
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset != UNDERLYING_TOKEN || account == address(0)) return (0, false);
        return (_owedAmount(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        virtual
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 total = account == address(0) ? 0 : _owedAmount(account);
        if (total == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        (INAVCalculator.Asset memory underlying, bool registered) =
            RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), UNDERLYING_TOKEN);
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        return _collect(account, underlying);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IAssistedBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // Internal — cache mutation (called by the concrete's typed submit/remove)
    //

    /// @dev Add one coordinate for the caller (idempotent). Fail-loud: `CoordinateCacheFull` past {_maxCoords}, and
    ///      {_validateCoord} reverts (`InvalidCoordinate` / `CoordinateNotOwned`) on a bad or non-owned coordinate.
    ///      Keyed on `msg.sender` (self-scoped).
    function _submitCoord(bytes memory coord) internal {
        address account = msg.sender;
        bytes32 key = keccak256(coord);
        // Re-validate on EVERY submit (before the dedup early-return) so a resubmit of an already-cached coordinate the
        // caller has since transferred away is rejected loud rather than silently kept.
        _validateCoord(account, coord); // fail-loud write-time hygiene
        if (_idxPlus1[account][key] != 0) return; // already cached (idempotent no-op)
        if (_coords[account].length >= _maxCoords()) revert CoordinateCacheFull(account, _maxCoords());
        _coords[account].push(coord);
        _idxPlus1[account][key] = _coords[account].length;
        emit CoordSubmitted(account, _coordId(coord));
    }

    /// @dev Drop one coordinate for the caller. Fail-loud: **reverts**
    ///      `CoordinateNotCached` if the caller isn't tracking `coord`, and `CoordinateStillLive` if it is not yet
    ///      removable (see {_removable}) — so a live position is never silently dropped. Keyed on `msg.sender`.
    function _removeCoord(bytes memory coord) internal {
        address account = msg.sender;
        bytes32 key = keccak256(coord);
        uint256 idxPlus1 = _idxPlus1[account][key];
        if (idxPlus1 == 0) revert CoordinateNotCached(account, _coordId(coord));
        if (!_removable(account, coord)) revert CoordinateStillLive(account, _coordId(coord));
        uint256 idx = idxPlus1 - 1;
        bytes[] storage list = _coords[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            bytes memory last = list[lastIdx];
            list[idx] = last;
            _idxPlus1[account][keccak256(last)] = idx + 1;
        }
        list.pop();
        delete _idxPlus1[account][key];
        emit CoordCleared(account, _coordId(coord));
    }

    //
    // Internal — valuation
    //

    /// @dev Total `UNDERLYING_TOKEN` owed across `account`'s cached coordinates (registration-independent — zeroed Asset).
    function _owedAmount(address account) internal view returns (uint256 total) {
        INAVCalculator.Asset memory zero;
        INAVCalculator.PositionBalance[] memory legs = _collect(account, zero);
        for (uint256 i; i < legs.length; ++i) {
            total += legs[i].amount;
        }
    }

    /// @dev Values every cached coordinate of `account` into a flat leg array, isolating each coordinate behind a
    ///      per-item `this.valueCoordSelf(...)` staticcall wrapped in try/catch — so a revert in one coordinate's live
    ///      reads discards only THAT coordinate and never propagates out of {getAdapterPositions} (where NAVCalculator's
    ///      per-adapter try/catch would otherwise fail-open and drop the account's ENTIRE set). Coordinates whose
    ///      valuation is internally safe pay only the extra call frame (negligible on the async NAV read path, ADR 0017).
    ///
    ///      **The isolation is deliberate and stays — but it must not absorb a STARVED coordinate.** A coordinate
    ///      whose protocol read reverts has answered: it contributes nothing, and one bad NFT must not cost the
    ///      account its other positions. Gas exhaustion is categorically different. The coordinate did not answer,
    ///      recording it as zero legs silently deletes a real position, and — because a starved child takes 63/64
    ///      of what the loop held — the ~1/64 residue cannot fund the coordinates AFTER it either, so one starved
    ///      entry can quietly empty the rest of the list. `_collect` would still RETURN, so nothing downstream can
    ///      tell the answer was partial: `PriceFeedLib._getAdapterPositions` only inspects its own catch arm, and
    ///      this frame never reverted. That is the one failure this loop must not swallow, so it raises
    ///      {CoordinateGasExhausted} instead.
    ///
    ///      The classification is {GasStipendLib}'s, not restated here — the same shared threshold
    ///      `MetaBalanceAdapter._positionsForInstances` and `PriceFeedLib._getAdapterPositions` use, so the three
    ///      cannot drift apart.
    ///
    ///      Direction note, so the severity is not overstated: this family emits credit legs only
    ///      (`isDebt = false` throughout), so swallowing a coordinate under-reports rather than over-reports. That
    ///      is a property of today's three members, not of this base — a future member emitting a debt leg would
    ///      make the swallowed case an over-report, and this guard is what stops that being a silent one.
    function _collect(address account, INAVCalculator.Asset memory underlying)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        bytes[] memory list = _coords[account];
        if (list.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](list.length * _maxLegsPerCoord());
        uint256 count;
        for (uint256 i; i < list.length; ++i) {
            // One sample, used both to derive the stipend and to measure against it — see GasStipendLib.exhausted.
            uint256 available = gasleft();
            uint256 stipend = GasStipendLib.stipendFrom(available);
            try this.valueCoordSelf{gas: stipend}(account, list[i], underlying) returns (
                INAVCalculator.PositionBalance[] memory legs
            ) {
                for (uint256 j; j < legs.length; ++j) {
                    temp[count++] = legs[j];
                }
            } catch {
                uint256 consumed = available - gasleft();
                if (GasStipendLib.exhausted(stipend, consumed)) {
                    revert CoordinateGasExhausted(address(this), _coordId(list[i]), stipend, consumed);
                }
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
    }

    /// @notice External self-call entrypoint for {_valueCoord}, enabling the per-coordinate try/catch isolation in
    ///         {_collect}. `msg.sender`-guarded to `address(this)` so it is not a usable external surface; it is
    ///         `external` (so the self-call is a staticcall) ONLY to give each coordinate its own revert frame.
    function valueCoordSelf(address account, bytes calldata coord, INAVCalculator.Asset calldata underlying)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        return _valueCoord(account, coord, underlying);
    }

    //
    // Hooks (concrete adapter)
    //

    /// @notice The per-account cache cap (read-loop gas bound).
    function _maxCoords() internal view virtual returns (uint256);

    /// @notice Upper bound on legs emitted per coordinate (scratch-buffer sizing).
    function _maxLegsPerCoord() internal pure virtual returns (uint256);

    /// @notice The human-facing id for a coordinate (a positionTicket / requestId), used only to populate the shared
    ///         `Coordinate*` errors. The stable dedup/lookup key is `keccak256(coord)`; this is a decoded scalar for
    ///         legibility.
    function _coordId(bytes memory coord) internal pure virtual returns (uint256);

    /// @notice Write-time validation for a submitted coordinate. MUST revert (fail-loud) on an invalid coordinate:
    ///         `InvalidCoordinate` for a malformed/unregistered target, `CoordinateNotOwned` if it does not resolve to
    ///         a live position owned by `account`.
    function _validateCoord(address account, bytes memory coord) internal view virtual;

    /// @notice Whether `coord` may be removed from `account`'s cache. Default: only when it no longer resolves to a
    ///         live owed amount for `account` (claimed / consumed) — so {_removeCoord} never drops a live position
    ///         (under-report only). Implemented per adapter (the liveness proxy is protocol-specific).
    function _removable(address account, bytes memory coord) internal view virtual returns (bool);

    /// @notice Values a single cached coordinate into its legs (empty if it contributes nothing — not owned, claimed,
    ///         zero amount). Decodes `coord` and re-verifies ownership live. Reached only via the self-`staticcall` in
    ///         {_collect}, so it MAY revert freely — the caller isolates it (a reverting coordinate is discarded).
    function _valueCoord(address account, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);
}
