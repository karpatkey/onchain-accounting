// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AssistedNftIdCache
/// @author KPK
/// @notice Shared base for the **permissionless, wrapper-fed** assisted balance adapters whose position coordinate is a
///         single `uint256` — a non-enumerable NFT tokenId or a sequential withdrawal/exit `requestId` (Nexus Mutual
///         StakingNFT, ether.fi / Stader withdrawal requests). It contributes: the per-account id cache and its
///         `msg.sender`-keyed CRUD, the single-underlying-asset {IBalanceAdapter} getter surface (all derived from one
///         per-id valuation hook), and self-service {clearAccount}. Concrete adapters implement only the protocol
///         hooks: {_ownerOf}, {_maxTokenIds}, {_valueTokenId}, {_maxLegsPerId}, plus {IPositionDescribable}.
/// @dev **Permissionless & self-scoped** (ADR: wrapper-fed assisted family). There is no AccessControl and no role:
///      {submit}/{remove}/{clearAccount} all key on `msg.sender`, so a caller can only ever mutate its OWN cached set.
///      The canonical feeder is a {BalanceAdapterWrapper} the owner Safe `delegatecall`s, so `msg.sender` seen here is
///      the Safe (== the position owner). The family invariant holds regardless of the feeder: the cache stores **ids
///      only, never amounts**; every read values live on-chain and re-verifies ownership (a coordinate no longer owned
///      values to 0 and emits no leg), so a faulty feeder can only **under-report, never over-report**.
///
///      The cache is an OpenZeppelin `EnumerableSet.UintSet` per account (dedup + O(1) add/remove + `values()`
///      enumeration). {submit} is fail-loud (reverts on a non-owned id or a full cache); {remove} is idempotent and
///      unconditional — dropping a still-live id is harmless (it only under-reports), so no ownership gate is needed.
///
///      Valuation fan-out is a virtual: this base calls {_valueTokenId} **directly**, which is correct for adapters
///      whose per-id valuation is internally try/catch-safe (never reverts). Adapters whose valuation can revert
///      extend {AssistedNftIdValuation} instead, which overrides {_collect} to isolate each id behind a self-`staticcall`.
abstract contract AssistedNftIdCache is IAssistedBalanceAdapter {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice The single asset this adapter reports (the redeemed / claimable / staked underlying). Must be a
    ///         registered NAV asset for {getAdapterPositions} to count it; the balance getters report it regardless
    ///         (registration-independent).
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered underlying-asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Candidate coordinate ids cached per account (the only thing the feeder supplies).
    mapping(address account => EnumerableSet.UintSet) private _tokenIds;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
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

    /// @notice Track `tokenId` for the caller (idempotent). The canonical caller is the owner Safe (via a
    ///         delegatecalled wrapper), right after it forwards the deposit/request that created the coordinate.
    ///         **Reverts** `CoordinateNotOwned` if `tokenId` is not currently owned by the caller (wrong id, burned, or
    ///         non-existent), and `CoordinateCacheFull` if a new id would grow the caller's set past {_maxTokenIds}.
    /// @dev Keyed on `msg.sender`: an account can only ever add ids it actually owns to its own cache. The ownership
    ///      check runs on EVERY submit (before the dedup) so a resubmit of an id the caller no longer owns is rejected
    ///      loud rather than silently kept; a genuine duplicate is a no-op (no event).
    function submit(uint256 tokenId) external {
        _submit(msg.sender, tokenId);
    }

    /// @notice Stop tracking `tokenId` for the caller. The cleanup path a Safe runs after it claims/exits. Fail-loud:
    ///         **reverts** `CoordinateNotCached` if the caller isn't tracking `tokenId`, and `CoordinateStillLive` if
    ///         the id is not yet removable (see {_removable}) — so a mistaken call is loud and a live position is never
    ///         silently dropped.
    /// @dev Keyed on `msg.sender`. The removability predicate is {_removable}; the default only permits removing a
    ///      coordinate the caller no longer owns (claimed/burned), which upholds the under-report-only invariant.
    ///      Protocols whose position persists after the value leaves it (the NFT is not burned on close) override
    ///      {_removable}.
    function remove(uint256 tokenId) external {
        EnumerableSet.UintSet storage set = _tokenIds[msg.sender];
        if (!set.contains(tokenId)) revert CoordinateNotCached(msg.sender, tokenId);
        if (!_removable(msg.sender, tokenId)) revert CoordinateStillLive(msg.sender, tokenId);
        set.remove(tokenId);
        emit TokenIdCleared(msg.sender, tokenId);
    }

    /// @inheritdoc IAssistedBalanceAdapter
    function clearAccount() external {
        _clear(msg.sender);
        emit AccountCleared(msg.sender);
    }

    //
    // Reads
    //

    /// @notice Candidate ids currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account].values();
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
    /// @dev Values each cached id live (`_valueTokenId`), re-verifying ownership: ids not owned by `account` / claimed
    ///      / invalid value to 0 and emit no leg. Dropped entirely if `UNDERLYING_TOKEN` is not registered in NAV.
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
    // Internal — cache mutation
    //

    /// @dev Shared submit body: cap + fail-loud ownership check, then dedup add. Caller supplies the account
    ///      (`msg.sender` from the public {submit}).
    function _submit(address account, uint256 tokenId) internal {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        // Ownership re-check on EVERY submit (before dedup) so it can't be bypassed by re-submitting a cached id.
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert CoordinateNotOwned(account, tokenId);
        if (set.contains(tokenId)) return; // idempotent — already cached
        uint256 cap = _maxTokenIds();
        if (set.length() >= cap) revert CoordinateCacheFull(account, cap);
        set.add(tokenId);
        emit TokenIdSubmitted(account, tokenId);
    }

    /// @notice Whether `tokenId` may be removed from `account`'s cache. Default: only when `account` no longer owns it
    ///         (claimed / burned / transferred away) — so {remove} can never drop a live position (under-report only).
    ///         Protocols whose position NFT **persists** after the value is withdrawn (so "no longer owned" never
    ///         holds) override this — e.g. to permit removal unconditionally.
    function _removable(address account, uint256 tokenId) internal view virtual returns (bool) {
        (address owner, bool ok) = _ownerOf(tokenId);
        return !(ok && owner == account);
    }

    /// @dev Delete `account`'s whole cached set (storage only, no per-id event). Each `remove` is O(1) swap-pop.
    function _clear(address account) private {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
    }

    /// @dev The cached ids for `account`, for the valuation loop (which re-verifies ownership and discards non-owned).
    function _cachedTokenIds(address account) internal view returns (uint256[] memory) {
        return _tokenIds[account].values();
    }

    //
    // Internal — valuation
    //

    /// @dev Total `UNDERLYING_TOKEN` owed across `account`'s cached ids. Registration-independent: sums the SAME legs
    ///      the NAV path emits, valued with a zeroed Asset (amounts do not depend on Asset metadata), so the two views
    ///      agree when the asset is registered.
    function _owedAmount(address account) internal view returns (uint256 total) {
        INAVCalculator.Asset memory zero;
        INAVCalculator.PositionBalance[] memory legs = _collect(account, zero);
        for (uint256 i; i < legs.length; ++i) {
            total += legs[i].amount;
        }
    }

    /// @dev Values every cached id of `account` into a flat leg array. This base calls {_valueTokenId} **directly** —
    ///      correct for adapters whose per-id valuation never reverts. {AssistedNftIdValuation} overrides this to
    ///      isolate each id behind a self-`staticcall` (fault isolation for reverting valuations).
    function _collect(address account, INAVCalculator.Asset memory underlying)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        uint256[] memory ids = _cachedTokenIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](ids.length * _maxLegsPerId());
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            INAVCalculator.PositionBalance[] memory legs = _valueTokenId(account, ids[i], underlying);
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

    /// @notice Reads the coordinate's owner for the write-time ownership check. MUST NOT revert — return `(0, false)`
    ///         for a burned / claimed / non-existent id (wrap the protocol read in try/catch).
    function _ownerOf(uint256 tokenId) internal view virtual returns (address owner, bool ok);

    /// @notice The per-account cache cap (read-loop gas bound). A real account never approaches it.
    function _maxTokenIds() internal view virtual returns (uint256);

    /// @notice Values a single cached `tokenId` into its legs (empty if it contributes nothing — not owned, invalid,
    ///         zero amount). MUST re-verify ownership live. `underlying` is the read-once registered Asset (zeroed when
    ///         called from the balance getters). Called via a self-`staticcall` in {AssistedNftIdValuation}, so it may
    ///         revert freely there; when reached directly (this base) it MUST NOT revert.
    function _valueTokenId(address account, uint256 tokenId, INAVCalculator.Asset memory underlying)
        internal
        view
        virtual
        returns (INAVCalculator.PositionBalance[] memory);

    /// @notice Upper bound on legs emitted per id (scratch-buffer sizing in {_collect}). E.g. 1 for a single-leg
    ///         withdrawal request; 2 for Nexus (Staking + Rewards) or a claimable/locked split.
    function _maxLegsPerId() internal pure virtual returns (uint256);
}
