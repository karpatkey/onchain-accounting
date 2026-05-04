// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UniswapV3PoolBalanceOracle} from "src/balances/protocols/uniswap/UniswapV3Pool.sol";

/// @title PancakeSwap V3 Pool Balance Oracle
/// @author kpk
/// @notice PancakeSwap V3 is a Uniswap V3 fork that shares every relevant view (`token0`,
///         `token1`, `fee`, `tickSpacing`, `feeGrowthGlobal0/1X128`, `ticks(int24)`, and the
///         NonfungiblePositionManager `positions` struct) byte-for-byte with Uniswap V3.
///         The single divergence is `slot0().feeProtocol`, which PancakeSwap declares as
///         `uint32` rather than Uniswap V3's `uint8` (PCS packs per-token protocol-fee tiers
///         into 32 bits where Uniswap V3 packs both tiers into a single 8-bit field).
///         Solidity 0.8's strict ABI decoder rejects a `uint8` read whenever the high bits
///         of the 32-byte word are set, which is the case on every active PCS V3 pool.
///
///         Following the SparkLend ↔ Aave V3 pattern in this repo, this contract therefore
///         inherits from `UniswapV3PoolBalanceOracle` and only overrides the `_slot0()` hook
///         to use a local interface declaration with `uint32 feeProtocol`. All other behaviour
///         — NFT discovery, principal computation, fee accrual, NAV registry filtering — flows
///         through the parent unchanged.
contract PancakeSwapV3PoolBalanceOracle is UniswapV3PoolBalanceOracle {
    /// @param pool_ The PancakeSwap V3 pool address.
    /// @param positionManager_ The PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2
    ///        address — same on every chain PancakeSwap deploys to).
    /// @param protocol_ Protocol identifier (e.g. "PancakeSwap V3").
    /// @param positionDetail_ Position detail base (e.g. "WETH/COW 0.25%"). Liquidity entries
    ///        use this verbatim; fee entries append `" Fees"`.
    /// @param navCalculator_ NAVCalculator contract address.
    constructor(
        address pool_,
        address positionManager_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) UniswapV3PoolBalanceOracle(pool_, positionManager_, protocol_, positionDetail_, navCalculator_) {}

    /// @inheritdoc UniswapV3PoolBalanceOracle
    /// @dev Overrides the parent's `slot0()` read with a local `IPancakeV3Pool` declaration so
    ///      the `uint32 feeProtocol` field decodes correctly. We only need `(sqrtPriceX96, tick)`
    ///      for the math, so the wider `feeProtocol` is destructured out and discarded.
    function _slot0() internal view override returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IPancakeV3Pool(POOL).slot0();
    }
}

/// @notice Minimal PancakeSwap V3 pool interface — identical to the parent's `IUniswapV3Pool`
///         except `slot0().feeProtocol` is `uint32` (see contract NatSpec for the rationale).
interface IPancakeV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}
