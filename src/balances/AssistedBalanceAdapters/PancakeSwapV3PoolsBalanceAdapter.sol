// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {UniswapV3PoolsBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal PancakeSwap V3 pool interface — identical to Uniswap V3's `slot0()` except `feeProtocol` is
///         `uint32` (Uniswap V3 packs it as `uint8`). The widened field is why the full-tuple decode needs a
///         PancakeSwap-specific ABI: decoding PancakeSwap's `uint32` value into a `uint8` reverts on the dirty
///         high bits (PCS V3 pools routinely have `feeProtocol > 255`).
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

/// @title PancakeSwap V3 Pools Balance Adapter (id-cached, assisted)
/// @author KPK
/// @notice Assisted balance adapter for PancakeSwap V3 pools. PancakeSwap V3 is a Uniswap V3 fork sharing every view
///         this adapter reads, so all behaviour (assistant-fed tokenId cache, ownership-verified reads, slot0-based
///         principal/fee math, NAV filtering, `abi.encode(pool)` identity) is inherited from
///         `UniswapV3PoolsBalanceAdapter`. It diverges in exactly two places: the protocol-id slug
///         (`pancakeswap-v3`), and the `_slot0` read — PancakeSwap V3's `slot0().feeProtocol` is `uint32` (not
///         `uint8`), so the inherited full-tuple decode would revert on the dirty high bits. See ADR 0017 for why
///         the V3 adapters read `slot0` (instantaneous on-chain amounts; manipulation mitigated by async settlement).
contract PancakeSwapV3PoolsBalanceAdapter is UniswapV3PoolsBalanceAdapter {
    /// @param positionManager_ The PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2 address).
    /// @param protocolName_    Human-readable protocol name (e.g. "PancakeSwap V3").
    /// @param navCalculator_   NAVCalculator contract address.
    /// @param admin_           Holder of `DEFAULT_ADMIN_ROLE` (administers `ASSISTANT_ROLE`). Required.
    /// @param assistant_       Initial holder of `ASSISTANT_ROLE` (optional; pass `address(0)` to grant later).
    constructor(
        address positionManager_,
        string memory protocolName_,
        address navCalculator_,
        address admin_,
        address assistant_
    ) UniswapV3PoolsBalanceAdapter(positionManager_, protocolName_, navCalculator_, admin_, assistant_) {}

    /// @inheritdoc UniswapV3PoolsBalanceAdapter
    /// @dev Reports the `pancakeswap-v3` slug (vs the inherited `uniswap-v3`) so the typed reconciliation key
    ///      distinguishes PancakeSwap V3 LP from Uniswap V3 LP. Same positionId schema as the base —
    ///      `abi.encode(pool)` (the pool address; NFT id in the display labels).
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V3;
    }

    /// @inheritdoc UniswapV3PoolsBalanceAdapter
    /// @dev Reports the `pancakeswap-v3` slug as the sub-id (ecosystem == sub for the V3 adapters), matching
    ///      `_protocolId`.
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V3;
    }

    /// @inheritdoc UniswapV3PoolsBalanceAdapter
    /// @dev Reports the `pancakeswap` brand (vs the inherited `uniswap`).
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP;
    }

    /// @inheritdoc UniswapV3PoolsBalanceAdapter
    /// @dev Reads `slot0` via the local `IPancakeV3Pool` ABI so the `uint32 feeProtocol` field decodes (the inherited
    ///      `uint8` decode would revert on PCS V3's high bits). Only `(sqrtPriceX96, tick)` are used.
    function _slot0(address pool) internal view override returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IPancakeV3Pool(pool).slot0();
    }
}
