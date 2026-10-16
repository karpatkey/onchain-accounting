// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";

/// @notice A Fables range's pooled accounting, `LedgerTypes.RangeState` field for field.
/// @author KPK
/// @dev Shares are ERC-6909 and are minted 1:1 against the Uniswap V4 liquidity a deposit adds, so
///      `totalShares` IS the hook's V4 position liquidity. MEASURED on chain 4663 at block 71,453,253,
///      24 Sep 2026: 1,915 live ranges across all seven deployed hooks, zero mismatches against
///      PoolManager's own position storage. That is why `balanceOf(holder, rangeId)` can be fed to
///      `LiquidityAmounts` unscaled, with no share price and no conversion factor anywhere.
///
///      `accFee*X128` is fee per UNSTAKED share; `accStaked*X128` is fee per STAKED share, which is an
///      emission weight rather than a token claim. `stakedResidual*` is the sub-unit remainder the staked
///      cut carries between syncs, held as a fraction of one fee unit in Q128.
struct FablesRangeState {
    uint128 totalShares;
    uint128 totalStaked;
    uint256 accFee0X128;
    uint256 accFee1X128;
    uint256 accStaked0X128;
    uint256 accStaked1X128;
    uint128 stakedResidual0;
    uint128 stakedResidual1;
    uint64 collectionSeq;
    uint64 resetSeq;
}

/// @notice One holder's slice of a range, `LedgerTypes.UserPosition` field for field.
/// @author KPK
/// @dev `owed0`/`owed1` are ALREADY NET of both the staked cut and the claim fee: both are taken at accrual
///      in the hook's `LedgerLib._split`, and `claimFees` takes nothing further ("No cut here: it was
///      already taken at accrual" — the hook's own comment at `FablesLedger.sol:524`). Discounting them a
///      second time in a valuer would under-report.
///
///      `forgone0`/`forgone1` are fees staked shares gave up. They are an offchain emission claim, never a
///      token balance, and are deliberately absent from this family's output.
struct FablesUserPosition {
    uint128 staked;
    uint128 owed0;
    uint128 owed1;
    uint256 checkpoint0X128;
    uint256 checkpoint1X128;
    uint256 stakedCheckpoint0X128;
    uint256 stakedCheckpoint1X128;
    uint256 forgone0;
    uint256 forgone1;
}

/// @notice The slice of a Fables hook that a NAV valuer reads. Every function here is `view`.
/// @author KPK
///
/// @dev **NOT ONE ABI, AND THAT IS WHY THIS INTERFACE IS NARROW.** Seven Fables hooks are deployed on chain
///      4663 and they do not share a surface. MEASURED 24 Sep 2026: `claimFeeBps()` answers as a no-arg
///      getter on six of them and REVERTS on `0x5eb87f69be00df39981622fd60a8de4b7837e080`, which declares
///      `claimFeeBps(bytes32)` instead — and that hook alone hosts four of the ten candidate pools. Since
///      `PriceFeedLib._getAdapterPositions` reads an adapter revert as "nothing to report", calling the wrong
///      shape would price four pools at ZERO with no error anywhere. This interface therefore deliberately
///      EXCLUDES `claimFeeBps` in both shapes and names only what all seven hooks answer identically:
///      `rangeId`, `rangeKey`, `rangeState`, `userPosition`, `balanceOf`, `effectiveClaimFee(uint256)`,
///      `claimFeeRecipient`, `poolManager`, `paused`.
interface IFablesHook {
    /// @notice `uint256(keccak256(abi.encode(poolId, tickLower, tickUpper)))`. Public and pure.
    function rangeId(bytes32 poolId, int24 tickLower, int24 tickUpper) external pure returns (uint256);

    /// @notice The stored preimage of a `rangeId`: which pool, which ticks.
    /// @dev `set` is false for an id never deposited into. The hook being its own preimage oracle is what lets
    ///      a valuer check a permissionlessly-filed range against a GOVERNED instance without trusting the
    ///      filer: see the three authority checks in `FablesSickleRangesMetaBalanceAdapter._legs`.
    function rangeKey(uint256 id) external view returns (PoolKey memory key, int24 tickLower, int24 tickUpper, bool set);

    function rangeState(uint256 id) external view returns (FablesRangeState memory);

    function userPosition(uint256 id, address owner) external view returns (FablesUserPosition memory);

    /// @notice ERC-6909 balance. One share is one unit of Uniswap V4 liquidity (see {FablesRangeState}).
    function balanceOf(address owner, uint256 id) external view returns (uint256);

    /// @notice The claim-fee rate a backlog opened at this range's sync index would be charged, in bps.
    /// @dev PER RANGE, not global: the lowest rate standing since that range's own `claimFeeSyncIndex`, capped
    ///      by the live policy. An untouched range reads 0 because the all-time minimum is 0; a range the fund
    ///      has deposited into reads the live rate.
    function effectiveClaimFee(uint256 id) external view returns (uint16);

    /// @notice Where the claim fee goes. `address(0)` means no claim fee is taken at all.
    function claimFeeRecipient() external view returns (address);

    /// @notice The Uniswap V4 PoolManager singleton this hook settles against.
    /// @dev Declared for completeness and for offchain probes; the adapter never calls it. See the
    ///      `POOL_MANAGER` immutable's docs for why reading it off a permissionlessly-supplied hook would be
    ///      asking an attacker where to look.
    function poolManager() external view returns (address);

    /// @notice Whether the hook is paused.
    /// @dev Advisory for a valuer, deliberately NOT a haircut. `withdraw` and `unstake` carry no pause check,
    ///      so principal is always exitable; `claimFees` and `transfer` do, so accrued fees are real but
    ///      temporarily unrealisable while paused. MEASURED 24 Sep 2026 at block 71,453,253: all seven hooks
    ///      read `paused == false`.
    function paused() external view returns (bool);
}
