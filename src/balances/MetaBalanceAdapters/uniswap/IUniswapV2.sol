// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal Uniswap V2 pair interface (shared by the Uniswap V2 / PancakeSwap V2 read paths).
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function kLast() external view returns (uint256);
}

/// @notice Minimal Uniswap V2 factory interface.
interface IUniswapV2Factory {
    function feeTo() external view returns (address);
}
