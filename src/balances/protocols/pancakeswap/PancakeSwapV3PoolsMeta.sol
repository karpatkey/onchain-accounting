// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV3PoolsMeta.sol";

/// @title PancakeSwap V3 Pools Meta Balance Adapter
/// @author kpk
/// @notice Meta-adapter for PancakeSwap V3 pools. PancakeSwap V3 is a Uniswap V3 fork sharing every relevant view
///         byte-for-byte; the single divergence is `slot0().feeProtocol`, which PancakeSwap declares as `uint32`
///         (vs Uniswap V3's `uint8`). Solidity 0.8's strict ABI decoder rejects a `uint8` read when the high bits
///         are set (the case on every active PCS V3 pool), so this contract inherits the Uniswap V3 pools
///         meta-adapter and overrides only the `_slot0` hook with a local `uint32 feeProtocol` interface. All
///         other behaviour (NFT discovery, principal/fee math, NAV filtering, identity derivation) is unchanged.
contract PancakeSwapV3PoolsMetaBalanceAdapter is UniswapV3PoolsMetaBalanceAdapter {
    /// @param positionManager_ The PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2 address).
    /// @param protocolName_ Human-readable protocol name (e.g. "PancakeSwap V3").
    /// @param navCalculator_ NAVCalculator contract address.
    constructor(address positionManager_, string memory protocolName_, address navCalculator_)
        UniswapV3PoolsMetaBalanceAdapter(positionManager_, protocolName_, navCalculator_)
    {}

    /// @inheritdoc UniswapV3PoolsMetaBalanceAdapter
    /// @dev Reads `slot0()` via a local `IPancakeV3Pool` declaration so the `uint32 feeProtocol` field decodes.
    function _slot0(address pool) internal view override returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IPancakeV3Pool(pool).slot0();
    }
}

/// @notice Minimal PancakeSwap V3 pool interface — identical to Uniswap V3's except `slot0().feeProtocol` is
///         `uint32` (see contract NatSpec for the rationale).
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
