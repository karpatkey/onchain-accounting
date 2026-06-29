// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {AssistedNftCacheAdapter} from "src/balances/AssistedBalanceAdapters/AssistedNftCacheAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Nexus Mutual Staking Pools Balance Adapter (id-cached, assisted)
/// @author KPK
/// @notice Reports an account's staked NXM across Nexus Mutual V2 staking pools, as NXM-denominated
///         `Staking` (active + expired stake) and `Rewards` legs — emitted **per StakingNFT position**. Each stake
///         is an ERC-721 `StakingNFT`; the NFT is not per-owner-enumerable and the StakingViewer exposes no
///         owner→tokenIds view, so a pure-view adapter cannot discover the positions cheaply. Rather than scanning
///         the whole `StakingNFT` supply, an off-chain assistant (holder of `ASSISTANT_ROLE`) submits the account's
///         `tokenId`s via `submitTokenIds`; this adapter then values each entirely from live on-chain reads
///         (`StakingViewer.getTokens`), re-verifying ownership on every read via `StakingNFT.tokenInfo`. The cache
///         stores **only ids, never amounts** — a faulty or compromised assistant cannot fabricate value; at worst
///         it omits an id (NAV under-counts), never over-counts. One holder can have several positions, possibly
///         across several pools. positionId is the **staking-pool contract address**
///         (`abi.encode(StakingViewer.stakingPool(poolId))`); the NFT id is surfaced as the typed
///         `positionInstanceId` on each leg (the display labels are `["Staking Pools", "Pool #<poolId>"]`), not in
///         positionId.
/// @dev Access control comes from {AssistedBalanceAdapter}: `DEFAULT_ADMIN_ROLE` administers roles and
///      `ASSISTANT_ROLE` gates the submit/clear mutators. `submitTokenIds` **reverts** `NotTokenOwner` for any id
///      whose `tokenInfo` owner is not the account (fail-loud writes); reads instead **discard** an id no longer
///      owned (fail-open). See `docs/decisions/0015-assisted-balance-adapter-family.md` (Merkl precedent, ADR 0007).
///      The no-arg balance getters (`getAdapterBalances`/`getAdapterBalanceForAsset`) return the summed NXM total
///      across the account's owned, cached positions.
contract NexusMutualStakingPoolsAssistedBalanceAdapter is AssistedNftCacheAdapter, IPositionDescribable {
    using Strings for uint256;

    //
    // Constants
    //

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.NEXUS_MUTUAL;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.NEXUS_MUTUAL;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS;

    /// @notice Hard cap on cached tokenIds per account (returned by the {_maxTokenIds} hook the shared
    ///         {AssistedNftCacheAdapter} base enforces at submit time). The read path iterates the cache (one
    ///         `tokenInfo` per id) and hands the survivors to `getTokens`/`getAggregatedTokens`, which iterate each
    ///         token's tranches — an unbounded set could OOG inside the viewer (NOT caught by NAVCalculator's
    ///         try/catch). 64 is generous headroom over a real account (the OIV Safes hold a handful); the assistant
    ///         must GC closed positions.
    uint256 public constant MAX_TOKEN_IDS = 64;

    //
    // State
    //

    /// @notice Nexus Mutual StakingNFT (ERC-721; `tokenInfo(id) -> (poolId, owner)`).
    address public immutable STAKING_NFT;

    /// @notice Nexus Mutual StakingViewer — `getAggregatedTokens(ids)` totals stake + rewards in NXM.
    address public immutable STAKING_VIEWER;

    /// @notice The asset positions are denominated in (NXM). Must be a registered NAV asset.
    address public immutable UNDERLYING_TOKEN;

    /// @notice NAVCalculator — used to look up the registered NXM asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param stakingNft_      Nexus StakingNFT. Must be a contract.
    /// @param stakingViewer_   Nexus StakingViewer. Must be a contract.
    /// @param underlyingToken_ NXM token address.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `ASSISTANT_ROLE`). Required.
    /// @param assistant_       Initial holder of `ASSISTANT_ROLE` (optional; pass `address(0)` to grant later).
    constructor(
        address stakingNft_,
        address stakingViewer_,
        address underlyingToken_,
        address navCalculator_,
        address admin_,
        address assistant_
    ) AssistedNftCacheAdapter(admin_, assistant_) {
        if (
            stakingNft_ == address(0) || stakingViewer_ == address(0) || underlyingToken_ == address(0)
                || navCalculator_ == address(0)
        ) {
            revert InvalidArguments();
        }
        require(stakingNft_.code.length > 0, "StakingNFT must be a contract");
        require(stakingViewer_.code.length > 0, "StakingViewer must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        STAKING_NFT = stakingNft_;
        STAKING_VIEWER = stakingViewer_;
        UNDERLYING_TOKEN = underlyingToken_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // Cache hooks (AssistedNftCacheAdapter)
    //

    /// @inheritdoc AssistedNftCacheAdapter
    /// @dev Ownership read for the cache's write-time check: wraps `INexusStakingNFT.tokenInfo` so a non-existent /
    ///      burned id (which `tokenInfo` reverts on) returns `(0, false)` rather than bubbling.
    function _ownerOf(uint256 tokenId) internal view override returns (address, bool) {
        try INexusStakingNFT(STAKING_NFT).tokenInfo(tokenId) returns (uint256, address owner) {
            return (owner, true);
        } catch {
            return (address(0), false);
        }
    }

    /// @inheritdoc AssistedNftCacheAdapter
    function _maxTokenIds() internal pure override returns (uint256) {
        return MAX_TOKEN_IDS;
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IERC165
    /// @dev Adds {IPositionDescribable} on top of the family's base advertisement
    ///      ({IAssistedBalanceAdapter}/{IBalanceAdapter}/{IAccessControl}/{IERC165}).
    function supportsInterface(bytes4 interfaceId) public view override(AssistedBalanceAdapter) returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    function protocolName() external pure returns (string memory) {
        return "Nexus Mutual";
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Total NXM owed (stake + rewards). Net convenience getter; the split is in getAdapterPositions.
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset != UNDERLYING_TOKEN || account == address(0)) return (0, false);
        (uint256 staking, uint256 rewards) = _stakeAndRewards(account);
        return (staking + rewards, false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        (uint256 staking, uint256 rewards) = account == address(0) ? (0, 0) : _stakeAndRewards(account);
        uint256 total = staking + rewards;
        if (total == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
        isDebt[0] = false;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Per StakingNFT position: a `Staking` (active + expired stake) and a `Rewards` (accrued) leg, each
    ///         keyed by `positionId == abi.encode(stakingPoolAddress)` (NFT id in `positionInstanceId`). Zero legs are dropped;
    ///         ids no longer owned by `account` are discarded. Empty if NXM is unregistered, filtered out, or the
    ///         account holds no positions.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN) {
            return new INAVCalculator.PositionBalance[](0);
        }
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        uint256[] memory ids = _cachedTokenIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // NXM must be registered in NAVCalculator for the position to count in NAV. Resolve its Asset record once.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        (INAVCalculator.Asset memory underlying, bool registered) = RegisteredAssetLib.find(reg, UNDERLYING_TOKEN);
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        // Up to two legs (Staking + Rewards) per owned tokenId.
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2 * ids.length);
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            // Per-NFT fault isolation (fail-open, ADR 0015): value each id behind an external `this.` call so a revert
            // in its live reads (`tokenInfo` / `getTokens` / `stakingPool` on a stale or exotic position) is caught
            // here and that ONE id is discarded — it never propagates out of getAdapterPositions, where NAVCalculator's
            // per-adapter try/catch would otherwise fail-open and drop the account's ENTIRE Nexus stake. Mirrors the
            // Uniswap V3 adapter's `try this.positionLegs(...)` fan-out.
            try this.tokenLegs(account, underlying, ids[i]) returns (INAVCalculator.PositionBalance[] memory legs) {
                for (uint256 j; j < legs.length; ++j) {
                    temp[count++] = legs[j];
                }
            } catch {}
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; i++) {
            positions[i] = temp[i];
        }
    }

    /// @notice Values one cached `tokenId` into its (up to 2) legs: `Staking` (active + expired stake) + `Rewards`
    ///         (accrued), both NXM-denominated. Returns an empty array if the id is not owned by `account`, the token
    ///         has no stake/rewards, or its staking pool can't be resolved.
    /// @dev `external` so `getAdapterPositions` can invoke it via `this.` inside a per-NFT try/catch — a revert in any
    ///      live read (`tokenInfo` / `getTokens` / `stakingPool`) is then isolated to this one id (fail-open). Reads
    ///      the token live and re-verifies ownership via `StakingNFT.tokenInfo` (a burned id reverts → caught by the
    ///      caller → discarded; a transferred id returns a different owner → empty). NOT meant for external callers; it
    ///      is `external` only to enable the self-call isolation.
    function tokenLegs(address account, INAVCalculator.Asset calldata underlying, uint256 tokenId)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (msg.sender != address(this)) revert NotAuthorized(); // self-call-only (external solely for try/catch isolation)
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

        // positionId = the staking-pool contract address (deterministic per poolId). The tokenId is NOT in positionId;
        // it rides in the typed `positionInstanceId`. A zero pool (unresolvable poolId) yields no leg (under-report).
        address pool = INexusStakingViewer(STAKING_VIEWER).stakingPool(tokens[0].poolId);
        if (pool == address(0)) return none;
        bytes memory positionId = abi.encode(pool);
        // The StakingNFT id is the EPHEMERAL per-item coordinate — typed `positionInstanceId`, not a label and not in
        // positionId (the stable staking-pool address; an account's NFTs in one pool share it). Breadcrumb is derived
        // from positionId by `positionLabels`.
        bytes32 instanceId = bytes32(tokens[0].tokenId);

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

    //
    // Internal — valuation
    //

    /// @dev The cached tokenIds still owned by `account`, re-verified live via `StakingNFT.tokenInfo`. Discards
    ///      (never reverts) ids that were withdrawn/transferred away — the assistant can only under-report.
    function _ownedCachedIds(address account) internal view returns (uint256[] memory ids) {
        uint256[] memory cached = _cachedTokenIds(account);
        uint256[] memory found = new uint256[](cached.length);
        uint256 n;
        for (uint256 i; i < cached.length; ++i) {
            try INexusStakingNFT(STAKING_NFT).tokenInfo(cached[i]) returns (uint256, address owner) {
                if (owner == account) found[n++] = cached[i];
            } catch {}
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = found[i];
        }
    }

    /// @dev Total NXM owed to `account` across its owned, cached staking positions: stake (active + expired) and
    ///      rewards, valued in one `getAggregatedTokens` call. Never reverts (degrades to 0).
    function _stakeAndRewards(address account) internal view returns (uint256 staking, uint256 rewards) {
        uint256[] memory ids = _ownedCachedIds(account);
        if (ids.length == 0) return (0, 0);
        try INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids) returns (
            INexusStakingViewer.AggregatedTokens memory agg
        ) {
            staking = agg.totalActiveStake + agg.totalExpiredStake;
            rewards = agg.totalRewards;
        } catch {
            return (0, 0);
        }
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Staking Pools", "Pool #<poolId>"]` — the numeric pool id read live via `INexusStakingPool.getPoolId()`,
    ///      matching the Nexus UI's pool numbering. Falls back to the pool address (`"0x…"`) if the read reverts
    ///      (non-Nexus / exotic positionId). The pool's product name is off-chain (IPFS metadata) and not readable
    ///      on-chain. The per-NFT id is the typed `positionInstanceId` on each leg, NOT a label. Empty for a
    ///      short/malformed positionId.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory out) {
        if (positionId.length < 32) return new string[](0);
        address pool = abi.decode(positionId, (address));
        out = new string[](2);
        out[0] = "Staking Pools";
        // Low-level staticcall + length check (not a typed try/catch): a no-code / non-Nexus / fallback-only
        // positionId returns success with empty data, which a typed call would then fail to decode and REVERT
        // uncaught — this display view must never revert, so we read defensively and fall back to the address.
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSelector(INexusStakingPool.getPoolId.selector));
        out[1] = (ok && data.length >= 32)
            ? string.concat("Pool #", Strings.toString(abi.decode(data, (uint256))))
            : Strings.toHexString(pool);
    }

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
/// @dev `Token`/`Deposit` mirror the live StakingViewer ABI field-for-field (order matters for decoding);
///      this adapter only reads `tokenId`, `poolId`, `activeStake`, `expiredStake`, `rewards`.
interface INexusStakingViewer {
    struct Deposit {
        uint256 tokenId;
        uint256 trancheId;
        uint256 stake;
        uint256 stakeShares;
        uint256 reward;
    }

    /// @param tokenId The StakingNFT id.
    /// @param poolId The staking pool the position belongs to (fixed at mint).
    /// @param activeStake NXM actively staked for this token.
    /// @param expiredStake NXM in expired tranches (still withdrawable).
    /// @param rewards Accrued, unclaimed reward NXM.
    /// @param deposits Per-tranche deposit breakdown (unused here; present for ABI parity).
    struct Token {
        uint256 tokenId;
        uint256 poolId;
        uint256 activeStake;
        uint256 expiredStake;
        uint256 rewards;
        Deposit[] deposits;
    }

    /// @param totalActiveStake NXM actively staked across the given tokens.
    /// @param totalExpiredStake NXM in expired tranches (still withdrawable).
    /// @param totalRewards Accrued, unclaimed reward NXM.
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
interface INexusStakingPool {
    function getPoolId() external view returns (uint256);
}
