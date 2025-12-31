// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IBalanceOracleCustom
/// @author kpk
/// @notice A standard interface for custom balance oracles that map a user’s DeFi position
///         (vault shares, receipt tokens, LP tokens, etc.) back into an amount of an underlying token asset.
/// @dev Extends ERC165 to allow on‐chain discovery with `supportsInterface`.
interface IBalanceOracleCustom is IERC165 {
    /// @notice Metadata tags describing the DeFi position this oracle is associated to.
    /// @param protocol The protocol name.
    /// @param position The specified position within the protocol.
    /// @param positionType The type of the position (e.g., "Supplied", "Borrowed", "Staked").
    struct PositionMetadata {
        string protocol;
        string position;
        string positionType;
    }

    /// @notice Calculates the current value of a user’s holdings in this DeFi position,
    ///         expressed in the underlying asset.
    /// @param  underlyingAsset The token address in which the position’s value is denominated.
    /// @param  account The address whose position balance is being queried.
    /// @return balance The amount of `underlyingAsset` that `account`’s position is worth, as a signed integer.
    function balanceOf(address underlyingAsset, address account) external view returns (int256 balance);

    /// @notice Returns the list of all the underlying assets supported by this oracle.
    /// @dev The returned list may be empty if the oracle cannot determine or provide the supported assets.
    /// @return underlyingAssets The list of underlying asset addresses supported by this oracle (may be empty).
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets);

    /// @notice Metadata tags describing the DeFi position this oracle is associated to.
    /// @return positionMetadata The position metadata associated with this oracle.
    function positionMetadata() external view returns (PositionMetadata memory positionMetadata);
}
