// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Wraps a single balance adapter address into a one-element array for the batch
///         `NAVCalculator.addBalanceAdapters(address[])` API. Test ergonomics only.
function aa(address adapter) pure returns (address[] memory adapters) {
    adapters = new address[](1);
    adapters[0] = adapter;
}
