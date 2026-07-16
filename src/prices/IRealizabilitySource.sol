// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IRealizabilitySource
/// @notice Per-asset source of a claim asset's *redemption* status — distinct from its price. A healthy exchange
///         rate does not mean a position can actually be redeemed soon: withdrawals may be paused, the protocol may
///         be in a degraded state (e.g. Lido bunker mode), or the exit queue may be long. This source reports that
///         status so NAVCalculator can emit an `unrealizable` signal; the downstream sub/redeem processor decides
///         whether to fail closed (a healthy-but-unrealizable rate is the overpay/dilute case).
/// @dev Pinned to a single asset (mirrors {ICustomPriceFeed}); implementers self-declare via ERC165 so the registry
///      can validate them. `expectedRedemptionSeconds` is a coarse estimate — it only needs to straddle the
///      per-asset limit configured on the NAV, not be exact. Reads should be view-only and fail-safe.
/// @author KPK
interface IRealizabilitySource is IERC165 {
    /// @notice The token whose redemption status this source reports.
    function underlyingAssetSupported() external view returns (address);

    /// @notice Current redemption status for the pinned asset.
    /// @return withdrawalsEnabled False when redemptions are paused/halted (e.g. protocol paused, no liquidity).
    /// @return expectedRedemptionSeconds Coarse estimate of time-to-redeem (0 ≈ instant).
    /// @return healthy Protocol-health flag; false (e.g. Lido bunker mode) means treat as unrealizable regardless
    ///         of the ETA.
    function realizability()
        external
        view
        returns (bool withdrawalsEnabled, uint256 expectedRedemptionSeconds, bool healthy);
}
