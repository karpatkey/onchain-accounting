// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal ERC4626 read surface for {ERC4626RedeemLib} — the fee-aware `previewRedeem` and the
///         rate-only `convertToAssets` fallback.
interface IERC4626Redeemable {
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// @title ERC4626RedeemLib
/// @author KPK
/// @notice Shared fee-aware share→asset valuation for ERC4626 vaults whose wrapper may charge a withdrawal/exit
///         fee. {redeemValue} prefers `previewRedeem` (which, per EIP-4626 §4.3, is net of any redemption fee that
///         `convertToAssets` MUST ignore) so a fee-charging vault is not over-reported, and falls back to
///         `convertToAssets` only when `previewRedeem` reverts (e.g. the vault is paused) so the position is still
///         reported. For fee-less vaults the two are equal.
/// @dev Extracted so the Morpho-vault and Aave-Umbrella adapters share one copy of this subtle preference rather
///      than each inlining the try/catch. Adapters that deliberately value at the raw rate (Euler, Fluid, Gearbox,
///      StakeWise, Cap) call `convertToAssets` directly and do NOT use this library.
library ERC4626RedeemLib {
    /// @notice The fee-net asset value of `shares` in `vault`: `previewRedeem(shares)`, falling back to
    ///         `convertToAssets(shares)` if `previewRedeem` reverts.
    function redeemValue(address vault, uint256 shares) internal view returns (uint256) {
        try IERC4626Redeemable(vault).previewRedeem(shares) returns (uint256 net) {
            return net;
        } catch {
            return IERC4626Redeemable(vault).convertToAssets(shares);
        }
    }
}
