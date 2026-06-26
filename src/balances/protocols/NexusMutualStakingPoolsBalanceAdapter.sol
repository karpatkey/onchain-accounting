// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Nexus Mutual Staking Pools Balance Adapter
/// @author kpk
/// @notice Reports an account's staked NXM across Nexus Mutual V2 staking pools, as NXM-denominated
///         `Staking` (active + expired stake) and `Rewards` legs — emitted **per StakingNFT position**.
///         Each stake is an ERC-721 `StakingNFT`; the NFT is not per-owner-enumerable and the
///         StakingViewer exposes no owner→tokenIds view. But `StakingNFT` is **mint-only** (no burn),
///         so its live tokenIds are exactly `1..totalSupply()` with a small, monotonic supply — this
///         adapter discovers an account's positions by scanning `tokenInfo(id)` over that range for a
///         matching owner, then values each via `StakingViewer.getTokens` (per-token active/expired
///         stake + rewards). One holder can have several positions, possibly across several pools; each
///         tokenId surfaces as its own leg(s), keyed by `positionId == abi.encode(tokenId, poolId)`.
/// @dev Immutable; no off-chain agent. The scan cost grows with Nexus's **global** StakingNFT supply
///      (not the account's position count). `MAX_TOKEN_SCAN` bounds it so the read loop can't OOG
///      (which NAVCalculator's try/catch would NOT catch). If the global supply ever approaches the
///      cap, high-id positions would be under-reported — never over-reported — and the protocol should
///      migrate to an agent-fed cache (the ADR-0014 pattern) before then. The no-arg balance getters
///      (`getAdapterBalances`/`getAdapterBalanceForAsset`) still return the summed NXM total.
contract NexusMutualStakingPoolsBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    //
    // Constants
    //

    bytes32 private constant PROTOCOL_ID = ProtocolIds.NEXUS_STAKING;

    /// @notice Upper bound on the StakingNFT id range scanned per read. StakingNFT has no burn, so
    ///         live ids are exactly `1..totalSupply` (~280 today); this is generous headroom plus a
    ///         hard gas bound on the scan loop.
    uint256 public constant MAX_TOKEN_SCAN = 5000;

    /// @notice Upper bound on positions collected per account. Besides sizing the working array, this
    ///         bounds the id count handed to `getAggregatedTokens` — which iterates each token's
    ///         tranches, so an unbounded set could OOG inside the viewer (NOT caught by NAVCalculator's
    ///         try/catch). 64 is generous headroom over a real account (the OIV Safes hold a handful);
    ///         a holder with more would have the excess under-reported (never over-reported).
    uint256 public constant MAX_POSITIONS_PER_ACCOUNT = 64;

    //
    // State
    //

    /// @notice Nexus Mutual StakingNFT (mint-only ERC-721; `tokenInfo(id) -> (poolId, owner)`).
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

    /// @param stakingNft_ Nexus StakingNFT. Must be a contract.
    /// @param stakingViewer_ Nexus StakingViewer. Must be a contract.
    /// @param underlyingToken_ NXM token address.
    /// @param navCalculator_ NAVCalculator. Must be a contract.
    constructor(address stakingNft_, address stakingViewer_, address underlyingToken_, address navCalculator_) {
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
    // Balance computation
    //

    /// @dev tokenIds owned by `account`, discovered by scanning `tokenInfo(1..min(totalSupply, cap))`.
    ///      Never reverts: a failed `totalSupply`/`tokenInfo` read degrades to fewer ids (the adapter
    ///      under-reports, never invents). Collection stops at `MAX_POSITIONS_PER_ACCOUNT`.
    function _ownedTokenIds(address account) internal view returns (uint256[] memory ids) {
        if (account == address(0)) return new uint256[](0);

        uint256 supply;
        try INexusStakingNFT(STAKING_NFT).totalSupply() returns (uint256 s) {
            supply = s;
        } catch {
            return new uint256[](0);
        }
        uint256 scanTo = supply < MAX_TOKEN_SCAN ? supply : MAX_TOKEN_SCAN;

        uint256[] memory found = new uint256[](MAX_POSITIONS_PER_ACCOUNT);
        uint256 n;
        // StakingNFT ids are 1-indexed and contiguous (mint-only).
        for (uint256 id = 1; id <= scanTo && n < MAX_POSITIONS_PER_ACCOUNT; ++id) {
            try INexusStakingNFT(STAKING_NFT).tokenInfo(id) returns (uint256, address owner) {
                if (owner == account) found[n++] = id;
            } catch {}
        }

        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = found[i];
        }
    }

    /// @dev Total NXM owed to `account` across its staking positions: stake (active + expired) and
    ///      rewards, valued in one `getAggregatedTokens` call. Never reverts (degrades to 0).
    function _stakeAndRewards(address account) internal view returns (uint256 staking, uint256 rewards) {
        uint256[] memory ids = _ownedTokenIds(account);
        if (ids.length == 0) return (0, 0);
        try INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids) returns (
            INexusStakingViewer.AggregatedTokens memory agg
        ) {
            // Active and expired stake are both the account's staked NXM principal (expired tranches
            // are no longer earning but remain withdrawable); rewards are accrued NXM.
            staking = agg.totalActiveStake + agg.totalExpiredStake;
            rewards = agg.totalRewards;
        } catch {
            return (0, 0);
        }
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
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "Nexus Mutual";
    }

    function describePosition(bytes calldata) external pure returns (string memory) {
        return "Staked NXM";
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
    /// @notice Per StakingNFT position: a `Staking` (active + expired stake) and a `Rewards` (accrued)
    ///         leg, each keyed by `positionId == abi.encode(tokenId, poolId)`. Zero legs are dropped;
    ///         empty if NXM is unregistered, filtered out, or the account holds no positions.
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

        // NXM must be registered in NAVCalculator for the position to count in NAV. Resolve its Asset
        // record first, and bail before the (bounded but non-trivial) StakingNFT scan when the asset is
        // unregistered — so an unregistered underlying costs a single registry read, not the full scan.
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

        uint256[] memory ids = _ownedTokenIds(account);
        if (ids.length == 0) return new INAVCalculator.PositionBalance[](0);

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
            // Active and expired stake are both staked NXM principal (expired tranches are no longer
            // earning but remain withdrawable); rewards are accrued NXM.
            uint256 staking = tokens[i].activeStake + tokens[i].expiredStake;
            uint256 rewards = tokens[i].rewards;
            if (staking == 0 && rewards == 0) continue;
            bytes memory positionId = abi.encode(tokens[i].tokenId, tokens[i].poolId);
            if (staking > 0) temp[count++] = _leg(underlying, staking, PositionKind.Staking, positionId);
            if (rewards > 0) temp[count++] = _leg(underlying, rewards, PositionKind.Rewards, positionId);
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; i++) {
            positions[i] = temp[i];
        }
    }

    function _leg(INAVCalculator.Asset memory asset, uint256 amount, PositionKind kind, bytes memory positionId)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: positionId,
            positionKind: kind
        });
    }
}

/// @notice Minimal interface for Nexus Mutual's StakingNFT (mint-only ERC-721).
interface INexusStakingNFT {
    /// @notice Total number of StakingNFTs minted; ids are 1..totalSupply (never burned).
    function totalSupply() external view returns (uint256);

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
}
