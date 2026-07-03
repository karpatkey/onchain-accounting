// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";

/// @title ISafeMinimal
/// @notice Minimal subset of the Safe interface used by the fork tests in this repository.
/// @dev Intentionally excludes most Safe functionality — only owner/signature/exec paths.
interface ISafeMinimal {
    /// @notice Safe operation kind.
    enum Operation {
        Call,
        DelegateCall
    }

    /// @notice Returns the current Safe owner set.
    function getOwners() external view returns (address[] memory);
    /// @notice Returns the current Safe signature threshold.
    function getThreshold() external view returns (uint256);

    /// @notice Verifies signatures for a Safe transaction hash.
    function checkSignatures(bytes32 dataHash, bytes memory data, bytes memory signatures) external view;

    /// @notice Executes a Safe transaction.
    /// @return success True when execution succeeds according to Safe internals.
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @title SafeOverrides
/// @notice Fork-test helper that patches Safe storage directly to enforce a deterministic single-owner setup, so tests
///         can sign for a production Safe without its private keys. Ported from karpatkey/flash-leverage's
///         `test/utils/SafeOverrides.sol`.
/// @dev Test-only; relies on Foundry cheatcodes (`vm.load`, `vm.store`). Never use in production logic.
abstract contract SafeOverrides is Test {
    /// @notice Sentinel owner pointer used by Safe's linked-list owner storage.
    address internal constant _SENTINEL_OWNERS = address(0x1);

    /// @notice Computes the storage slot for `owners[key]` in Safe's owner linked-list mapping.
    function _ownersLoc(uint256 ownersMappingSlot, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, ownersMappingSlot));
    }

    /// @notice Finds the Safe owners mapping slot by probing storage for `owners[SENTINEL] == firstOwner`.
    function _findOwnersMappingSlot(address safe, address firstOwner) internal view returns (uint256) {
        for (uint256 slot = 0; slot < 64; slot++) {
            bytes32 word = vm.load(safe, _ownersLoc(slot, _SENTINEL_OWNERS));
            if (address(uint160(uint256(word))) == firstOwner) {
                return slot;
            }
        }
        revert("OwnersMappingSlotNotFound");
    }

    /// @notice Finds owner-count and threshold storage slots by an adjacency pattern:
    ///         `slot(threshold) == threshold AND slot(threshold-1) == ownersLen`.
    function _findThresholdAndOwnerCountSlots(address safe, uint256 ownersLen, uint256 threshold)
        internal
        view
        returns (uint256 ownerCountSlot, uint256 thresholdSlot)
    {
        for (uint256 i = 1; i < 64; i++) {
            if (uint256(vm.load(safe, bytes32(i))) == threshold) {
                if (uint256(vm.load(safe, bytes32(i - 1))) == ownersLen) {
                    return (i - 1, i);
                }
            }
        }
        revert("ThresholdSlotNotFound");
    }

    /// @notice Rewrites a Safe's owner linked-list and threshold storage to a single-owner (threshold 1) configuration.
    /// @dev If `newOwner == address(0)`, falls back to `msg.sender`. Clears prior owner pointers.
    function patchThresholdAndMakeSingleOwner(address safe, address newOwner) public {
        if (newOwner == address(0)) newOwner = msg.sender;

        address[] memory ownersBefore = ISafeMinimal(safe).getOwners();
        uint256 thresholdBefore = ISafeMinimal(safe).getThreshold();

        uint256 ownersMappingSlot = _findOwnersMappingSlot(safe, ownersBefore[0]);
        (uint256 ownerCountSlot, uint256 thresholdSlot) =
            _findThresholdAndOwnerCountSlots(safe, ownersBefore.length, thresholdBefore);

        // owners[SENTINEL] = newOwner ; owners[newOwner] = SENTINEL
        vm.store(safe, _ownersLoc(ownersMappingSlot, _SENTINEL_OWNERS), bytes32(uint256(uint160(newOwner))));
        vm.store(safe, _ownersLoc(ownersMappingSlot, newOwner), bytes32(uint256(uint160(_SENTINEL_OWNERS))));

        // Clear old pointers (avoids cyclic linked-list residue if something still reads them).
        for (uint256 i = 0; i < ownersBefore.length; i++) {
            address oldOwner = ownersBefore[i];
            if (oldOwner != newOwner && oldOwner != _SENTINEL_OWNERS) {
                vm.store(safe, _ownersLoc(ownersMappingSlot, oldOwner), bytes32(0));
            }
        }

        // ownerCount = 1 ; threshold = 1
        vm.store(safe, bytes32(ownerCountSlot), bytes32(uint256(1)));
        vm.store(safe, bytes32(thresholdSlot), bytes32(uint256(1)));
    }

    /// @notice Builds a prevalidated Safe signature blob for a single owner (`r = owner`, `s = 0`, `v = 1`).
    /// @dev Valid only when the `execTransaction` submitter (`msg.sender`) equals `owner`.
    function buildPrevalidatedSignature(address owner) public pure returns (bytes memory sig) {
        sig = new bytes(65);
        assembly {
            let o := and(owner, 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(add(sig, 0x20), o) // r
            mstore(add(sig, 0x40), 0) // s
            mstore8(add(sig, 0x60), 1) // v
        }
    }
}
