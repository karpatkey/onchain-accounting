// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

import {UniswapV3PoolsBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title PancakeSwap V3 Pools Balance Adapter (id-cached, assisted)
/// @author KPK
/// @notice Assisted balance adapter for PancakeSwap V3 pools. PancakeSwap V3 is a Uniswap V3 fork sharing every view
///         this adapter reads. Historically the Uniswap base also read `slot0` (whose `feeProtocol` field PancakeSwap
///         declares as `uint32` vs Uniswap V3's `uint8`), so a subclass override was needed. Since [2], the adapter
///         no longer reads `slot0` at all — the price is reconstructed from the registered oracle feeds — so that
///         divergence is moot and this subclass differs from Uniswap V3 only in its protocol-id slug. All other
///         behaviour (assistant-fed tokenId cache, ownership-verified reads, principal/fee math, NAV filtering,
///         identity derivation) is inherited unchanged.
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
    ///      distinguishes PancakeSwap V3 LP from Uniswap V3 LP. Same positionId schema (address npm, uint256 tokenId).
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V3;
    }
}
