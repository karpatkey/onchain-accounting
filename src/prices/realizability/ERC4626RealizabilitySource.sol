// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {RealizabilityBaseline} from "./RealizabilityBaseline.sol";

interface IERC4626Preview {
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
}

/// @title ERC4626RealizabilitySource
/// @notice Realizability source for instant-redemption ERC4626 vaults (e.g. sUSDS, sDAI). Withdrawals are considered
///         enabled when a redemption preview succeeds and the vault holds assets; redemption is ~instant.
/// @dev Suits vaults that redeem synchronously against on-hand liquidity. NOT for request/queue vaults (e.g. Maple
///      syrupUSDC), where `previewRedeem` returns the rate even though a withdrawal is queued — use the MANAGER
///      scalar for those. `instantEtaSeconds` is normally 0; a small non-zero value can model a settlement lag.
/// @author KPK
contract ERC4626RealizabilitySource is RealizabilityBaseline {
    /// @notice The ERC4626 vault (== UNDERLYING for a share token).
    address public immutable VAULT;

    /// @notice Expected redemption time when withdrawals are enabled (0 ≈ instant).
    uint256 public immutable INSTANT_ETA_SECONDS;

    /// @param vault The ERC4626 vault / share token (also the underlying asset this source is pinned to).
    /// @param instantEtaSeconds Expected redemption seconds when enabled (usually 0).
    constructor(address vault, uint256 instantEtaSeconds) RealizabilityBaseline(vault) {
        VAULT = vault;
        INSTANT_ETA_SECONDS = instantEtaSeconds;
    }

    /// @notice Current redemption status for the pinned asset (see IRealizabilitySource).
    function realizability()
        external
        view
        override
        returns (bool withdrawalsEnabled, uint256 expectedRedemptionSeconds, bool healthy)
    {
        // Redemption is realizable when a preview succeeds (vault not paused) and there are assets to redeem into.
        try IERC4626Preview(VAULT).previewRedeem(1e18) returns (uint256 assets) {
            withdrawalsEnabled = assets > 0 && IERC4626Preview(VAULT).totalAssets() > 0;
        } catch {
            withdrawalsEnabled = false;
        }
        expectedRedemptionSeconds = withdrawalsEnabled ? INSTANT_ETA_SECONDS : 0;
        healthy = true;
    }
}
