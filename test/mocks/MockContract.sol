// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title MockContract
/// @notice Minimal contract used to satisfy "must be a contract" constructor checks in unit tests.
/// @dev Has no logic; only exists so that extcode size > 0 at the deployed address.
contract MockContract {
    function stub() external pure returns (bool) {
        return true;
    }
}
