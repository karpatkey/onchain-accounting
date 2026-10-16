// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// Mocks for the vfat Sickle-held adapter family: the forward `owner → sickle` factory map and the Sickle's own
// reverse `owner()` attestation, plus the hostile variants {SickleHeldPositions} is required to reject.

/// @notice Minimal vfat SickleFactory — the forward map only (that is all the balance layer reads).
contract MockSickleFactory {
    mapping(address => address) internal _sickles;
    bool internal _reverts;

    function setSickle(address owner, address sickle) external {
        _sickles[owner] = sickle;
    }

    /// @notice Make `sickles()` revert, simulating a factory that does not answer (the fail-open path).
    function setReverts(bool reverts) external {
        _reverts = reverts;
    }

    function sickles(address owner) external view returns (address) {
        require(!_reverts, "factory down");
        return _sickles[owner];
    }
}

/// @notice Minimal vfat Sickle — holds positions and attests to its owner. Constructing one with an owner other
///         than the account the factory filed it under is the "factory entry fails the reverse check" case.
contract MockSickle {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Repoint the attestation after deployment (lets a test file a Sickle under itself).
    function setOwner(address owner_) external {
        owner = owner_;
    }
}

/// @notice A Sickle whose `owner()` reverts: no reverse attestation, so it must never be admitted.
contract MockRevertingOwnerSickle {
    function owner() external pure returns (address) {
        revert("no owner");
    }
}

/// @notice A factory whose `sickles()` answers with a full word whose upper 96 bits are dirty — not an address.
/// @dev The typed mock structurally cannot produce this (it declares a real `address`), so the malformed branch
///      needs a hand-rolled return. Masking instead of rejecting would admit a holder nobody attested to.
contract MockDirtyWordFactory {
    bytes32 public word;

    constructor(address sickle) {
        word = bytes32(uint256(uint160(sickle)) | (uint256(1) << 255));
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(word);
    }
}

/// @notice A Sickle whose `owner()` answers with a dirty word rather than an address.
contract MockDirtyOwnerSickle {
    bytes32 public word;

    constructor(address owner_) {
        word = bytes32(uint256(uint160(owner_)) | (uint256(1) << 255));
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(word);
    }
}

/// @notice A Sickle whose `owner()` returns the zero address (no attestation at all).
contract MockZeroOwnerSickle {
    function owner() external pure returns (address) {
        return address(0);
    }
}
