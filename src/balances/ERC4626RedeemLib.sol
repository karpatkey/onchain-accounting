// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {GasStipendLib} from "src/utils/GasStipendLib.sol";

/// @notice Minimal ERC4626 read surface for {ERC4626RedeemLib} — the fee-aware `previewRedeem`.
interface IERC4626Redeemable {
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @notice `previewRedeem` ran out of the gas its frame was given, so the position could not be valued and must
///         not be silently dropped.
/// @dev Declared file-local rather than in `src/errors.sol`: both pinned libraries plain-import that file, so
///      adding to it would pull this symbol into both CREATE2 compilation closures for no benefit.
error RedeemValueGasExhausted(address vault, uint256 stipend, uint256 consumed);

/// @title ERC4626RedeemLib
/// @author KPK
/// @notice Shared fee-aware share→asset valuation for ERC4626 vaults whose wrapper may charge a withdrawal/exit
///         fee. {redeemValue} reports `previewRedeem` — which, per EIP-4626 §4.3, is net of any redemption fee —
///         and reports **nothing** when that read fails, rather than substituting a value known to be an upper
///         bound.
/// @dev Extracted so its callers share one copy of this subtle preference rather
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
    ///      behaviour it replaces was an invisible over-report. Every caller already treats 0 as "no leg"
    ///      (`MorphoVaultsMetaBalanceAdapter` and `SymbioticVaultsMetaBalanceAdapter` return an empty array;
    ///      `AaveUmbrellaBalanceAdapter` skips the leg; `YoVaultsMetaBalanceAdapter` drops the held leg and, as
    ///      the `min` of its pending valuation, the pending leg), so no caller-side change is needed and no caller
    ///      learns to trust a fabricated number. **That list is exhaustive as written; grep `redeemValue` before
    ///      relying on it** — it has already gone stale twice, when a third and a fourth caller were added.
    ///
    ///      **Why this is a raw staticcall and not `try`/`catch`.** An earlier revision used `try`/`catch` and
    ///      justified it with "the return type is a single `uint256`, so there is no decode that can revert past
    ///      the `catch`". That is FALSE, and the mistake is worth recording because it is the same class this
    ///      whole sweep exists to remove. A high-level call that expects return data does not emit an
    ///      `extcodesize` precheck — the returndata-size check subsumes it — so a callee returning ZERO bytes
    ///      makes the call SUCCEED and the `uint256` decode then reverts in THIS frame, outside the `catch`. The
    ///      trigger is the one the ezETH commit in this same PR calls "not hypothetical": an ERC-1967 proxy whose
    ///      implementation slot points at a code-less address.
    ///
    ///      The blast radius made it worse than a dropped leg. In `AaveUmbrellaBalanceAdapter` this is reached
    ///      from `_sharesToUnderlying` INLINE inside `getAdapterPositions`, with no per-stake-token isolation, and
    ///      through a wrapper address that was only ever probed with low-level staticcalls — never high-level
    ///      called. So the revert propagated out of the whole adapter, `PriceFeedLib._getAdapterPositions` scored
    ///      the cheap revert benign, and EVERY Umbrella staking, cooldown and rewards leg vanished from the NAV
    ///      with no staleness, irregular or gas signal set.
    ///
    ///      **The two failure kinds are now separated, because they deserve opposite answers.**
    ///        - **Starved** — `previewRedeem` ran out of the gas it was given. The position was NOT valued, and
    ///          returning 0 would silently delete it: `MorphoVaultsMetaBalanceAdapter` would emit an empty array
    ///          and SUCCEED, so no classifier upstream ever fires and an operator cannot tell the difference
    ///          between "starved" and "the fund exited the vault". That is the absorb-your-own-out-of-gas hole
    ///          this PR closes in {AssistedCoordCache} and {FluidVaultLib}, and it was left open here. It now
    ///          raises {RedeemValueGasExhausted}, which the callers' existing gas classifiers surface loudly.
    ///        - **Genuinely unreadable** — a revert, an empty reply, a short reply, a code-less vault. The vault
    ///          has answered, or cannot answer at all; there is nothing to value and no reason to fail the whole
    ///          account's read. Reports 0, which every caller already treats as "no leg".
    ///
    ///      The stipend is `GasStipendLib.stipendFrom` — a PROPORTION of the caller's own budget, not a fixed
    ///      ceiling. That matters here specifically: MetaMorpho's `previewRedeem` walks the withdraw queue, so a
    ///      fixed cap (`StaticCallLib.PROBE_GAS` is 100_000) could be exceeded by an entirely honest vault and
    ///      would be unrecoverable by supplying more gas. That is also why this does not simply call
    ///      {StaticCallLib.probeWord}, which is otherwise the right shape.
    ///
    ///      The 32-byte output window means the reply size cannot be charged to this frame, which the
    ///      `try`/`catch` form could not claim either.
    function redeemValue(address vault, uint256 shares) internal view returns (uint256) {
        bytes memory cd = abi.encodeCall(IERC4626Redeemable.previewRedeem, (shares));

        // One sample, used both to derive the stipend and to measure against it — see GasStipendLib.exhausted.
        uint256 available = gasleft();
        uint256 stipend = GasStipendLib.stipendFrom(available);

        bool ok;
        uint256 size;
        uint256 net;
        assembly ("memory-safe") {
            // 32-byte output window at the free pointer, WITHOUT bumping it — nothing allocates across this
            // block. Zeroed first so a short reply cannot surface a previous allocation's bytes.
            let out := mload(0x40)
            mstore(out, 0)
            ok := staticcall(stipend, vault, add(cd, 0x20), mload(cd), out, 0x20)
            size := returndatasize()
            net := mload(out)
        }

        if (ok && size >= 32) return net;

        // The read did not produce a value. Which KIND of failure decides what happens next.
        uint256 consumed = available - gasleft();
        if (GasStipendLib.exhausted(stipend, consumed)) {
            revert RedeemValueGasExhausted(vault, stipend, consumed);
        }
        return 0;
    }
}
