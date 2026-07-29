// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal ERC4626 read surface for {ERC4626RedeemLib} — the fee-aware `previewRedeem`.
interface IERC4626Redeemable {
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @title ERC4626RedeemLib
/// @author KPK
/// @notice Shared fee-aware share→asset valuation for ERC4626 vaults whose wrapper may charge a withdrawal/exit
///         fee. {redeemValue} reports `previewRedeem` — which, per EIP-4626 §4.3, is net of any redemption fee —
///         and reports **nothing** when that read fails, rather than substituting a value known to be an upper
///         bound.
/// @dev Extracted so the Morpho-vault and Aave-Umbrella adapters share one copy of this subtle preference rather
///      than each inlining the read. Adapters that deliberately value at the raw rate (Euler, Fluid, Gearbox,
///      StakeWise, Cap) call `convertToAssets` directly and do NOT use this library.
library ERC4626RedeemLib {
    /// @notice The fee-net asset value of `shares` in `vault`: `previewRedeem(shares)`, or **0** if that read
    ///         cannot be completed.
    /// @dev **Why a failed read reports 0 rather than falling back to `convertToAssets`.** It used to fall back.
    ///      That fallback was unconditionally UPWARD and therefore an over-report, which is the one direction an
    ///      adapter in this repo may never take:
    ///
    ///        - EIP-4626 §4.3 requires `convertToAssets` to IGNORE any redemption fee, and requires
    ///          `previewRedeem` to include it. So `convertToAssets(s) >= previewRedeem(s)` by construction, with
    ///          the gap being exactly the fee. Substituting one for the other cannot lose value; it can only add
    ///          value that a redemption would not actually pay.
    ///        - `catch` fires for far more than the "vault is paused" case it was written for: a withdraw-queue
    ///          market reverting, and — the one that matters on a NAV read — `previewRedeem` running out of the
    ///          gas its frame was given, after which the cheaper `convertToAssets` can still complete. Gas
    ///          starvation therefore selected the inflated branch precisely when the read was least trustworthy.
    ///        - Nothing downstream can see it happen. The leg is emitted well-formed, with the right asset,
    ///          `positionId` and `positionKind`; only `amount` is larger. It is a balance-side failure, so no
    ///          price-side signal fires (`nav.stalePriceAssets`, `nav.irregularPriceAssets`, `pd.irregular` are
    ///          all untouched), and nothing reverted, so neither `AdapterGasExhausted` nor `InstanceGasExhausted`
    ///          fires either. `getAccountNavVerbose` is not a cross-check — it runs the same math over the same
    ///          `PositionBalance[]` and returns the same wrong number.
    ///
    ///      Reporting 0 instead is the same trade every sibling adapter already makes when it cannot value one
    ///      side of a position: drop the position rather than move the number upward. See
    ///      `GearboxV3CreditAccountsMetaBalanceAdapter` ("If the debt read fails for a credit account, the WHOLE
    ///      account is dropped … reporting collateral alone would overstate equity"),
    ///      `FluidVaultsMetaBalanceAdapter._instancePositions` ("A debt this adapter cannot report must never
    ///      leave its collateral standing alone … Under-reporting the whole position is the safe direction") and
    ///      `MorphoMarketsMetaBalanceAdapter._instancePositions` (the same sentence again). This library was the
    ///      one place in `src/balances` that resolved a failed read the other way.
    ///
    ///      **The cost, stated so it is not rediscovered as a bug.** A vault whose `previewRedeem` is unavailable
    ///      now contributes nothing instead of contributing a gross figure. That is a visible under-report — the
    ///      position disappears from a report the fund can compare against its own expectations — where the
    ///      behaviour it replaces was an invisible over-report. Both callers already treat 0 as "no leg"
    ///      (`MorphoVaultsMetaBalanceAdapter` returns an empty array; `AaveUmbrellaBalanceAdapter` skips the
    ///      leg), so no caller-side change is needed and no caller learns to trust a fabricated number.
    ///
    ///      `previewRedeem` is called through `try`/`catch`, which is sufficient HERE and would not be
    ///      elsewhere: the return type is a single `uint256`, so there is no decode that can revert past the
    ///      `catch`, and `vault` is a governed instance coordinate that `_instancePositions` has already
    ///      high-level-called (`asset()`, `balanceOf`) before reaching this, so a code-less `vault` cannot get
    ///      this far. Widen either of those and this needs {StaticCallLib} instead.
    function redeemValue(address vault, uint256 shares) internal view returns (uint256) {
        try IERC4626Redeemable(vault).previewRedeem(shares) returns (uint256 net) {
            return net;
        } catch {
            return 0;
        }
    }
}
