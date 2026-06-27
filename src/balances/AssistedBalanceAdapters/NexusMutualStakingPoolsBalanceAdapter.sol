// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
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
///         (`abi.encode(StakingViewer.stakingPool(poolId))`); the NFT id is surfaced as the last display **label**
///         (`["Staking", "<pool>", "NFT #<id>"]`), not in positionId.
/// @dev Access control comes from {AssistedBalanceAdapter}: `DEFAULT_ADMIN_ROLE` administers roles and
///      `ASSISTANT_ROLE` gates the submit/clear mutators. `submitTokenIds` **reverts** `NotTokenOwner` for any id
///      whose `tokenInfo` owner is not the account (fail-loud writes); reads instead **discard** an id no longer
///      owned (fail-open). See `docs/decisions/0015-assisted-balance-adapter-family.md` (Merkl precedent, ADR 0007).
///      The no-arg balance getters (`getAdapterBalances`/`getAdapterBalanceForAsset`) return the summed NXM total
///      across the account's owned, cached positions.
contract NexusMutualStakingPoolsBalanceAdapter is AssistedBalanceAdapter, IPositionDescribable {
    using Strings for uint256;

    //
    // Constants
    //

    bytes32 private constant PROTOCOL_ID = ProtocolIds.NEXUS_MUTUAL_STAKING;

    /// @notice Hard cap on cached tokenIds per account. The read path iterates the cache (one `tokenInfo` per id) and
    ///         hands the survivors to `getTokens`/`getAggregatedTokens`, which iterate each token's tranches — an
    ///         unbounded set could OOG inside the viewer (NOT caught by NAVCalculator's try/catch). 64 is generous
    ///         headroom over a real account (the OIV Safes hold a handful); the assistant must GC closed positions.
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

    /// @notice Candidate StakingNFT tokenIds cached per account (the only thing the assistant supplies).
    mapping(address account => uint256[] tokenIds) private _tokenIds;

    /// @dev `idxPlus1` = index of `tokenId` in `_tokenIds[account]` plus 1. Zero ⇒ not present (dedup + O(1) removal).
    mapping(address account => mapping(uint256 tokenId => uint256)) private _tokenIdIdxPlus1;

    //
    // Events
    //

    event TokenIdSubmitted(address indexed account, uint256 indexed tokenId);
    event TokenIdCleared(address indexed account, uint256 indexed tokenId);
    event AccountCleared(address indexed account);

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
    ) AssistedBalanceAdapter(admin_, assistant_) {
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
    // Mutators (onlyRole(ASSISTANT_ROLE))
    //

    /// @notice Add candidate StakingNFT tokenIds for `account`. Idempotent (dedup). **Reverts** `NotTokenOwner` if any
    ///         id's `tokenInfo` owner is not `account` — writes are fail-loud. Correctness does not depend on it
    ///         (reads re-verify ownership), but a non-owned id is a caller mistake.
    function submitTokenIds(address account, uint256[] calldata tokenIds) external onlyRole(ASSISTANT_ROLE) {
        if (account == address(0)) revert InvalidArguments();
        for (uint256 i; i < tokenIds.length; ++i) {
            _addTokenId(account, tokenIds[i]);
        }
    }

    /// @notice Batch variant across accounts. `accounts` and `tokenIds` must have the same length.
    function submitTokenIdsBatch(address[] calldata accounts, uint256[][] calldata tokenIds)
        external
        onlyRole(ASSISTANT_ROLE)
    {
        if (accounts.length != tokenIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert InvalidArguments();
            for (uint256 j; j < tokenIds[i].length; ++j) {
                _addTokenId(accounts[i], tokenIds[i][j]);
            }
        }
    }

    /// @notice Drop a cached tokenId. Idempotent. GC for withdrawn/transferred positions (stale ids already read as 0).
    function clearTokenId(address account, uint256 tokenId) external onlyRole(ASSISTANT_ROLE) {
        if (_tokenIdIdxPlus1[account][tokenId] == 0) return;
        _removeTokenId(account, tokenId);
        emit TokenIdCleared(account, tokenId);
    }

    /// @notice Drop all cached tokenIds for `account`.
    function clearAccount(address account) external onlyRole(ASSISTANT_ROLE) {
        uint256[] storage ids = _tokenIds[account];
        for (uint256 i; i < ids.length; ++i) {
            delete _tokenIdIdxPlus1[account][ids[i]];
        }
        delete _tokenIds[account];
        emit AccountCleared(account);
    }

    //
    // Reads (view, anyone)
    //

    /// @notice Candidate tokenIds currently cached for `account` (display/debug; not ownership-filtered).
    function tokenIdsOf(address account) external view returns (uint256[] memory) {
        return _tokenIds[account];
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

    /// @inheritdoc IPositionDescribable
    /// @dev Fallback only — the per-leg labels (including the NFT id) are supplied on each `PositionBalance.labels`
    ///      and consumed directly by the verbose reads. `positionId` is `abi.encode(pool)`, which carries no tokenId,
    ///      so this fallback returns `["Staking", "<pool address>"]` (no NFT id). Fail-open on a malformed id.
    function positionLabels(bytes calldata pid) external pure returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address pool = abi.decode(pid, (address));
        string[] memory out = new string[](2);
        out[0] = "Staking";
        out[1] = Strings.toHexString(pool);
        return out;
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
    ///         keyed by `positionId == abi.encode(stakingPoolAddress)` (NFT id in the labels). Zero legs are dropped;
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

        // Cheap path first: build the owned-id survivor list and bail before the (non-trivial) registry read when
        // the account has no live positions.
        uint256[] memory ids = _ownedCachedIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

        // NXM must be registered in NAVCalculator for the position to count in NAV. Resolve its Asset record first.
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        INAVCalculator.Asset memory underlying;
        bool registered;
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == UNDERLYING_TOKEN) {
                underlying = reg[i];
                registered = true;
                break;
            }
        }
        if (!registered) return new INAVCalculator.PositionBalance[](0);

        INexusStakingViewer.Token[] memory tokens;
        try INexusStakingViewer(STAKING_VIEWER).getTokens(ids) returns (INexusStakingViewer.Token[] memory t) {
            tokens = t;
        } catch {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Up to two legs (Staking + Rewards) per owned tokenId.
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2 * tokens.length);
        uint256 count;
        for (uint256 i; i < tokens.length; ++i) {
            // Active and expired stake are both staked NXM principal (expired tranches are no longer earning but
            // remain withdrawable); rewards are accrued NXM.
            uint256 staking = tokens[i].activeStake + tokens[i].expiredStake;
            uint256 rewards = tokens[i].rewards;
            if (staking == 0 && rewards == 0) continue;
            // positionId = the staking-pool contract address (deterministic per poolId). Skip the token if the pool
            // can't be resolved (under-report). The tokenId is NOT in positionId; it rides in the display labels.
            address pool;
            try INexusStakingViewer(STAKING_VIEWER).stakingPool(tokens[i].poolId) returns (address p) {
                pool = p;
            } catch {
                continue;
            }
            if (pool == address(0)) continue;
            bytes memory positionId = abi.encode(pool);
            string[] memory labels = _labels(pool, tokens[i].tokenId);
            if (staking > 0) temp[count++] = _leg(underlying, staking, PositionKind.Staking, positionId, labels);
            if (rewards > 0) temp[count++] = _leg(underlying, rewards, PositionKind.Rewards, positionId, labels);
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; i++) {
            positions[i] = temp[i];
        }
    }

    //
    // Internal — write
    //

    function _addTokenId(address account, uint256 tokenId) internal {
        if (_tokenIdIdxPlus1[account][tokenId] != 0) return; // already cached
        // Cap the cache so the per-account read loop stays gas-bounded (OOG there isn't caught by NAV). The assistant
        // must GC closed positions to make room; a real account never approaches MAX_TOKEN_IDS positions.
        if (_tokenIds[account].length >= MAX_TOKEN_IDS) return;
        // Fail-loud ownership check: a non-owned id is a caller mistake. `tokenInfo` reverts for a non-existent id;
        // surface that as NotTokenOwner too.
        try INexusStakingNFT(STAKING_NFT).tokenInfo(tokenId) returns (uint256, address owner) {
            if (owner != account) revert NotTokenOwner(account, tokenId);
        } catch {
            revert NotTokenOwner(account, tokenId);
        }
        _tokenIds[account].push(tokenId);
        _tokenIdIdxPlus1[account][tokenId] = _tokenIds[account].length;
        emit TokenIdSubmitted(account, tokenId);
    }

    function _removeTokenId(address account, uint256 tokenId) internal {
        uint256 idxPlus1 = _tokenIdIdxPlus1[account][tokenId];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        uint256[] storage list = _tokenIds[account];
        uint256 lastIdx = list.length - 1;
        if (idx != lastIdx) {
            uint256 lastId = list[lastIdx];
            list[idx] = lastId;
            _tokenIdIdxPlus1[account][lastId] = idx + 1;
        }
        list.pop();
        delete _tokenIdIdxPlus1[account][tokenId];
    }

    //
    // Internal — valuation
    //

    /// @dev The cached tokenIds still owned by `account`, re-verified live via `StakingNFT.tokenInfo`. Discards
    ///      (never reverts) ids that were withdrawn/transferred away — the assistant can only under-report.
    function _ownedCachedIds(address account) internal view returns (uint256[] memory ids) {
        uint256[] memory cached = _tokenIds[account];
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

    /// @dev `["Staking", "<pool address>", "NFT #<tokenId>"]` — the per-leg display hierarchy.
    function _labels(address pool, uint256 tokenId) private pure returns (string[] memory out) {
        out = new string[](3);
        out[0] = "Staking";
        out[1] = Strings.toHexString(pool);
        out[2] = string.concat("NFT #", tokenId.toString());
    }

    function _leg(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        PositionKind kind,
        bytes memory positionId,
        string[] memory labels
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: positionId,
            positionKind: kind,
            labels: labels
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
