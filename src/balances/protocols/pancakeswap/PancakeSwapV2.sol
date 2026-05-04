// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UniswapV2BalanceOracle} from "src/balances/protocols/UniswapV2.sol";

/// @title PancakeSwap V2 Balance Oracle
/// @author kpk
/// @notice PancakeSwap V2 is a byte-for-byte Uniswap V2 fork: same `Pair`/`Factory` ABI, same
///         `_mintFee` formula, same `feeTo`/`kLast` accessors. This wrapper inherits all
///         behaviour from `UniswapV2BalanceOracle` and exists only to give PancakeSwap V2 its
///         own contract type — visible on Etherscan and in our deploy/dispatch tables — the
///         same way `SparkLendBalanceOracle` extends `AaveV3InstanceBalanceOracle` without
///         changing semantics.
contract PancakeSwapV2BalanceOracle is UniswapV2BalanceOracle {
    /// @param pair_ The PancakeSwap V2 pair contract address.
    /// @param protocol_ Protocol identifier (e.g. "PancakeSwap V2").
    /// @param positionDetail_ Position detail (e.g. "ETH/COW LP").
    /// @param navCalculator_ The NAVCalculator contract address.
    constructor(address pair_, string memory protocol_, string memory positionDetail_, address navCalculator_)
        UniswapV2BalanceOracle(pair_, protocol_, positionDetail_, navCalculator_)
    {}
}
