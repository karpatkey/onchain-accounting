// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title ICappedRateFeed
/// @author KPK
/// @notice Marker/accessor interface for yield-bearing Custom price feeds whose exchange rate is growth-capped
///         (and optionally market-floored) against per-asset config held on the NAV (ADR 0021). The feed stays
///         immutable — it holds no cap parameters and no setters; it reads them from `NAVCalculator.getRateCap`.
///         `rawRate()` exposes the UNCAPPED protocol rate so the NAV's MANAGER-gated `snapshotRateCap` can record
///         the baseline the cap ratchets from.
interface ICappedRateFeed {
    /// @notice The uncapped protocol exchange rate, 18-decimal base-token units per 1 underlying (e.g. ETH per
    ///         rsETH). Reverts-to-... nothing: fail-to-stale is handled in the price path, but this raw accessor
    ///         returns the live protocol value for snapshotting.
    /// @return rate The uncapped 18-decimal exchange rate.
    function rawRate() external view returns (uint256 rate);
}
