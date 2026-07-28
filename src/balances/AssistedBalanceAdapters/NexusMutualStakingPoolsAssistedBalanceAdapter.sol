// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AssistedCoordCache} from "./AssistedCoordCache.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Nexus Mutual Staking Pools Assisted Balance Adapter (id-cached, assistant-fed)
/// @author KPK
/// @notice Reports an account's staked NXM across Nexus Mutual V2 staking pools, as NXM-denominated `Staking`
///         (active + expired stake) and `Rewards` legs — emitted **per StakingNFT position**. The StakingNFT is not
///         per-owner-enumerable, so a trusted feeder pushes/pops the account's `tokenId`s via {submit}/{remove}. The
///         canonical feeder is `NexusMutualStakingPoolsAssistant`, delegatecalled by the owner Safe so the adapter sees
///         `msg.sender = Safe = owner`. Each cached id is valued live (`StakingViewer.getTokens`), re-verifying
///         ownership via `StakingNFT.tokenInfo` every read; the cache stores **ids only, never amounts**.
/// @dev Member of the permissionless assistant-fed assisted family ([ADR 0018](../../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)),
///      extending the single {AssistedCoordCache}: the coordinate is `abi.encode(tokenId)`. `StakingViewer.getTokens`
///      can revert, but {AssistedCoordCache} values each coordinate behind a self-`staticcall`, so a bad id is isolated.
///      positionId is the **staking-pool contract address** (`StakingViewer.stakingPool(poolId)`); the NFT id rides in
///      `positionInstanceId`. **{_removable} is value-based**: Nexus does NOT burn the StakingNFT on withdraw, so "no
///      longer owned" is not a liveness proxy — an id is removable only once it is no longer owned by the account OR is
///      fully emptied (no stake/rewards). A partial/rewards-only withdraw leaves a live position that stays tracked.
contract NexusMutualStakingPoolsAssistedBalanceAdapter is AssistedCoordCache, IPositionDescribable {
    using Strings for uint256;

    /// @notice Hard cap on cached tokenIds per account (read-loop gas bound). A real account never approaches it.
    uint256 public constant MAX_TOKEN_IDS = 256;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.NEXUS_MUTUAL;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.NEXUS_MUTUAL;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS;

    /// @notice Nexus Mutual StakingNFT (ERC-721; `tokenInfo(id) -> (poolId, owner)`).
    address public immutable STAKING_NFT;

    /// @notice Nexus Mutual StakingViewer — `getTokens(ids)` returns per-token stake + rewards in NXM.
    address public immutable STAKING_VIEWER;

    /// @param stakingNft_      Nexus StakingNFT. Must be a contract.
    /// @param stakingViewer_   Nexus StakingViewer. Must be a contract.
    /// @param underlyingToken_ NXM token address. Must be non-zero.
    /// @param navCalculator_   NAVCalculator. Must be a contract.
    constructor(address stakingNft_, address stakingViewer_, address underlyingToken_, address navCalculator_)
        AssistedCoordCache(underlyingToken_, navCalculator_)
    {
        if (stakingNft_ == address(0) || stakingViewer_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(stakingNft_, "StakingNFT");
        AddressCheckLib.requireContract(stakingViewer_, "StakingViewer");
        STAKING_NFT = stakingNft_;
        STAKING_VIEWER = stakingViewer_;
    }

    //
    // Typed feed surface (permissionless, msg.sender-keyed)
    //

    /// @notice Track `tokenId` for the caller (idempotent). **Reverts** `CoordinateNotOwned` if not owned by the caller,
    ///         `CoordinateCacheFull` past {MAX_TOKEN_IDS}.
    function submit(uint256 tokenId) external {
        _submitCoord(abi.encode(tokenId));
    }

    /// @notice Stop tracking `tokenId` for the caller. **Reverts** `CoordinateNotCached` if not tracked, and
    ///         `CoordinateStillLive` if the position is still live (owned with active/expired stake or rewards) — a
    ///         still-live id is never silently dropped (see {_removable}).
    function remove(uint256 tokenId) external {
        _removeCoord(abi.encode(tokenId));
    }

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory ids) {
        bytes[] memory coords = _cachedCoords(account);
        ids = new uint256[](coords.length);
        for (uint256 i; i < coords.length; ++i) {
            ids[i] = abi.decode(coords[i], (uint256));
        }
    }

    /// @inheritdoc IPositionDescribable
    function protocolName() external pure returns (string memory) {
        return "Nexus Mutual";
    }

    /// @inheritdoc IPositionDescribable
    /// @dev `["Staking Pools", "Pool #<poolId>"]` — the numeric pool id read live via `getPoolId()`. Falls back to the
    ///      pool address when that read does not answer with a word. Empty for a malformed positionId.
    ///
    ///      **What the guards below do and do not promise.** They reject any positionId that is not exactly one clean
    ///      address word, so no foreign coordinate can be truncated or padded into a `Pool #` breadcrumb. They do NOT
    ///      establish that a rendered breadcrumb names a pool this adapter tracks: a CLEAN address that simply is not
    ///      a Nexus pool still renders `["Staking Pools", "0x…"]` through the hex fallback. That is unavoidable here —
    ///      Nexus pools are discovered per ACCOUNT from the cached NFT ids, so there is no account-independent set to
    ///      check a positionId against, and {IPositionDescribable} defines labels as a pure function of `positionId`.
    ///      The fallback is kept because it is the useful answer for the case it exists for: a real pool whose
    ///      `getPoolId()` read fails, where the address is what an operator needs. Callers that must know whether a
    ///      coordinate is actually tracked ask {tokenIdsOf}, not this view.
    function positionLabels(bytes calldata positionId) external view override returns (string[] memory out) {
        // Exactly one word. Every positionId this adapter emits is `abi.encode(poolAddress)`; a shorter buffer would
        // revert inside `abi.decode`, and a LONGER one would decode its first word and label a multi-word coordinate
        // belonging to some other adapter as a Nexus pool. Both are foreign, so both take the same `[]` exit.
        if (positionId.length != 32) return new string[](0);
        // Decode as a raw word, not `abi.decode(positionId, (address))`: Solidity's decoder REVERTS on an address
        // whose upper 96 bits are dirty, which would turn a foreign positionId into a revert of a view that must
        // never revert. A dirty word takes the same `[]` exit — it is not masked down to its low 160 bits, which
        // would render a `Pool #` breadcrumb for a coordinate this adapter never emitted.
        uint256 raw = abi.decode(positionId, (uint256));
        if (raw >> 160 != 0) return new string[](0);
        address pool = address(uint160(raw));
        out = new string[](2);
        out[0] = "Staking Pools";
        // Bounded probe, not a raw `pool.staticcall`. This view is reachable with an ARBITRARY clean address, and the
        // unbounded form forwarded all gas and `returndatacopy`d the whole reply into `bytes memory`: measured at
        // 1.04e9 gas against a looping `getPoolId()` and 6.2e7 against one returning 4 MB. It failed open in both
        // cases but starved the frame — an out-of-gas in the very view that must never revert. {probeWord} caps the
        // stipend at `PROBE_GAS` and copies at most one word. Its `hasWord` is the exact equivalent of the previous
        // `ok && data.length >= 32` (and already folds in `ok`), so a pool id of 0 still counts as answered.
        (, bool hasWord, uint256 poolId) =
            StaticCallLib.probeWord(pool, abi.encodeWithSelector(INexusMutualStakingPool.getPoolId.selector));
        out[1] = hasWord ? string.concat("Pool #", poolId.toString()) : Strings.toHexString(pool);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IPositionDescribable).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Hooks
    //

    /// @inheritdoc AssistedCoordCache
    function _maxCoords() internal pure override returns (uint256) {
        return MAX_TOKEN_IDS;
    }

    /// @inheritdoc AssistedCoordCache
    function _maxLegsPerCoord() internal pure override returns (uint256) {
        return 2;
    }

    /// @inheritdoc AssistedCoordCache
    function _coordId(bytes memory coord) internal pure override returns (uint256) {
        return abi.decode(coord, (uint256));
    }

    /// @inheritdoc AssistedCoordCache
    function _validateCoord(address account, bytes memory coord) internal view override {
        uint256 tokenId = abi.decode(coord, (uint256));
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) revert CoordinateNotOwned(account, tokenId);
    }

    /// @inheritdoc AssistedCoordCache
    /// @dev Nexus does not burn the StakingNFT on withdraw, so "no longer owned" is not a reliable liveness proxy.
    ///      Removable iff the position no longer resolves to a live amount for `account`: either the id is no longer
    ///      owned by `account`, or it is owned but fully emptied (no active/expired stake and no rewards). A still-live
    ///      (partial/rewards-only) position is NOT removable, so a later partial withdraw can never silently drop it —
    ///      matching the family "under-report only" invariant. On an unresolvable `getTokens` read, err toward keeping
    ///      the id (return false) so a maybe-live position is never dropped.
    function _removable(address account, bytes memory coord) internal view override returns (bool) {
        uint256 tokenId = abi.decode(coord, (uint256));
        (address owner, bool ok) = _ownerOf(tokenId);
        if (!ok || owner != account) return true; // transferred / burned away → safe to drop
        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        try INexusStakingViewer(STAKING_VIEWER).getTokens(one) returns (INexusStakingViewer.Token[] memory tokens) {
            if (tokens.length == 0) return true;
            return tokens[0].activeStake + tokens[0].expiredStake + tokens[0].rewards == 0;
        } catch {
            return false; // cannot confirm the position is dead → keep tracking it
        }
    }

    /// @inheritdoc AssistedCoordCache
    /// @notice Values one cached `tokenId` into its (up to 2) legs: `Staking` (active + expired) + `Rewards`, NXM-
    ///         denominated. Empty if not owned by `account`, no stake/rewards, or the pool can't be resolved. Reached
    ///         via the self-`staticcall`, so it may revert freely (`getTokens` reverts are isolated).
    function _valueCoord(address account, bytes memory coord, INAVCalculator.Asset memory underlying)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        uint256 tokenId = abi.decode(coord, (uint256));
        INAVCalculator.PositionBalance[] memory none = new INAVCalculator.PositionBalance[](0);

        (, address owner) = INexusStakingNFT(STAKING_NFT).tokenInfo(tokenId);
        if (owner != account) return none;

        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        INexusStakingViewer.Token[] memory tokens = INexusStakingViewer(STAKING_VIEWER).getTokens(one);
        if (tokens.length == 0) return none;

        uint256 staking = tokens[0].activeStake + tokens[0].expiredStake;
        uint256 rewards = tokens[0].rewards;
        if (staking == 0 && rewards == 0) return none;

        address pool = INexusStakingViewer(STAKING_VIEWER).stakingPool(tokens[0].poolId);
        if (pool == address(0)) return none;
        bytes memory positionId = abi.encode(pool);
        bytes32 instanceId = bytes32(tokenId);

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](2);
        uint256 n;
        if (staking > 0) tmp[n++] = _leg(underlying, staking, PositionKind.Staking, positionId, instanceId);
        if (rewards > 0) tmp[n++] = _leg(underlying, rewards, PositionKind.Rewards, positionId, instanceId);

        INAVCalculator.PositionBalance[] memory outLegs = new INAVCalculator.PositionBalance[](n);
        for (uint256 k; k < n; ++k) {
            outLegs[k] = tmp[k];
        }
        return outLegs;
    }

    /// @dev Ownership read wrapping `tokenInfo` so a non-existent / burned id returns `(0, false)`.
    function _ownerOf(uint256 tokenId) internal view returns (address owner, bool ok) {
        try INexusStakingNFT(STAKING_NFT).tokenInfo(tokenId) returns (uint256, address o) {
            return (o, true);
        } catch {
            return (address(0), false);
        }
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

/// @notice Minimal interface for a Nexus Mutual StakingPool — its numeric pool id, for the display label.
interface INexusMutualStakingPool {
    function getPoolId() external view returns (uint256);
}
