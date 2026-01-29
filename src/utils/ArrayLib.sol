// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title Array Library
/// @notice Shared array operations for address arrays: slice/copy, deduplication, and intersection.
///         Used by NAVCalculator and balance oracles.
library ArrayLib {
    /// @notice Copies the first `count` elements of `src` into a new array of length `count`.
    /// @param src Source array (length must be >= count).
    /// @param count Number of elements to copy.
    /// @return dst New array of length count with elements src[0..count).
    function copySliceAddress(address[] memory src, uint256 count) internal pure returns (address[] memory dst) {
        dst = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            dst[i] = src[i];
        }
    }

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
        uint256 maxSize = array1.length < array2.length ? array1.length : array2.length;
        address[] memory temp = new address[](maxSize);
        uint256 count = 0;

        for (uint256 i = 0; i < array1.length; i++) {
            for (uint256 j = 0; j < array2.length; j++) {
                if (array1[i] == array2[j]) {
                    bool alreadyAdded = false;
                    for (uint256 k = 0; k < count; k++) {
                        if (temp[k] == array1[i]) {
                            alreadyAdded = true;
                            break;
                        }
                    }
                    if (!alreadyAdded) {
                        temp[count] = array1[i];
                        count++;
                    }
                    break; // Found match, move to next element in array1
                }
            }
        }

        result = copySliceAddress(temp, count);
    }

    /// @notice Deduplicates an address array (removes duplicate addresses)
    /// @param source Source array that may contain duplicates
    /// @return result Array with unique addresses only
    function deduplicateAddresses(address[] memory source) internal pure returns (address[] memory result) {
        if (source.length == 0) return source;

        address[] memory temp = new address[](source.length);
        uint256 count = 0;

        for (uint256 i = 0; i < source.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == source[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[count++] = source[i];
            }
        }

        result = copySliceAddress(temp, count);
    }
}
