// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UniswapV2PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV2PoolsMeta.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title PancakeSwap V2 Pools Meta Balance Adapter
/// @author kpk
/// @notice Meta-adapter for PancakeSwap V2 pairs. PancakeSwap V2 is a byte-for-byte Uniswap V2 fork (same
///         Pair/Factory ABI, same `_mintFee` formula), so this is a thin subclass of the Uniswap V2 pools
///         meta-adapter with no behavioural change — it exists for block-explorer visibility and dispatch
///         clarity, reporting the same positions. The protocol identifier (e.g.
///         "PancakeSwap V2") is set per deployment.
contract PancakeSwapV2PoolsMetaBalanceAdapter is UniswapV2PoolsMetaBalanceAdapter {
    /// @param protocolName_ Human-readable protocol name (e.g. "PancakeSwap V2").
    /// @param navCalculator_ NAVCalculator contract address.
    constructor(string memory protocolName_, address navCalculator_)
        UniswapV2PoolsMetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc UniswapV2PoolsMetaBalanceAdapter
    /// @dev Reports the `pancakeswap-v2` slug (vs the inherited `uniswap-v2`) so the typed reconciliation key
    ///      distinguishes PancakeSwap V2 LP from Uniswap V2 LP. Same positionId schema (address pair).
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V2;
    }
}
