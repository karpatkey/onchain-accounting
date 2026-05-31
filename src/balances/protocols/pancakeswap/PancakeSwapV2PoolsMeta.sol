// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UniswapV2PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV2PoolsMeta.sol";

/// @title PancakeSwap V2 Pools Meta Balance Adapter
/// @author kpk
/// @notice Meta-adapter for PancakeSwap V2 pairs. PancakeSwap V2 is a byte-for-byte Uniswap V2 fork (same
///         Pair/Factory ABI, same `_mintFee` formula), so this is a thin subclass of the Uniswap V2 pools
///         meta-adapter with no behavioural change — it exists for block-explorer visibility and dispatch
///         clarity, mirroring the per-instance `PancakeSwapV2BalanceOracle`. The protocol identifier (e.g.
///         "PancakeSwap V2") is set per deployment.
contract PancakeSwapV2PoolsMetaBalanceAdapter is UniswapV2PoolsMetaBalanceAdapter {
    /// @param protocol_ Protocol identifier (e.g. "PancakeSwap V2").
    /// @param navCalculator_ NAVCalculator contract address.
    constructor(string memory protocol_, address navCalculator_)
        UniswapV2PoolsMetaBalanceAdapter(protocol_, navCalculator_)
    {}
}
