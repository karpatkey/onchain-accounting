// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsMetaBalanceAdapter.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title PancakeSwap V3 Pools Meta Balance Adapter
/// @author KPK
/// @notice Meta-adapter for PancakeSwap V3 pools. PancakeSwap V3 is a Uniswap V3 fork sharing every view this
///         adapter reads. Historically this subclass also overrode `_slot0` because PancakeSwap declares
///         `slot0().feeProtocol` as `uint32` (vs Uniswap V3's `uint8`) and Solidity 0.8's strict decoder rejects
///         the `uint8` read. Since [2], the adapter no longer reads `slot0` at all — the price is reconstructed
///         from the registered oracle feeds — so that divergence is moot and this subclass differs from Uniswap V3
///         only in its protocol-id slug. All other behaviour (NFT discovery, principal/fee math, NAV filtering,
///         identity derivation) is inherited unchanged.
contract PancakeSwapV3PoolsMetaBalanceAdapter is UniswapV3PoolsMetaBalanceAdapter {
    /// @param positionManager_ The PancakeSwap V3 NonfungiblePositionManager (canonical CREATE2 address).
    /// @param protocolName_ Human-readable protocol name (e.g. "PancakeSwap V3").
    /// @param navCalculator_ NAVCalculator contract address.
    constructor(address positionManager_, string memory protocolName_, address navCalculator_)
        UniswapV3PoolsMetaBalanceAdapter(positionManager_, protocolName_, navCalculator_)
    {}

    /// @inheritdoc UniswapV3PoolsMetaBalanceAdapter
    /// @dev Reports the `pancakeswap-v3` slug (vs the inherited `uniswap-v3`) so the typed reconciliation key
    ///      distinguishes PancakeSwap V3 LP from Uniswap V3 LP. Same positionId schema (address npm, uint256 tokenId).
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V3;
    }
}
