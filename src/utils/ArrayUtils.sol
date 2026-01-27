// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Array Utilities
/// @notice Utility library for array operations
library ArrayUtils {
    /// @notice Finds addresses that are present in both input arrays (intersection).
    /// @dev Deduplicates: if array1 contains the same address multiple times, it appears only once in the result.
    /// @param array1 First array of addresses
    /// @param array2 Second array of addresses
    /// @return result Array of addresses that appear in both arrays (no duplicates)
    function intersection(address[] memory array1, address[] memory array2)
        internal
        pure
        returns (address[] memory result)
    {
        // Pre-allocate array (max size is the smaller of the two arrays)
        uint256 maxSize = array1.length < array2.length ? array1.length : array2.length;
        result = new address[](maxSize);
        uint256 count = 0;

        for (uint256 i = 0; i < array1.length; i++) {
            for (uint256 j = 0; j < array2.length; j++) {
                if (array1[i] == array2[j]) {
                    // Skip if already in result (array1 may contain duplicates, e.g. COMP as collateral + reward)
                    bool alreadyAdded = false;
                    for (uint256 k = 0; k < count; k++) {
                        if (result[k] == array1[i]) {
                            alreadyAdded = true;
                            break;
                        }
                    }
                    if (!alreadyAdded) {
                        result[count] = array1[i];
                        count++;
                    }
                    break; // Found match, move to next element in array1
                }
            }
        }

        // Copy to correctly-sized array so callers see the right length (mstore resize can be ignored by callers)
        address[] memory out = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = result[i];
        }
        return out;
    }
}
