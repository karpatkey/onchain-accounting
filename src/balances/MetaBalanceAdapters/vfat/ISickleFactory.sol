// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title ISickleFactory
/// @author KPK
/// @notice The two reads of vfat's `SickleFactory` that the balance layer needs: the forward `owner → sickle` map
///         and, on the Sickle itself, the reverse `sickle → owner` attestation used to check it.
/// @dev vfat's factory deploys ONE Sickle per owner (a minimal-proxy "smart wallet" that holds the owner's LP
///      positions) and records it in a public mapping. Both directions are plain storage reads on immutable
///      contracts — see {SickleHeldPositions} for why the balance layer reads both rather than trusting either.
interface ISickleFactory {
    /// @notice The Sickle deployed for `owner`, or `address(0)` if that owner has never deployed one.
    function sickles(address owner) external view returns (address sickle);
}

/// @notice The ownership attestation a Sickle makes about itself.
interface ISickle {
    /// @notice The account this Sickle was deployed for and acts on behalf of.
    function owner() external view returns (address);
}
