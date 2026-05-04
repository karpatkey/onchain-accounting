// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title FixedPoint128
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Adapted from Uniswap v3-core. Source:
///      https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/FixedPoint128.sol
///      Original pragma `>=0.4.0`. The constant is unchanged.
library FixedPoint128 {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}
