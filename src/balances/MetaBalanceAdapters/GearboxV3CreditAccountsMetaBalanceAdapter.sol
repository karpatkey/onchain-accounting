// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20MetaView} from "src/balances/LabelLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Gearbox V3 Credit Accounts Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **borrow-side** Gearbox V3 positions — the collateral
///         basket and the debt held in its **Credit Accounts** — complementing `GearboxV3MarketsMetaBalanceAdapter`,
///         which covers only the passive ERC4626 *supply* side (pool LPs). The instance coordinate is the **credit
///         account address** (widened to bytes32); the active set lives on NAVCalculator
///         (`addMetaInstances`/`removeMetaInstances`, MANAGER-gated). See ADR 0010.
/// @dev **Why the credit account is the instance (not the CreditManager).** Gearbox V3 has no on-chain
///      borrower→creditAccount lookup — `ICreditManagerV3` exposes only the reverse
///      (`creditAccountInfo(ca).borrower`) plus `creditAccounts()` returning *every* open account. Keying on the
///      CreditManager would therefore force an unbounded scan of all accounts inside the NAV read (an OOG there is
///      NOT caught by NAVCalculator's try/catch, so it would brick the account's whole scan). Keying on the credit
///      account instead makes discovery a governance concern: the fund's own credit accounts are curated as the
///      instance set (exactly like Morpho markets or Aave instances), and each read is O(#instances). Per instance:
///        - the adapter resolves the CreditManager from the credit account (`ICreditAccountV3.creditManager()`) and
///          confirms `creditAccountInfo(ca).borrower == account` — so a queried sub-account only ever sees the credit
///          accounts it actually owns (a closed/liquidated CA reads `borrower == address(0)` ⇒ empty);
///        - it emits one **Borrowed** leg (`isDebt = true`) for the total owed in the pool's underlying
///          (`debt + accruedInterest + accruedFees` from `calcDebtAndCollateral(ca, DEBT_ONLY)`), and one
///          **Collateral** leg per enabled token (`balanceOf(ca)`), so NAV nets the basket against the debt into the
///          trader's equity — the same double-entry the Aave/Spark/Euler adapters use.
///      All legs of a credit account share its `positionId` (`abi.encode(creditAccount)`) and are distinguished by
///      `positionKind` + `balanceAsset`; `positionInstanceId` is `bytes32(0)` (the credit account *is* the instance,
///      so its identity lives in `positionId`, not in the ephemeral field).
///
///      **Never over-reports (assisted-family spirit, on-chain here).** If the debt read fails for a credit account,
///      the WHOLE account is dropped (empty) rather than emitting collateral with no offsetting debt — reporting
///      collateral alone would overstate equity. Collateral tokens that are unregistered/unpriced in NAVCalculator
///      are likewise dropped while the full debt is still counted, so the position can only **under**-report.
///
///      **Valuation note.** Collateral is valued at instantaneous on-chain token balances priced by NAVCalculator's
///      external oracles (the basket includes leveraged positions) — not a manipulation-resistant mark; acceptable
///      under the asynchronous NAV-consumer model (see ADR 0017), same as the AMM-LP adapters.
contract GearboxV3CreditAccountsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Longest credit-manager name accepted as a label leaf; anything longer degrades to the underlying
    ///         symbol fallback. Far above any real Gearbox credit-manager name.
    /// @dev Currently IMPLIED by {MAX_RETURN_BYTES} rather than independently enforced: past the size check below,
    ///      `size <= MAX_RETURN_BYTES`, and `len <= size - 64` then forces `len <= 256` on its own — so the
    ///      `len > MAX_LABEL_BYTES` clause cannot fire today. It is kept because the two constants express one
    ///      invariant, `MAX_RETURN_BYTES == 64 + MAX_LABEL_BYTES`, and they must move together: that equality is
    ///      also what guarantees there is no off-by-one rejecting a *valid* maximum-length label (a canonical
    ///      256-byte string encodes to exactly 320 bytes). Raise one without the other and the clause stops being
    ///      redundant — which is precisely when you want it already there.
    uint256 private constant MAX_LABEL_BYTES = 256;

    /// @notice Hard ceiling on returndata **copied into this contract's memory** for a label probe: the two ABI head
    ///         words plus {MAX_LABEL_BYTES} of payload (64 + 256 = 320). Written as a literal because inline assembly
    ///         accepts only direct number constants.
    /// @dev This, not the gas stipend, is what bounds the *caller's* cost. A stipend alone does not: a hostile credit
    ///      manager can `return(0, 200_000)` — its own memory expansion for ~200 KB costs it well under
    ///      {LABEL_READ_GAS} — while this contract pays `returndatacopy` plus its own monotonically growing memory,
    ///      charged outside the stipend and quadratic in total. Passing an explicit output size to `staticcall` copies
    ///      at most this many bytes whatever the callee returns, so the cost is flat. `returndatasize()` still reports
    ///      the true size, so an oversized reply is rejected rather than silently truncated.
    uint256 private constant MAX_RETURN_BYTES = 320;

    /// @notice Gas stipend for a label probe. Generous for a real (even proxied) metadata read, and it bounds the
    ///         callee's own execution — including a write-protection abort, which consumes everything forwarded.
    /// @dev Necessary but NOT sufficient on its own; see {MAX_RETURN_BYTES} for the caller-side bound.
    uint256 private constant LABEL_READ_GAS = 100_000;

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the credit account address. Returns an empty array (never reverts) when: the credit
    ///      manager can't be resolved, the account is not the credit account's borrower, or the debt can't be valued
    ///      (whole-account drop, so collateral is never reported without its offsetting debt).
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address ca = _toAddress(instance);

        address cm = _creditManagerOf(ca);
        if (cm == address(0)) return new INAVCalculator.PositionBalance[](0);

        (uint256 enabledMask, address borrower) = _accountInfo(cm, ca);
        if (borrower != account) return new INAVCalculator.PositionBalance[](0);

        // Value the obligation FIRST. If it can't be read, drop the whole credit account — emitting collateral without
        // its offsetting debt would overstate equity (over-report). A successful read with debt == 0 is fine (a
        // pure-long account: collateral, no borrow).
        (bool debtOk, uint256 debt) = _debtOf(cm, ca);
        if (!debtOk) return new INAVCalculator.PositionBalance[](0);

        // Same reasoning one step further: a debt that is READ but cannot be REPORTED — `underlying()`
        // unreadable, or the underlying not a registered NAV asset — is dropped by `_appendBorrow` while the
        // collateral legs below are still emitted, which overstates equity exactly as an unreadable debt would.
        // Checked on registration only, not the assetFilter: a filtered view showing collateral while hiding an
        // unreportable debt over-reports the same way.
        if (debt > 0 && !_debtReportable(cm)) return new INAVCalculator.PositionBalance[](0);

        // Upper bound: one Collateral leg per enabled token + one Borrowed leg. Over-allocate and resize (a tighter
        // count would mean re-reading balances/registry twice). `enabledMask` is bounded by the manager's allowed-token
        // count, and only set bits are visited.
        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](_popcount(enabledMask) + 1);
        uint256 n;
        n = _appendCollateral(ca, cm, enabledMask, assetFilter, temp, n);
        n = _appendBorrow(ca, cm, debt, assetFilter, temp, n);

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @dev Appends one `Collateral` leg per enabled token the credit account holds a balance of. Unregistered or
    ///      asset-filtered-out tokens, and zero balances, are skipped (the account can only under-report). Iterates
    ///      only the set bits of `mask`; a per-token read that reverts skips that token. Extracted from
    ///      `_instancePositions` to keep its frame under the via_ir stack limit.
    function _appendCollateral(
        address ca,
        address cm,
        uint256 mask,
        address assetFilter,
        INAVCalculator.PositionBalance[] memory temp,
        uint256 n
    ) private view returns (uint256) {
        while (mask != 0) {
            uint256 bit = mask & (~mask + 1); // lowest set bit
            mask ^= bit;

            address token;
            try ICreditManagerV3(cm).getTokenByMask(bit) returns (address t) {
                token = t;
            } catch {
                continue;
            }
            if (token == address(0)) continue;
            if (assetFilter != address(0) && assetFilter != token) continue;

            (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(token);
            if (!found) continue;

            uint256 bal;
            try IERC20(token).balanceOf(ca) returns (uint256 b) {
                bal = b;
            } catch {
                continue;
            }
            if (bal == 0) continue;

            temp[n++] = _leg(info, bal, false, abi.encode(ca), PositionKind.Collateral);
        }
        return n;
    }

    /// @notice True iff a non-zero debt on `cm` can actually be emitted as a leg: its `underlying()` is readable
    ///         and that asset is registered on the NAV.
    /// @dev Deliberately ignores `assetFilter`, unlike {_appendBorrow}: a filtered view showing collateral
    ///      while hiding an unreportable debt over-reports just as an unfiltered one would.
    function _debtReportable(address cm) private view returns (bool) {
        address underlying;
        try ICreditManagerV3(cm).underlying() returns (address u) {
            underlying = u;
        } catch {
            return false;
        }
        (, bool found) = _getAssetInfo(underlying);
        return found;
    }

    /// @dev Appends the single `Borrowed` leg (the total owed in the pool's underlying) if `debt > 0` and the
    ///      underlying is registered (and matches `assetFilter`, if set). Extracted to relieve stack.
    function _appendBorrow(
        address ca,
        address cm,
        uint256 debt,
        address assetFilter,
        INAVCalculator.PositionBalance[] memory temp,
        uint256 n
    ) private view returns (uint256) {
        if (debt == 0) return n;

        address underlying;
        try ICreditManagerV3(cm).underlying() returns (address u) {
            underlying = u;
        } catch {
            return n;
        }
        if (assetFilter != address(0) && assetFilter != underlying) return n;

        (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(underlying);
        if (!found) return n;

        temp[n++] = _leg(info, debt, true, abi.encode(ca), PositionKind.Borrowed);
        return n;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev The credit account's assets: the pool underlying (debt) + currently-enabled collateral tokens. Used by the
    ///      non-NAV `underlyingAssetsSupported` view; returns an empty array if the credit manager can't be resolved
    ///      or the pool `underlying()` read reverts.
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        address ca = _toAddress(instance);
        address cm = _creditManagerOf(ca);
        if (cm == address(0)) return new address[](0);

        address underlying;
        try ICreditManagerV3(cm).underlying() returns (address u) {
            underlying = u;
        } catch {
            return new address[](0);
        }

        (uint256 mask,) = _accountInfo(cm, ca);
        assets = new address[](1 + _popcount(mask));
        assets[0] = underlying;
        uint256 k = 1;
        while (mask != 0) {
            uint256 bit = mask & (~mask + 1);
            mask ^= bit;
            try ICreditManagerV3(cm).getTokenByMask(bit) returns (address t) {
                assets[k++] = t;
            } catch {}
        }
        if (k < assets.length) {
            address[] memory trimmed = new address[](k);
            for (uint256 i = 0; i < k; i++) {
                trimmed[i] = assets[i];
            }
            assets = trimmed;
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Credit Account", <leaf>]` where the leaf is the credit manager's `name()` (e.g.
    ///      "Trade WETH Tier 1"). If `name()` is missing/empty, falls back to the underlying asset symbol
    ///      (e.g. "USDC") via `underlying()` — the same accessor the position read uses. Leaf is "" (→ just
    ///      `["Credit Account"]`) only if both are unreadable. Returns an empty array for a short positionId.
    ///
    ///      **All THREE reads** go through the raw-call readers below rather than `try`/`catch`. `_creditManagerOf`
    ///      guards the *credit account's* codesize but returns whatever `creditManager()` answered, so `cm` itself may
    ///      be code-less — a high-level call to it reverts via `extcodesize` in this frame, past any `catch`. And a
    ///      `cm` that answers any of these selectors successfully but with undecodable returndata reverts in this
    ///      frame too. All of it would take down a display-only view; see {_safeStringRead} / {_safeAddressRead}.
    ///
    ///      The tier-2 `symbol()` hop matters as much as the first two, and is easy to overlook: the chain is only as
    ///      fail-open as its last link, and `u` is *manager-chosen* (see the inline note below). Hardening `name()`
    ///      and `underlying()` while leaving the symbol read on `try`/`catch` would have left the whole function
    ///      revert-able and gas-unbounded through a one-line gap.
    ///
    ///      Note the deliberate asymmetry inside this file: `underlying()` is read through {_safeAddressRead} here,
    ///      but still through `try`/`catch` on the NAV path (`_debtReportable`, `_instanceAssets`, `_appendBorrow`).
    ///      Those callers already treat a failed read as "drop the leg", so their failure mode is a caught revert,
    ///      not an over-report — and putting a gas cap on a NAV-path read is a separate decision from a label fix.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address ca = abi.decode(pid, (address));
        address cm = _creditManagerOf(ca);
        if (cm == address(0)) return _labels("Credit Account", "");

        string memory leaf = _safeStringRead(cm, ICreditManagerV3.name.selector);

        if (bytes(leaf).length == 0) {
            address u = _safeAddressRead(cm, ICreditManagerV3.underlying.selector);
            // NOT `LabelLib.symbol`: `u` is whatever the (already untrusted) credit manager returned from
            // `underlying()`, and `_safeAddressRead` masks that word rather than rejecting it — so this hop's
            // target is fully manager-chosen. LabelLib still reads through `try`/`catch`, which leaves both the
            // decode-failure revert and an uncapped gas burn on the very last hop of the chain this function
            // exists to harden. Read it with the same guarded reader as the two hops above.
            if (u != address(0)) leaf = _safeStringRead(u, IERC20MetaView.symbol.selector);
        }
        return _labels("Credit Account", leaf);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.GEARBOX;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.GEARBOX_V3;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.GEARBOX_V3_CREDIT_ACCOUNTS;
    }

    //
    // Internal — Gearbox reads (all try/catch'd by callers or here, so a non-Gearbox/stale instance degrades to empty)
    //

    /// @dev Resolves the CreditManager that owns a credit account; `address(0)` if `ca` is not a Gearbox credit
    ///      account (the `creditManager()` call reverts).
    function _creditManagerOf(address ca) private view returns (address cm) {
        // Codesize guard: a high-level call to a codeless address reverts via extcodesize, which try/catch does
        // NOT catch — keep this fail-open (it backs both the position read and the verbose-only label).
        if (ca.code.length == 0) return address(0);
        try ICreditAccountV3(ca).creditManager() returns (address m) {
            cm = m;
        } catch {
            cm = address(0);
        }
    }

    /// @dev Reads `(enabledTokensMask, borrower)` from the manager's `creditAccountInfo`. `(0, address(0))` on revert
    ///      — a zero borrower fails the ownership check in the caller, so the account is dropped.
    function _accountInfo(address cm, address ca) private view returns (uint256 enabledTokensMask, address borrower) {
        try ICreditManagerV3(cm).creditAccountInfo(ca) returns (
            uint256, uint256, uint128, uint128, uint256 mask, uint16, uint64, address b
        ) {
            enabledTokensMask = mask;
            borrower = b;
        } catch {
            return (0, address(0));
        }
    }

    /// @dev Total debt owed (principal + accrued interest + accrued fees) in the pool underlying, via
    ///      `calcDebtAndCollateral(ca, DEBT_ONLY)` (no price reads, so it does not need the oracle). Returns
    ///      `ok = false` on revert so the caller drops the whole credit account rather than reporting collateral with
    ///      no offsetting debt.
    function _debtOf(address cm, address ca) private view returns (bool ok, uint256 debt) {
        try ICreditManagerV3(cm).calcDebtAndCollateral(ca, CollateralCalcTask.DEBT_ONLY) returns (
            CollateralDebtData memory cdd
        ) {
            return (true, cdd.debt + cdd.accruedInterest + cdd.accruedFees);
        } catch {
            return (false, 0);
        }
    }

    //
    // Internal — fail-open label reads (display-only; must never revert)
    //

    /// @notice Fail-open read of a parameterless, `address`-returning view. `address(0)` on every failure path.
    /// @dev `positionLabels` is display-only and MUST NOT revert, and a `try`/`catch` around this call would not make
    ///      that true. Three distinct failure classes, only one of which `catch` handles:
    ///        1. `target` has **no code** — a high-level call reverts via Solidity's `extcodesize` precheck *before*
    ///           the call, in this frame, so `catch` never sees it;
    ///        2. the call **reverts** — the one class `catch` does cover;
    ///        3. the call **succeeds but the returndata is not decodable as an `address`** — fewer than 32 bytes, or
    ///           32 bytes with dirty upper bits. Solidity's decoder runs in THIS frame after the call returned, so
    ///           its revert propagates straight past `catch`.
    ///      A raw `staticcall` turns class 2 into a `false` return; the codesize guard covers class 1; the explicit
    ///      `returndatasize()` check plus a `uint160` mask (rather than `abi.decode(…, (address))`, which validates
    ///      the upper bits and reverts) covers class 3. Output is written into scratch space with an explicit size, so
    ///      nothing is copied beyond one word however much the callee returns.
    function _safeAddressRead(address target, bytes4 selector) private view returns (address) {
        if (target.code.length == 0) return address(0);
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            // Scratch space (0x00–0x3f): selector in the first word, the single return word in the second.
            // `bytes4` is left-aligned, so the 4 bytes at 0x00 are exactly the selector.
            mstore(0x00, selector)
            ok := staticcall(LABEL_READ_GAS, target, 0x00, 0x04, 0x20, 0x20)
            size := returndatasize()
            word := mload(0x20)
        }
        if (!ok || size < 32) return address(0);
        return address(uint160(word));
    }

    /// @notice Fail-open read of a parameterless, `string`-returning view. "" on every failure path.
    /// @dev Same three classes as {_safeAddressRead}; class 3 is the one a `try`/`catch` silently misses, and the
    ///      shapes are not hypothetical — all reproduced on solc 0.8.34: empty returndata (an ERC-1967 proxy whose
    ///      implementation slot points at a code-less address, so the `delegatecall` succeeds returning nothing), a
    ///      `bytes32` name (MKR-era style), a bare offset word with no length word, a nonsense offset, and an absurd
    ///      declared length.
    ///
    ///      So the ABI head is validated *before* decoding. A canonical `string` return is
    ///      `[offset = 0x20][length][payload…]`: require two full words, an offset of exactly `0x20`, a non-zero
    ///      length within {MAX_LABEL_BYTES}, and a payload that fits inside the returndata. Bounding on the raw
    ///      declared length is sufficient — a memory-source `abi.decode` bounds on that length, not on `ceil32` of it.
    ///
    ///      The probe is gas-capped and output-capped, and both are load-bearing rather than defensive: a raw
    ///      `staticcall` assigning `(bool, bytes memory)` always `returndatacopy`s the response *including a revert
    ///      payload*, which the parameterless `catch {}` this replaced never did. Uncapped, this rewrite would be
    ///      strictly worse than the old `try`/`catch` against a hostile credit manager. See {MAX_RETURN_BYTES}.
    function _safeStringRead(address target, bytes4 selector) private view returns (string memory) {
        if (target.code.length == 0) return "";

        bytes memory data = new bytes(MAX_RETURN_BYTES);
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            ok := staticcall(LABEL_READ_GAS, target, 0x00, 0x04, add(data, 0x20), MAX_RETURN_BYTES)
            size := returndatasize()
        }
        // A `string` return needs at least the offset and length words. An oversized reply is rejected outright rather
        // than truncated: a canonical reply for a <= MAX_LABEL_BYTES string never exceeds MAX_RETURN_BYTES, so
        // anything larger is malformed or hostile.
        if (!ok || size < 64 || size > MAX_RETURN_BYTES) return "";

        // Shrink to what was actually returned so the payload bound below — and `abi.decode`'s own bounds check — are
        // exact. Only ever shrinks: `size <= MAX_RETURN_BYTES` is the allocated length.
        assembly ("memory-safe") {
            mstore(data, size)
        }

        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            len := mload(add(data, 0x40))
        }
        if (offset != 0x20 || len == 0 || len > MAX_LABEL_BYTES || len > size - 64) return "";

        return abi.decode(data, (string));
    }

    /// @dev Population count (number of set bits) of `x`, via Kernighan's algorithm. Used to size the per-account leg
    ///      buffer to the enabled-token count.
    function _popcount(uint256 x) private pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }
}

/// @notice Minimal interface for a Gearbox V3 credit account (the isolated per-position contract).
interface ICreditAccountV3 {
    /// @notice The CreditManager that opened and manages this credit account.
    function creditManager() external view returns (address);
}

/// @notice Gearbox V3 `CollateralCalcTask` — selects how much of a credit account's collateral/debt is computed.
///         `DEBT_ONLY` returns the debt side (debt + accrued interest + fees) without pricing collateral.
enum CollateralCalcTask {
    GENERIC_PARAMS,
    DEBT_ONLY,
    FULL_COLLATERAL_CHECK_LAZY,
    DEBT_COLLATERAL,
    DEBT_COLLATERAL_SAFE_PRICES
}

/// @notice Gearbox V3 `CollateralDebtData` (exact field order — `calcDebtAndCollateral`'s ABI-decoded return).
struct CollateralDebtData {
    uint256 debt;
    uint256 cumulativeIndexNow;
    uint256 cumulativeIndexLastUpdate;
    uint128 cumulativeQuotaInterest;
    uint256 accruedInterest;
    uint256 accruedFees;
    uint256 totalDebtUSD;
    uint256 totalValue;
    uint256 totalValueUSD;
    uint256 twvUSD;
    uint256 enabledTokensMask;
    uint256 quotedTokensMask;
    address[] quotedTokens;
    address _poolQuotaKeeper;
}

/// @notice Minimal interface for a Gearbox V3 CreditManager (the borrow-side reads this adapter needs).
interface ICreditManagerV3 {
    /// @notice Per-credit-account record. Returns, in order: debt, cumulativeIndexLastUpdate, cumulativeQuotaInterest,
    ///         quotaFees, enabledTokensMask, flags, lastDebtUpdate, borrower.
    function creditAccountInfo(address creditAccount)
        external
        view
        returns (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint128 cumulativeQuotaInterest,
            uint128 quotaFees,
            uint256 enabledTokensMask,
            uint16 flags,
            uint64 lastDebtUpdate,
            address borrower
        );

    /// @notice The pool's underlying asset — the token debt is denominated in.
    function underlying() external view returns (address);

    /// @notice The collateral token at a given single-bit token mask.
    function getTokenByMask(uint256 tokenMask) external view returns (address token);

    /// @notice Computes a credit account's debt/collateral data for the given task.
    function calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        external
        view
        returns (CollateralDebtData memory cdd);

    /// @notice Human-readable credit manager name (e.g. "Gearbox USDC v3").
    function name() external view returns (string memory);
}
