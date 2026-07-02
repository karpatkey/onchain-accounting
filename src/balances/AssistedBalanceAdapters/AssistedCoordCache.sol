// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedCoordCache
/// @author KPK
/// @notice Sibling of {AssistedNftIdCache} for the **permissionless, wrapper-fed** assisted adapters whose position
///         coordinate is a **tuple** rather than a bare `uint256` — e.g. StakeWise V3 exit positions, keyed by
///         `(vault, positionTicket, timestamp)` whose full preimage the valuation needs. It holds the per-account
///         coordinate-record cache (opaque `bytes` blobs, deduped by their keccak key) and its `msg.sender`-keyed CRUD,
///         plus the single-underlying-asset {IBalanceAdapter} getter surface. The concrete adapter exposes a *typed*
///         `submit`/`remove` that `abi.encode`s its tuple and routes to {_submitCoord}/{_removeCoord}, and implements
///         {_valueCoord} (decode + value live) and {_validateCoord} (fail-loud write-time hygiene).
/// @dev Permissionless & self-scoped (same trust model as {AssistedNftIdCache}): no roles; all mutators key on
///      `msg.sender`, so a caller can only ever touch its OWN set. The family invariant holds — coordinates only, valued
///      live, ownership re-verified per read → under-report only. Uses a `bytes[]` array + `key → idxPlus1` map for
///      dedup and O(1) swap-pop removal. Valuation is a direct loop (no self-`staticcall` isolation): tuple valuations
///      here are internally try/catch-safe, so they never revert out of the read.
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

    event CoordSubmitted(address indexed account, bytes32 indexed key);
    event CoordCleared(address indexed account, bytes32 indexed key);
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
        if (_idxPlus1[account][key] != 0) return; // already cached (idempotent no-op)
        if (_coords[account].length >= _maxCoords()) revert CoordinateCacheFull(account, _maxCoords());
        _validateCoord(account, coord); // fail-loud write-time hygiene
        _coords[account].push(coord);
        _idxPlus1[account][key] = _coords[account].length;
        emit CoordSubmitted(account, key);
    }

    /// @dev Drop one coordinate for the caller. Fail-loud (symmetric with {AssistedNftIdCache.remove}): **reverts**
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
        emit CoordCleared(account, key);
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

    /// @dev Values every cached coordinate of `account` into a flat leg array (direct loop; {_valueCoord} is
    ///      internally safe).
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
            INAVCalculator.PositionBalance[] memory legs = _valueCoord(account, list[i], underlying);
            for (uint256 j; j < legs.length; ++j) {
                temp[count++] = legs[j];
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
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

    /// @notice Values a single cached coordinate into its legs (empty if it contributes nothing). Decodes `coord`,
    ///         re-verifies ownership live, and MUST NOT revert (all external reads try/catch to 0).
    function _valueCoord(address account, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);
}
