// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Nexus Mutual Staking Pools Assisted Balance Adapter (id-cached, wrapper-fed)
/// @author KPK
/// @notice Reports an account's staked NXM across Nexus Mutual V2 staking pools, as NXM-denominated `Staking`
///         (active + expired stake) and `Rewards` legs — emitted **per StakingNFT position**. Each stake is an ERC-721
///         `StakingNFT`; the NFT is not per-owner-enumerable and the StakingViewer exposes no owner→tokenIds view, so a
///         pure-view adapter cannot discover the positions cheaply. Instead, a trusted **wrapper contract** (holder of
///         `SUBMITTER_ROLE` — the `NexusMutualStakingPoolsWrapper`) pushes/pops the account's `tokenId`s via
///         {submit}/{remove} **atomically as it forwards deposits/withdrawals** to the Nexus staking pool, so the id
///         cache is kept current on-chain in the same transaction that changes the position. This adapter then values
///         each cached id entirely from live on-chain reads (`StakingViewer.getTokens`), re-verifying ownership on
///         every read via `StakingNFT.tokenInfo`. The cache stores **only ids, never amounts** — a faulty or
///         compromised wrapper cannot fabricate value; at worst it omits an id (NAV under-counts), never over-counts.
///         One holder can have several positions, possibly across several pools. positionId is the **staking-pool
///         contract address** (`abi.encode(StakingViewer.stakingPool(poolId))`); the NFT id is surfaced as the typed
///         `positionInstanceId` on each leg (the display labels are `["Staking Pools", "Pool #<poolId>"]`), not in
///         positionId.
/// @dev Assisted-family member (ADR 0015), wrapper-fed variant (ADR 0018): it is the documented immutability exception
///      and upholds the family invariant — cache coordinates only (never amounts), value every read live on-chain,
///      re-verify ownership per read — so the feeder can only **under-report, never over-report**. Access control is OZ
///      `AccessControl`: `DEFAULT_ADMIN_ROLE` administers `SUBMITTER_ROLE`, and `SUBMITTER_ROLE` (held by the wrapper) gates
///      the {submit}/{remove} mutators. {submit} **reverts** `NotTokenOwner` for any id whose `tokenInfo` owner is not
///      the account (fail-loud writes); reads instead **discard** an id no longer owned (fail-open). The convenience
///      balance getters (`getAdapterBalances`/`getAdapterBalanceForAsset`) sum the **same** per-id fault-isolated legs
///      the NAV path (`getAdapterPositions`) emits, so when NXM is registered the two views agree; they are
///      registration-independent (report the raw owed NXM even when NXM is unregistered, the one case where
///      getAdapterPositions is empty because NAV can't price it).
///
///      NOTE: this is intentionally a **single self-contained contract** — the id cache, the per-id fail-open valuation
///      fan-out, the access-control scaffolding, the Nexus valuation, and the single-asset getters are all inlined
///      rather than composed from shared bases. The shared abstractions are deferred to a later refactor.
contract NexusMutualStakingPoolsAssistedBalanceAdapter is AccessControl, IBalanceAdapter, IPositionDescribable {
    using EnumerableSet for EnumerableSet.UintSet;
    using Strings for uint256;

    //
    // Constants
    //

    /// @notice Role (held by the wrapper contract) authorized to feed/unfeed cached tokenIds via {submit}/{remove}.
    bytes32 public constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.NEXUS_MUTUAL;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.NEXUS_MUTUAL;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS;

    //
    // State
    //

    /// @notice Nexus Mutual StakingNFT (ERC-721; `tokenInfo(id) -> (poolId, owner)`).
    address public immutable STAKING_NFT;

    /// @notice Nexus Mutual StakingViewer — `getTokens(ids)` returns per-token stake + rewards in NXM.
    address public immutable STAKING_VIEWER;

    /// @notice The single asset this adapter reports (NXM). Must be a registered NAV asset for `getAdapterPositions`
    ///         to count it; the balance getters report it regardless (registration-independent).
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered NXM asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Candidate tokenIds cached per account (the only thing the wrapper supplies). An `EnumerableSet.UintSet`
    ///         gives dedup, O(1) membership/removal, and `values()` enumeration.
    mapping(address account => EnumerableSet.UintSet) private _tokenIds;

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

    //
    // Constructor
    //

    /// @param stakingNft_      Nexus StakingNFT. Must be a contract.
    /// @param stakingViewer_   Nexus StakingViewer. Must be a contract.
    /// @param underlyingToken_ NXM token address. Must be non-zero.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `SUBMITTER_ROLE`). Required.
    /// @param wrapper_         Initial holder of `SUBMITTER_ROLE` (the wrapper contract; optional — pass `address(0)` and
    ///        grant after the wrapper is deployed, since the wrapper needs this adapter's address at construction).
    constructor(
        address stakingNft_,
        address stakingViewer_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address wrapper_
    ) {
        if (
            stakingNft_ == address(0) || stakingViewer_ == address(0) || underlyingToken_ == address(0)
                || navCalculator_ == address(0) || admin_ == address(0)
        ) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(stakingNft_, "StakingNFT");
        AddressCheckLib.requireContract(stakingViewer_, "StakingViewer");
        AddressCheckLib.requireContract(navCalculator_, "NAVCalculator");

        STAKING_NFT = stakingNft_;
        STAKING_VIEWER = stakingViewer_;
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (wrapper_ != address(0)) _grantRole(SUBMITTER_ROLE, wrapper_);
    }

    //
    // Writes (SUBMITTER_ROLE) + admin rescue
    //

    /// @notice Track `tokenId` for `account` (idempotent). Called by the wrapper right after it forwards a deposit that
    ///         minted / topped-up the position. **Reverts** `NotTokenOwner` if `tokenId` is not currently owned by
    ///         `account`. No per-account cap: the wrapper only ever adds ids the caller owns via a real Nexus deposit,
    ///         so the set is bounded by the account's own deposits; a pathological account's large read is self-
    ///         inflicted and fail-opens (per-adapter) in NAVCalculator, never affecting other accounts.
    function submit(address account, uint256 tokenId) external onlyRole(SUBMITTER_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        // Fail-loud ownership check on EVERY submit: the tokenId must currently belong to `account`, or revert with
        // the custom `NotTokenOwner` error. A non-owned / burned / non-existent id is a caller mistake. Checked before
        // the dedup so it can never be bypassed by re-submitting an already-cached id.
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        // Idempotent: EnumerableSet.add dedups; only emit on a genuine insert.
        if (_tokenIds[account].add(tokenId)) emit TokenIdSubmitted(account, tokenId);
    }

    /// @notice Stop tracking `tokenId` for `account`. Called by the wrapper right after it forwards a withdrawal for
    ///         the position (Nexus does not burn the StakingNFT on withdraw, so the account still owns it). Verifies
    ///         the tokenId belongs to `account` (fail-loud, custom error) — symmetric with {submit}; a no-op (no
    ///         event) if the account owns it but it was not cached.
    function remove(address account, uint256 tokenId) external onlyRole(SUBMITTER_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        // Fail-loud ownership check: the tokenId must currently belong to `account`, or revert `NotTokenOwner`.
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert NotTokenOwner(account, tokenId);
        if (_tokenIds[account].remove(tokenId)) emit TokenIdCleared(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`. Admin-gated rescue (e.g. to reset a mis-fed account); the
    ///         normal path is the wrapper's per-position {submit}/{remove}.
    function clearAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EnumerableSet.UintSet storage set = _tokenIds[account];
        for (uint256 n = set.length(); n > 0; --n) {
            set.remove(set.at(n - 1));
        }
        emit AccountCleared(account);
    }

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account].values();
    }

    //
    // IBalanceAdapter — single-asset getters (NXM)
    //

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset) external view returns (uint256 amount, bool isDebt) {
        if (asset != UNDERLYING_TOKEN || account == address(0)) return (0, false);
        return (_owedAmount(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
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

    /// @dev Total NXM across `account`'s positions, summed from the SAME per-id fault-isolated leg path the NAV view
    ///      uses ({_collectLegs}) — so a single degenerate token drops from BOTH views identically. Registration-
    ///      INDEPENDENT: reports the raw NXM owed even when NXM is not (yet) a registered NAV asset (the leg's Asset
    ///      metadata does not affect the summed amount), passing a zeroed Asset as the read context.
    function _owedAmount(address account) internal view returns (uint256 total) {
        INAVCalculator.Asset memory underlying;
        INAVCalculator.PositionBalance[] memory legs = _collectLegs(account, address(0), abi.encode(underlying));
        for (uint256 i; i < legs.length; ++i) {
            total += legs[i].amount;
        }
    }

    //
    // IBalanceAdapter — positions (NAV path)
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice Per StakingNFT position: a `Staking` (active + expired stake) and a `Rewards` (accrued) leg, each keyed
    ///         by `positionId == abi.encode(stakingPoolAddress)` (NFT id in `positionInstanceId`). Zero legs are
    ///         dropped; ids no longer owned by `account` are discarded. Empty if NXM is unregistered, filtered out, or
    ///         the account holds no positions.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        (INAVCalculator.Asset memory underlying, bool registered) =
            RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), UNDERLYING_TOKEN);
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        return _collectLegs(account, assetFilter, abi.encode(underlying));
    }

    //
    // Per-id fail-open valuation fan-out
    //

    /// @dev Values all of `account`'s cached ids into a flat leg array, isolating a faulty id (fail-open, ADR 0015) so
    ///      a revert in one id's live reads never zeroes the whole account. `ctx` is the read-once NXM Asset record
    ///      (`abi.encode(INAVCalculator.Asset)`) — a zeroed Asset for the balance getters (amounts don't depend on it).
    function _collectLegs(address account, address assetFilter, bytes memory ctx)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        uint256[] memory ids = _tokenIds[account].values();
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // Up to 2 legs per StakingNFT: Staking (active + expired) + Rewards (accrued).
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](ids.length * 2);
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            // Per-id fault isolation: a revert in this id's live reads is caught here and only that id is discarded.
            try this.valueTokenIdSelf(account, ids[i], assetFilter, ctx) returns (
                INAVCalculator.PositionBalance[] memory legs
            ) {
                for (uint256 j; j < legs.length; ++j) {
                    temp[count++] = legs[j];
                }
            } catch {}
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = temp[i];
        }
    }

    /// @notice External self-call entrypoint for {_valueTokenId}, enabling the per-id try/catch isolation in
    ///         {_collectLegs}. `msg.sender`-guarded to `address(this)` so it is not a usable external surface; it is
    ///         `external` (hence the self-call is a staticcall) ONLY to give each id's valuation its own revert frame.
    function valueTokenIdSelf(address account, uint256 tokenId, address, /* assetFilter */ bytes calldata ctx)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        return _valueTokenId(account, tokenId, ctx);
    }

    /// @notice Values one cached `tokenId` into its (up to 2) legs: `Staking` (active + expired stake) + `Rewards`
    ///         (accrued), both NXM-denominated. Returns empty if the id is not owned by `account`, the token has no
    ///         stake/rewards, or its staking pool can't be resolved. Re-verifies ownership live via `tokenInfo`;
    ///         reached only via the self-call, so it may revert freely (the caller isolates it).
    function _valueTokenId(address account, uint256 tokenId, bytes memory ctx)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        INAVCalculator.Asset memory underlying = abi.decode(ctx, (INAVCalculator.Asset));
        INAVCalculator.PositionBalance[] memory none = new INAVCalculator.PositionBalance[](0);

        // Re-verify ownership live: a burned id reverts `tokenInfo` (caught by the caller's try/catch → discarded);
        // a transferred id returns a different owner → empty.
        (, address owner) = INexusStakingNFT(STAKING_NFT).tokenInfo(tokenId);
        if (owner != account) return none;

        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        INexusStakingViewer.Token[] memory tokens = INexusStakingViewer(STAKING_VIEWER).getTokens(one);
        if (tokens.length == 0) return none;

        // Active and expired stake are both staked NXM principal (expired tranches are no longer earning but remain
        // withdrawable); rewards are accrued NXM.
        uint256 staking = tokens[0].activeStake + tokens[0].expiredStake;
        uint256 rewards = tokens[0].rewards;
        if (staking == 0 && rewards == 0) return none;

        // positionId = the staking-pool contract address (deterministic per poolId). A zero pool (unresolvable poolId)
        // yields no leg (under-report). The tokenId rides in the typed `positionInstanceId`, not in positionId — use
        // the ownership-VERIFIED `tokenId` param, not the viewer's echoed-back `tokens[0].tokenId`.
        address pool = INexusStakingViewer(STAKING_VIEWER).stakingPool(tokens[0].poolId);
        if (pool == address(0)) return none;
        bytes memory positionId = abi.encode(pool);
        bytes32 instanceId = bytes32(tokenId);

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](2);
        uint256 n;
        if (staking > 0) tmp[n++] = _leg(underlying, staking, PositionKind.Staking, positionId, instanceId);
        if (rewards > 0) tmp[n++] = _leg(underlying, rewards, PositionKind.Rewards, positionId, instanceId);

        INAVCalculator.PositionBalance[] memory out = new INAVCalculator.PositionBalance[](n);
        for (uint256 k; k < n; ++k) {
            out[k] = tmp[k];
        }
        return out;
    }

    /// @dev Ownership read for the {submit} write-time check: wraps `INexusStakingNFT.tokenInfo` so a non-existent /
    ///      burned id (which `tokenInfo` reverts on) returns `(0, false)` rather than bubbling.
    function _ownerOf(uint256 tokenId) internal view returns (address owner, bool ok) {
        try INexusStakingNFT(STAKING_NFT).tokenInfo(tokenId) returns (uint256, address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
    }

    //
    // IPositionDescribable
    //

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "Nexus Mutual";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Staking Pools", "Pool #<poolId>"]` — the numeric pool id read live via `INexusMutualStakingPool.getPoolId()`,
    ///      matching the Nexus UI's pool numbering. Falls back to the pool address (`"0x…"`) if the read reverts
    ///      (non-Nexus / exotic positionId). Empty for a short/malformed positionId.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory out) {
        if (positionId.length < 32) return new string[](0);
        address pool = abi.decode(positionId, (address));
        out = new string[](2);
        out[0] = "Staking Pools";
        // Low-level staticcall + length check (not a typed try/catch): a no-code / non-Nexus / fallback-only
        // positionId returns success with empty data, which a typed call would then fail to decode and REVERT
        // uncaught — this display view must never revert, so we read defensively and fall back to the address.
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSelector(INexusMutualStakingPool.getPoolId.selector));
        out[1] = (ok && data.length >= 32)
            ? string.concat("Pool #", Strings.toString(abi.decode(data, (uint256))))
            : Strings.toHexString(pool);
    }

    //
    // ERC-165
    //

    /// @inheritdoc IERC165
    /// @dev Advertises {IBalanceAdapter} (required by the NAVCalculator registry) and {IPositionDescribable} on top of
    ///      {AccessControl}'s {IAccessControl}/{IERC165}.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId
            || interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Internal helpers
    //

    function _leg(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        PositionKind kind,
        bytes memory positionId,
        bytes32 positionInstanceId
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolBrand: PROTOCOL_BRAND,
            protocolId: PROTOCOL_ID,
            protocolSubId: PROTOCOL_SUB_ID,
            positionId: positionId,
            positionKind: kind,
            isLocked: false,
            positionInstanceId: positionInstanceId
        });
    }
}

/// @notice Minimal interface for Nexus Mutual's StakingNFT (ERC-721).
interface INexusStakingNFT {
    /// @notice The pool and owner of `tokenId`. Reverts for a non-existent id.
    function tokenInfo(uint256 tokenId) external view returns (uint256 poolId, address owner);
}

/// @notice Minimal interface for Nexus Mutual's StakingViewer.
/// @dev `Token`/`Deposit` mirror the live StakingViewer ABI field-for-field (order matters for decoding); this adapter
///      only reads `poolId`, `activeStake`, `expiredStake`, `rewards` (it uses the ownership-verified `tokenId` param,
///      not the viewer's echoed-back `Token.tokenId`).
interface INexusStakingViewer {
    struct Deposit {
        uint256 tokenId;
        uint256 trancheId;
        uint256 stake;
        uint256 stakeShares;
        uint256 reward;
    }

    struct Token {
        uint256 tokenId;
        uint256 poolId;
        uint256 activeStake;
        uint256 expiredStake;
        uint256 rewards;
        Deposit[] deposits;
    }

    struct AggregatedTokens {
        uint256 totalActiveStake;
        uint256 totalExpiredStake;
        uint256 totalRewards;
    }

    /// @notice Per-token stake + rewards (in NXM) for each given StakingNFT tokenId.
    function getTokens(uint256[] calldata tokenIds) external view returns (Token[] memory);

    /// @notice Aggregates stake + rewards (in NXM) across the given StakingNFT tokenIds.
    function getAggregatedTokens(uint256[] calldata tokenIds) external view returns (AggregatedTokens memory);

    /// @notice The (deterministic) staking-pool contract address for `poolId`. Used as the `positionId`.
    function stakingPool(uint256 poolId) external view returns (address);
}

/// @notice Minimal interface for a Nexus Mutual StakingPool — its numeric pool id, for the display label
///         (`"Pool #<id>"`). The pool's product name is off-chain (IPFS metadata), so it is not read here.
interface INexusMutualStakingPool {
    function getPoolId() external view returns (uint256);
}
