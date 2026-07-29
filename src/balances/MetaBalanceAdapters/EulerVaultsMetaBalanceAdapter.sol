// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";

/// @notice Minimal Euler V2 vault accessors beyond ERC4626. `debtOf` exists only on core eVaults (EVK); `EVC()` is
///         exposed by both core eVaults and EulerEarn vaults. A vault lacking either (or a non-Euler ERC4626)
///         degrades gracefully — but NOT via try/catch, which does not intercept a return-data decode failure or a
///         call to a code-less address. Both are read through low-level staticcalls rather than `try`, for that
///         reason; their POLICIES differ and the difference is deliberate. `EVC()` is bounded and fail-open
///         ({EulerVaultsMetaBalanceAdapter._safeEvc}) because losing it only re-keys a leg. `debtOf` takes a share
///         of the calling frame and fails CLOSED on exhaustion
///         ({EulerVaultsMetaBalanceAdapter._safeDebt}) because losing it changes a number. See
///         {EulerVaultsMetaBalanceAdapter._supplyKind} for the shared reasoning and {_safeDebt} for the split.
interface IEulerEVault {
    /// @return The account's current debt in the vault's underlying asset (interest-accrued), 0 if none.
    function debtOf(address account) external view returns (uint256);
    /// @return The Ethereum Vault Connector this vault is bound to.
    function EVC() external view returns (address);
}

/// @notice Ethereum Vault Connector — used to distinguish a collateral-enabled supply (Collateral) from a plain one.
interface IEVC {
    /// @return The vaults the account has enabled as collateral.
    function getCollaterals(address account) external view returns (address[] memory);
}

/// @title Euler Vaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's position in *any* Euler V2 ERC4626 vault — both the
///         EulerEarn aggregator vaults (the "Earn" product) and the core eVaults (EVK, the "Lend/Borrow" product).
///         The set of vaults to query is configured on NAVCalculator (per-adapter, MANAGER-gated) and passed in as
///         `bytes32` instance coordinates (vault addresses widened to bytes32).
/// @dev Euler V2 vaults are ERC4626-compliant, so the supplied balance is `convertToAssets(balanceOf(account))` —
///      identical in shape to the Morpho-vault adapter. Per instance the adapter emits up to two legs:
///        - **Supplied** — `convertToAssets(balanceOf)`, for any vault the account has shares in (EulerEarn earn
///          deposits, or core-eVault lend/collateral supply). Always positive, `isDebt = false`.
///        - **Borrowed** — `debtOf(account)`, for core eVaults the account borrows from. `isDebt = true`. EulerEarn
///          vaults do not implement `debtOf`, so a REVERT is read fail-open ({_safeDebt}) and means "no debt leg".
///          A read that runs out of gas is not a failure of that kind and fails closed instead — see {_safeDebt}.
///      Both legs share the same `positionId` (`abi.encode(address(vault))`) and are distinguished by `positionKind`,
///      matching the multi-leg convention used by the lending adapters (Aave/Spark supply vs borrow on one reserve).
///      A supply the account has enabled as EVC collateral is reported as `Collateral`; an unencumbered supply
///      (EulerEarn earn deposits, or core-eVault supply not enabled as collateral) is `Supplied` — determined via an
///      EVC `getCollaterals` lookup that is genuinely fail-open (see {_supplyKind}): every failure mode, including
///      the ones `try`/`catch` cannot intercept, degrades to `Supplied` rather than reverting the instance.
/// @dev **Instance set is a governed allowlist — not auto-enumerated.** Euler V2 exposes an on-chain
///      `GenericFactory` (mainnet `0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e`, `getProxyListLength()` /
///      `getProxyListSlice()`) enumerating every deployed vault, and this adapter could read it to avoid governance
///      seeding instances. We deliberately do NOT: the active set stays the MANAGER-curated `bytes32[]` on
///      NAVCalculator. This is the strongest case for the allowlist because the factory is **fully permissionless** —
///      anyone can deploy a vault (~850 exist, including junk like `eUNDEFINED-1`). Since balances are read
///      trustlessly from the vault (`balanceOf`→`convertToAssets`, `debtOf`), auto-including factory output would let
///      an attacker deploy a vault that reports a fabricated balance in a NAV-registered asset and inflate NAV; the
///      registered-asset filter does not help (the attack is denominated in a registered asset). Iterating ~850
///      vaults per account read is also impractical (the read path sizes buffers by `_metaInstanceTotal`). Use the
///      factory off-chain to *propose* instances; governance approves each into the allowlist. See
///      BALANCE_ADAPTERS.md §6.1.
contract EulerVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Thrown when the `debtOf` read ran out of the gas it was given rather than answering.
    /// @dev Declared here rather than on `INAVCalculator` because on the path that matters it is not the error a
    ///      consumer sees: `MetaBalanceAdapter._positionsForInstances` catches it and re-raises
    ///      `INAVCalculator.InstanceGasExhausted`, the wave-wide signal for this condition. Its purpose is to make
    ///      the instance revert instead of returning a leg-shaped answer with the debt missing.
    ///
    ///      One caller does receive it raw: `MetaBalanceAdapter.instancePositions` is `external` and probes a
    ///      single instance without that `catch`, so a configuration or reconciliation tool calling it directly
    ///      gets this selector rather than `InstanceGasExhausted`. Such a tool needs this ABI to tell "ran out of
    ///      gas" from an unknown failure. See {_safeDebt}.
    error DebtReadGasExhausted(address vault, address account, uint256 budget, uint256 consumed);

    /// @dev Gas stipend for the `getCollaterals` probe ({_isEnabledCollateral}) — the one fail-open read here that
    ///      is still hand-rolled, because it decodes an `address[]` with a bounded prefix scan rather than a single
    ///      word or a string, so neither shared reader fits it. A raw staticcall assigning `(bool, bytes memory)`
    ///      always `returndatacopy`s the response — including a revert payload, which a parameterless `catch {}`
    ///      does not — so an *uncapped* version would be strictly worse against a hostile address than the
    ///      `try`/`catch` it replaced: a `revert(0, 3_000_000)` costs ~35M gas to copy, enough to out-of-gas the
    ///      whole account read. The cap bounds both the callee's execution and, transitively, how much returndata it
    ///      can afford to expand into.
    ///
    ///      Measured against the real mainnet EVC at the fork-test block, fully cold: `getCollaterals` costs 6,328
    ///      gas — roughly 24x headroom. The stipend is a genuine (if distant) ceiling on honest reads: an EVC that
    ///      ever exceeded it would silently classify every collateral-enabled supply as `Supplied`. That is the safe
    ///      direction, and the fork test pins the live cost, but it is the reason this is generous rather than tight.
    ///
    ///      `debtOf` ({_safeDebt}) and `EVC()` ({_safeEvc}) no longer use this constant, and no longer share a
    ///      policy with each other either — the difference is what each read's absence costs:
    ///
    ///      - `EVC()` is CLASSIFICATION. Losing it degrades a `Collateral` leg to `Supplied`, which moves a
    ///        position between keys and changes no number, so it keeps the fixed {StaticCallLib.PROBE_GAS}
    ///        ceiling of 100_000. Measured at 15,318 gas cold on mainnet.
    ///      - `debtOf` is ACCOUNTING. Losing it removes a debt leg and RAISES the reported NAV, so it takes a
    ///        frame-derived stipend and fails closed on exhaustion — see {_safeDebt}. Measured at 32,125 gas cold
    ///        on a live core-eVault borrow, binary-searched minimum viable stipend 29,543.
    ///
    ///      Be precise about `debtOf`'s failure shape, because the obvious reassurance is WRONG. It is tempting to
    ///      say a starved `debtOf` merely reads 0 alongside a surviving supply leg, so the two vanish together.
    ///      That holds only when the same vault carries both. In Euler's canonical core topology the account
    ///      borrows from a CONTROLLER vault while its collateral sits in other vaults, so on the controller
    ///      `balanceOf(account) == 0` and a starved `debtOf` emits no legs at all — while the sibling vaults still
    ///      report their collateral in full. That is unoffset collateral, which OVER-reports NAV. Headroom is not
    ///      what makes that acceptable — nothing about a measured margin bounds a hostile or upgraded vault — so
    ///      the read no longer relies on it being unreachable.
    uint256 private constant PROBE_GAS = 150_000;

    /// @dev Upper bound on the collateral-list length {_supplyKind} will scan. The EVC caps an account's collateral
    ///      set at 10 elements (`SET_MAX_ELEMENTS`); this sits above that so a protocol-side bump does not silently
    ///      degrade classification, while still bounding the work a malformed/hostile `getCollaterals` can impose.
    uint256 private constant MAX_COLLATERALS = 32;

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns an empty array (rather than reverting) when the vault asset is unregistered or the account has
    ///      neither a supply nor a debt position, so a vault in either of those states does not disturb the rest of
    ///      the configured set. That isolation is NOT total, and the exception is deliberate: a `debtOf` read that
    ///      runs out of gas reverts {DebtReadGasExhausted} (see {_safeDebt}), which the base re-raises as
    ///      `InstanceGasExhausted` and `PriceFeedLib` propagates — so that one vault does take down the whole
    ///      account read. Answering with a number that is missing a debt leg is the worse outcome.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address vaultAddr = _toAddress(instance);
        IERC4626 vault = IERC4626(vaultAddr);
        address asset = vault.asset();

        // Apply asset filter (both legs are denominated in the vault's underlying asset).
        if (assetFilter != address(0) && assetFilter != asset) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Skip unregistered assets (NAVCalculator would drop them anyway). Note this suppresses BOTH this
        // vault's supply and debt legs together, since they share one asset — so within a vault there is no
        // unoffset-collateral hazard. It does NOT generalise across vaults: in Euler's core EVK model an
        // account borrows from a controller vault while its collateral sits in OTHER vaults with OTHER assets,
        // so an unregistered controller asset would drop the debt while sibling vaults still report collateral.
        // Not reachable today — both configured instances are EulerEarn aggregators, which have no `LTVList`
        // and whose `debtOf` reverts, so `debt` is permanently 0 — but adding a core eVault would open it.
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) {
            return new INAVCalculator.PositionBalance[](0);
        }

        uint256 supplied = vault.convertToAssets(vault.balanceOf(account));

        // Debt leg: only core eVaults (EVK) implement debtOf; EulerEarn aggregators do not, so a REVERT must not
        // drop the supply leg. Read low-level rather than through try/catch for the reasons documented on
        // {_supplyKind} — but through a different helper from the EVC probes, and under a different policy: a
        // frame-derived stipend that fails CLOSED on exhaustion. See {_safeDebt}.
        uint256 debt = _safeDebt(vaultAddr, account);

        uint256 n = (supplied > 0 ? 1 : 0) + (debt > 0 ? 1 : 0);
        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](n);
        if (n == 0) {
            return positions;
        }

        bytes memory positionId = _instancePositionId(instance);
        uint256 i = 0;
        if (supplied > 0) {
            positions[i++] = _leg(assetInfo, supplied, false, positionId, _supplyKind(account, vaultAddr));
        }
        if (debt > 0) {
            positions[i] = _leg(assetInfo, debt, true, positionId, PositionKind.Borrowed);
        }
        return positions;
    }

    /// @dev Classifies a supply leg: `Collateral` if the account has enabled this vault as EVC collateral, else
    ///      `Supplied`. EulerEarn aggregators do expose `EVC()`, but their shares can never be enabled as
    ///      collateral, so `getCollaterals` never lists them and they resolve to `Supplied`; a non-Euler ERC4626
    ///      lacking `EVC()` entirely likewise resolves to `Supplied`.
    ///
    ///      **Genuinely fail-open — every failure mode degrades to `Supplied`, none can revert.** This is safe by
    ///      construction: `PositionKind` is classification only. The `amount` is computed before this is called and
    ///      is untouched by it, and `isDebt` — not the kind — carries the sign that NAV prices. So the worst this
    ///      helper can do is under-classify a `Collateral` supply as `Supplied`; it can never change a reported
    ///      balance, drop a leg, or over-report. `Supplied` is already the intended default for every vault whose
    ///      collateral status cannot be established.
    ///
    ///      That property is the entire point of this rewrite, because the previous `try`/`catch` form did NOT hold
    ///      it. Solidity routes neither of these into `catch`, so both propagated out of `_instancePositions`, where
    ///      the base fan-out's per-instance `catch` dropped the ENTIRE instance — supply leg AND debt leg — turning
    ///      a display-classification failure into a silently zeroed real balance (and, on a core eVault, a
    ///      *suppressed debt*, which over-reports NAV):
    ///        1. **Return-data decode failure.** A call that SUCCEEDS but returns something undecodable as the
    ///           declared type reverts in the CALLING frame, past `catch`. Reproduced on solc 0.8.34 for `EVC()`
    ///           returning empty returndata (an ERC-1967 proxy whose implementation slot points at a code-less
    ///           address — the `delegatecall` succeeds and returns nothing) and returning a dirty-high-bits
    ///           `bytes32`, and for `getCollaterals` returning a bad offset or an absurd length.
    ///        2. **No-code address.** A high-level call to an address with no code reverts via Solidity's
    ///           `extcodesize` precheck BEFORE the call, which `catch` also does not catch. Neither address was
    ///           guarded.
    ///
    ///      The fix for BOTH modes is the same move: drop to a low-level `staticcall`. That is what removes the
    ///      `extcodesize` precheck (mode 2) — a raw `staticcall` to a code-less address simply returns
    ///      `(true, "")`, which the returndata-length checks then reject — and it is what lets the ABI head be
    ///      validated before decoding instead of trusting the declared return type (mode 1). A `code.length` guard
    ///      in front of a low-level `staticcall` is therefore a cheap short-circuit that skips a pointless call,
    ///      NOT the thing that makes mode 2 safe — which is why `_safeEvc`/`_safeDebt` no longer carry one at all
    ///      now that they delegate to {StaticCallLib}, and behave identically.
    ///
    ///      Stipends differ per read and it matters when tuning them: `_safeEvc` is bounded by
    ///      `StaticCallLib.PROBE_GAS` (100_000); `_isEnabledCollateral` — still hand-rolled, because it decodes an
    ///      `address[]` with a bounded prefix scan — by this file's own {PROBE_GAS} (150_000); and `_safeDebt` by
    ///      neither, taking a share of the calling frame instead (see there for why an accounting read cannot use
    ///      a fixed local ceiling). Changing the local constant moves only the collateral probe.
    ///
    ///      One consequence of that split is worth stating: `_safeDebt` runs BEFORE the classification probes and
    ///      no longer has a ceiling, so a vault that makes it expensive leaves less for `_safeEvc` and
    ///      `_isEnabledCollateral` further down. Ordinarily those simply degrade to `Supplied`, which re-keys a
    ///      leg and changes no amount.
    ///
    ///      That is the ordinary case, not a guarantee. `_isEnabledCollateral` assigns `(bool, bytes memory)`
    ///      from its raw staticcall, so the caller pays an uncapped `returndatacopy`; against an EVC returning a
    ///      very large `address[]` (the shape `test_supplyKind_returndataBomb_boundedAndFailsOpen` pins) that
    ///      copy can exceed what an expensive `debtOf` left behind and out-of-gas `_instancePositions` outright.
    ///      The base then classifies the instance as exhausted and the account read reverts. Loud rather than
    ///      wrong, and it needs both a costly `debtOf` and a hostile EVC on the same governed vault — but it is
    ///      a revert, not a re-key, so do not read the paragraph above as "this ordering can only cost fidelity".
    ///
    ///      `vaultAddr` is MANAGER-governed and its guard is defensive only — `_instancePositions` already reverts
    ///      on a code-less vault at `asset()`, long before this is reached. The live exposure is `evc`, which is
    ///      read FROM the vault, and the collateral list, which is read from that `evc`: both are outside the
    ///      governed set and can be upgraded or swapped after an instance is registered.
    ///
    ///      One downstream consequence, deliberate: `positionKind` is a component of the off-chain reconciliation
    ///      key (`docs/howto/position-identity-schema.md`), so degrading `Collateral` to `Supplied` re-keys the
    ///      row. That is strictly better than the behaviour it replaces — the instance vanishing entirely, which
    ///      destroys the row *and* its debt leg — but it does mean a broken EVC shows up off-chain as a position
    ///      moving between keys rather than as an error.
    function _supplyKind(address account, address vaultAddr) private view returns (PositionKind) {
        address evc = _safeEvc(vaultAddr);
        if (evc == address(0)) return PositionKind.Supplied;
        return _isEnabledCollateral(evc, account, vaultAddr) ? PositionKind.Collateral : PositionKind.Supplied;
    }

    /// @dev Reads `debtOf`, failing OPEN on a revert and CLOSED on an exhausted stipend. Returns 0 — "no debt
    ///      leg" — for a code-less vault, a reverting call, or fewer than 32 bytes of returndata; reverts
    ///      {DebtReadGasExhausted} when the call consumed essentially everything it was forwarded.
    ///
    ///      Uses the same bounded low-level form as {_safeEvc} rather than `try`/`catch`, and for the same reason:
    ///      `catch` does not intercept a return-data decode failure. EulerEarn aggregators genuinely revert here
    ///      (they have no `debtOf`), which `catch` *would* have handled — but a vault whose `debtOf` SUCCEEDS and
    ///      returns something undecodable as `uint256` (empty returndata from an ERC-1967 proxy whose implementation
    ///      slot points at a code-less address; an EVK dispatcher with an unset module) reverted the whole
    ///      `_instancePositions` frame, and the base fan-out then dropped the ENTIRE instance.
    ///
    ///      Unlike the classification helpers this one is **not** merely cosmetic, which is why it matters more:
    ///      dropping the instance suppresses the DEBT leg. Within one vault that is harmless (supply and debt share
    ///      an asset, so both vanish together — the same reasoning as the unregistered-asset early return above).
    ///      Across vaults it is not: in Euler's core EVK model an account borrows from a controller vault while its
    ///      collateral sits in OTHER vaults, so a decode-failing controller drops the debt while sibling vaults
    ///      still report collateral — unoffset collateral, which OVER-reports NAV. Reading 0 keeps the failure in
    ///      the safe direction only when the supply leg survives alongside it, which on a controller vault
    ///      (`balanceOf == 0`) it does not — which is why an exhausted stipend now reverts rather than reading 0.
    ///
    ///      Not reachable on the configured mainnet instances today (both are EulerEarn aggregators whose `debtOf`
    ///      genuinely reverts), but the instance set is governed config and adding a core eVault would open it.
    ///
    ///      **Fail-open on a revert, FAIL-CLOSED on an exhausted stipend**, which is why this does not use
    ///      {StaticCallLib.safeUint}: that helper's `ok` folds the two together, and they are opposite events. A
    ///      vault that reverts has answered "I have no `debtOf`" — EulerEarn's case, and reading 0 is correct. A
    ///      vault that ran out of gas has answered nothing, and reading 0 there is how a real borrow becomes a
    ///      higher NAV. Reverting instead makes the instance fail rather than return a number missing a leg.
    ///
    ///      The stipend {StaticCallLib.probeWordMetered} uses is a share of THIS frame rather than
    ///      {StaticCallLib.PROBE_GAS}, and that is the half that actually closes the hole. A fixed local ceiling is unrecoverable — it binds identically at every
    ///      budget, so no amount of extra gas gets the read through — and, worse, it is invisible: 100_000 spent
    ///      inside a multi-megagas instance stipend looks like a cheap revert to the base fan-out's gas-based
    ///      classifier, which then drops the instance silently. A frame-derived stipend makes a starved read
    ///      consume enough of the instance's budget that {MetaBalanceAdapter._positionsForInstances} classifies
    ///      it and raises `InstanceGasExhausted`, so the failure leaves the adapter instead of being absorbed one
    ///      frame below the guard built to catch it. That guard's docstring names this exact blind spot — an
    ///      instance that swallows its own out-of-gas — and this is how this adapter stops being an instance that
    ///      does.
    ///
    ///      {DebtReadGasExhausted} is therefore the MECHANISM rather than the signal a consumer sees: its job is
    ///      to make the instance revert at all. The base re-labels it as `InstanceGasExhausted`, which is the
    ///      error already carried on `INAVCalculator` for exactly this condition.
    ///
    ///      **What this guard is and is not for.** Its threat model is ACCIDENTAL starvation — an honest vault
    ///      made dearer by an upgrade, a proxy hop that grew, a frame squeezed by the instances ahead of it. It is
    ///      not a defence against a hostile vault, and cannot be: a vault willing to starve the read can instead
    ///      `return 0` from `debtOf` and produce the identical unoffset-collateral over-report for free, at no
    ///      gas cost and with nothing anywhere to classify. The trust boundary for a hostile vault is governance
    ///      approving the instance; this guard sits inside it.
    ///
    ///      Two bounds follow from that, both measured rather than assumed:
    ///
    ///      - **Depth.** Starvation is classified loud through 8 callee frames below the probe, counting frames
    ///        on the composed path. Real EVK dispatcher/module hops are 2-4, so this is ample against accidents —
    ///        but the depth is the CALLEE's, so it does not bound a vault choosing it.
    ///
    ///        **This 8 is derived, not owned here, and no test pins it.** It falls straight out of
    ///        `GasStipendLib.SLACK_DIVISOR = 8`: `(63/64)^8 = 0.8816 >= 7/8 > (63/64)^9 = 0.8679`. Change the
    ///        divisor in that file — which this adapter does not own, and which the bracket test below proves is
    ///        a live possibility in both directions — and this number moves with it, to ~18 frames at divisor 4
    ///        and ~3 at divisor 16, with nothing here going red to say so. Re-derive rather than trust it if
    ///        `SLACK_DIVISOR` has changed.
    ///
    ///        Past 8 the debt reads 0 while the supply leg survives: the unoffset-collateral over-report, at 9
    ///        frames and beyond. There is no intervening regime. An earlier revision of this note claimed 9 was
    ///        a safe middle case in which the whole instance dropped — that was a symptom of classifying against
    ///        the forwarded stipend rather than the frame, i.e. of the silent-drop band this adapter's guard was
    ///        corrected to close, and it disappeared with it. Measured invariant across frame size.
    ///      - **Cost.** A genuine revert is misread as starvation only when it costs a large fraction of the
    ///        frame — `frame <= (8/7) * revert_cost`, about 1.14x. A real EulerEarn dispatch failure costs
    ///        single-digit thousands, two orders of magnitude below the frame its own prologue needs, so the band
    ///        is empty in practice. The counter-intuitive part is the direction: a MORE expensive genuine revert
    ///        is MORE likely to be called starved, not less.
    ///
    ///      **Starvation is not the only route to unoffset collateral here, and the others keep the old policy.**
    ///      A successful reply carrying fewer than 32 bytes (an EVK dispatcher with an unset module; an ERC-1967
    ///      proxy whose implementation slot points at a code-less address) still reads as 0, and so does the
    ///      unregistered-controller-asset early return above. Both produce the same over-report and both remain
    ///      fail-open, so this function deliberately carries two policies. The distinction is evidence, not
    ///      severity: an exhausted stipend is the one failure whose gas cost the callee cannot fake, so it is the
    ///      one that can be classified from outside. Closing the others needs a different mechanism than a gas
    ///      threshold, and is tracked separately rather than smuggled in here.
    ///
    ///      Why the whole read must fail rather than just this leg: the over-report is not local to this vault.
    ///      In Euler's core topology the controller vault holds the debt with `balanceOf == 0`, so suppressing
    ///      its debt leg removes the instance's ONLY leg while sibling vaults keep reporting collateral in full.
    ///      Nothing inside this instance can offset that; only refusing to answer can.
    function _safeDebt(address vaultAddr, address account) private view returns (uint256) {
        (bool ok, bool hasWord, uint256 debt, bool starved, uint256 budget, uint256 consumed) =
            StaticCallLib.probeWordMetered(vaultAddr, abi.encodeCall(IEulerEVault.debtOf, (account)));
        if (starved) revert DebtReadGasExhausted(vaultAddr, account, budget, consumed);
        if (!ok || !hasWord) return 0;
        return debt;
    }

    /// @dev Fail-open `EVC()` read. Returns `address(0)` — the "cannot classify" sentinel {_supplyKind}
    ///      short-circuits on — for a code-less vault, a reverting/out-of-stipend call, fewer than 32 bytes of
    ///      returndata, or a word with dirty high bits (a `bytes32`-shaped return, not an address).
    function _safeEvc(address vaultAddr) private view returns (address) {
        // STRICT, not {StaticCallLib.safeAddr}: `address(0)` is this read's "cannot classify" sentinel, so a
        // masked-from-garbage zero would be indistinguishable from a real one. See {StaticCallLib.safeAddrStrict}.
        (, address evc,) = StaticCallLib.safeAddrStrict(vaultAddr, abi.encodeCall(IEulerEVault.EVC, ()));
        return evc;
    }

    /// @dev Fail-open `getCollaterals` membership test. Returns false — degrading the leg to `Supplied` — for a
    ///      code-less EVC, a reverting/out-of-stipend call, or returndata that is not a canonical `address[]`.
    ///      A canonical `address[]` return is `[offset = 0x20][length][element…]`, so this requires two full words,
    ///      an offset of exactly `0x20`, and a payload that actually fits inside the returndata; a longer-than-cap
    ///      list is scanned as a {MAX_COLLATERALS}-entry prefix rather than rejected. Elements are compared as full
    ///      words, so an entry with dirty high bits simply never matches — strictly under-classifying, consistent
    ///      with the fail-open contract.
    function _isEnabledCollateral(address evc, address account, address vaultAddr) private view returns (bool) {
        if (evc.code.length == 0) return false;
        (bool ok, bytes memory data) = evc.staticcall{gas: PROBE_GAS}(abi.encodeCall(IEVC.getCollaterals, (account)));
        if (!ok || data.length < 64) return false;

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        // A truncated payload is malformed — reject it outright. An over-long but well-formed list is NOT
        // malformed, so scan its first {MAX_COLLATERALS} entries rather than discarding the whole thing: bounding
        // the work is the cap's purpose, and rejecting wholesale would silently degrade every classification the
        // moment Euler raised `SET_MAX_ELEMENTS` past 32 — the exact outcome the cap exists to avoid. Scanning a
        // prefix can only ever find a true positive; missing an entry past the cap degrades to `Supplied`, which
        // is the safe direction.
        if (offset != 0x20 || len > (data.length - 64) / 32) return false;
        uint256 scan = len > MAX_COLLATERALS ? MAX_COLLATERALS : len;

        uint256 target = uint256(uint160(vaultAddr));
        for (uint256 j = 0; j < scan; j++) {
            uint256 word;
            // `data` points at its own length prefix, so returndata word 0 (the offset) is at `data + 0x20` and
            // word 1 (the array length) at `data + 0x40` — elements therefore start at `data + 0x60`.
            assembly ("memory-safe") {
                word := mload(add(data, add(0x60, mul(j, 0x20))))
            }
            if (word == target) return true;
        }
        return false;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Vault", <leaf>]` where the leaf is the vault's ERC4626 name ("" if unreadable). Returns an
    ///      empty array for a malformed positionId (see {_pidAddress}).
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Vault", false);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.EULER;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.EULER;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.EULER_VAULTS;
    }
}
