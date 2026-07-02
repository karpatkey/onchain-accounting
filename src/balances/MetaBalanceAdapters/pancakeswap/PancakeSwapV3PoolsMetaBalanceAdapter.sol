// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {
    UniswapV3PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal PancakeSwap V3 pool interface — identical to Uniswap V3's except `slot0().feeProtocol` is
///         `uint32` (Uniswap V3 packs it as `uint8`). Only `slot0` is needed here; every other read
///         (`token0`/`token1`/`fee`/`ticks`/`feeGrowthGlobal`/NPM `positions`) is byte-compatible and reused from
///         the Uniswap V3 base via `UniswapV3PoolLib`.
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

/// @title PancakeSwap V3 Pools Meta Balance Adapter
/// @author KPK
/// @notice PancakeSwap V3 is a byte-compatible Uniswap V3 fork, so this is a thin subclass of
///         {UniswapV3PoolsMetaBalanceAdapter}: it overrides only the protocol identity slugs and the `_slot0` read
///         (PancakeSwap V3's `feeProtocol` is `uint32`, so the full-tuple decode differs — decoding it into
///         Uniswap's `uint8` would revert on dirty high bits). All discovery/valuation/label logic is inherited.
/// @dev Licensing: inherits the GPL-2.0-or-later Uniswap math via the base — combined work is GPL-2.0-or-later
///      (docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md).
contract PancakeSwapV3PoolsMetaBalanceAdapter is UniswapV3PoolsMetaBalanceAdapter {
    /// @param positionManager_ The PancakeSwap V3 NonfungiblePositionManager (per-chain canonical NPM).
    /// @param protocolName_    Human-readable protocol name (e.g. "PancakeSwap V3").
    /// @param navCalculator_   The NAVCalculator contract for asset-registry access.
    constructor(address positionManager_, string memory protocolName_, address navCalculator_)
        UniswapV3PoolsMetaBalanceAdapter(positionManager_, protocolName_, navCalculator_)
    {}

    /// @inheritdoc UniswapV3PoolsMetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP;
    }

    /// @inheritdoc UniswapV3PoolsMetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V3;
    }

    /// @inheritdoc UniswapV3PoolsMetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V3;
    }

    /// @inheritdoc UniswapV3PoolsMetaBalanceAdapter
    /// @dev Decodes PancakeSwap V3's `uint32 feeProtocol` slot0 ABI (vs Uniswap V3's `uint8`).
    function _slot0(address pool) internal view override returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IPancakeV3Pool(pool).slot0();
    }
}
