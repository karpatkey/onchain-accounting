// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal Euler V2 vault accessors beyond ERC4626. `debtOf` exists only on core eVaults (EVK); `EVC()` is
///         exposed by both core eVaults and EulerEarn vaults. A vault lacking either (or a non-Euler ERC4626)
///         degrades gracefully: `debtOf` is read under try/catch (a revert means "no debt leg"), and `EVC()` via the
///         bounded fail-open staticcall in {EulerVaultsMetaBalanceAdapter._safeEvc} — try/catch is NOT sufficient
///         there, see {EulerVaultsMetaBalanceAdapter._supplyKind}.
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
///          vaults do not implement `debtOf`, so it is read under try/catch and a revert means "no debt leg".
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
    /// @dev Gas stipend for each of the two EVC probe reads in {_supplyKind}. A raw staticcall assigning
    ///      `(bool, bytes memory)` always `returndatacopy`s the response — including a revert payload, which a
    ///      parameterless `catch {}` does not — so an *uncapped* version of these reads would be strictly worse
    ///      against a hostile address than the `try`/`catch` they replace: a `revert(0, 3_000_000)` costs ~35M gas
    ///      to copy, enough to out-of-gas the whole account read. The cap bounds both the callee's execution and,
    ///      transitively, how much returndata it can afford to expand into. 150k leaves ample headroom for a real
    ///      proxied `EVC()` (a single SLOAD) and a real `getCollaterals` (an EVC set read, ≤10 cold SLOADs).
    uint256 private constant EVC_PROBE_GAS = 150_000;

    /// @dev Upper bound on the collateral-list length {_supplyKind} will scan. The EVC caps an account's collateral
    ///      set at 10 elements (`SET_MAX_ELEMENTS`); this sits above that so a protocol-side bump does not silently
    ///      degrade classification, while still bounding the work a malformed/hostile `getCollaterals` can impose.
    uint256 private constant MAX_COLLATERALS = 32;

    /// @param protocolName_ Human-readable protocol name (e.g. "Euler").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns an empty array (rather than reverting) when the vault asset is unregistered or the account has
    ///      neither a supply nor a debt position, so a single vault never zeroes out the rest of the configured set.
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

        // Debt leg: only core eVaults (EVK) implement debtOf; EulerEarn aggregators do not, so guard with try/catch
        // — a revert there must not drop the supply leg.
        uint256 debt = 0;
        try IEulerEVault(vaultAddr).debtOf(account) returns (uint256 d) {
            debt = d;
        } catch {}

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
    ///      Both addresses are now `code.length`-guarded, both reads are bounded by {EVC_PROBE_GAS}, and the ABI
    ///      head is validated before decoding rather than trusting the declared return type. Note `vaultAddr` is
    ///      MANAGER-governed and its guard is defensive only — `_instancePositions` already reverts on a code-less
    ///      vault at `asset()`, long before this is reached. The live exposure is `evc`, which is read FROM the
    ///      vault, and the collateral list, which is read from that `evc`: both are outside the governed set and
    ///      can be upgraded or swapped after an instance is registered.
    function _supplyKind(address account, address vaultAddr) private view returns (PositionKind) {
        address evc = _safeEvc(vaultAddr);
        if (evc == address(0)) return PositionKind.Supplied;
        return _isEnabledCollateral(evc, account, vaultAddr) ? PositionKind.Collateral : PositionKind.Supplied;
    }

    /// @dev Fail-open `EVC()` read. Returns `address(0)` — the "cannot classify" sentinel {_supplyKind}
    ///      short-circuits on — for a code-less vault, a reverting/out-of-stipend call, fewer than 32 bytes of
    ///      returndata, or a word with dirty high bits (a `bytes32`-shaped return, not an address).
    function _safeEvc(address vaultAddr) private view returns (address) {
        if (vaultAddr.code.length == 0) return address(0);
        (bool ok, bytes memory data) = vaultAddr.staticcall{gas: EVC_PROBE_GAS}(abi.encodeCall(IEulerEVault.EVC, ()));
        if (!ok || data.length < 32) return address(0);

        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @dev Fail-open `getCollaterals` membership test. Returns false — degrading the leg to `Supplied` — for a
    ///      code-less EVC, a reverting/out-of-stipend call, or returndata that is not a canonical `address[]`.
    ///      A canonical `address[]` return is `[offset = 0x20][length][element…]`, so this requires two full words,
    ///      an offset of exactly `0x20`, a length within {MAX_COLLATERALS}, and a payload that actually fits inside
    ///      the returndata. Elements are compared as full words, so an entry with dirty high bits simply never
    ///      matches — strictly under-classifying, consistent with the fail-open contract.
    function _isEnabledCollateral(address evc, address account, address vaultAddr) private view returns (bool) {
        if (evc.code.length == 0) return false;
        (bool ok, bytes memory data) =
            evc.staticcall{gas: EVC_PROBE_GAS}(abi.encodeCall(IEVC.getCollaterals, (account)));
        if (!ok || data.length < 64) return false;

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        if (offset != 0x20 || len > MAX_COLLATERALS || len > (data.length - 64) / 32) return false;

        uint256 target = uint256(uint160(vaultAddr));
        for (uint256 j = 0; j < len; j++) {
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
    ///      empty array for a short positionId.
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
