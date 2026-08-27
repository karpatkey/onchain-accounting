// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {InvalidArguments} from "src/errors.sol";

/// @notice Lido V3 `VaultHub` — the central registry for stVaults. Every view is keyed on the VAULT address.
/// @dev Only the four reads this adapter needs are declared. `vaultConnection` returns a static struct whose FIRST
///      word is the logical owner; it is read as a raw word rather than through a generated struct type, because the
///      struct's later fields are protocol-version-dependent and decoding them would make this adapter revert on a
///      layout change it does not care about.
interface IVaultHub {
    /// @notice Total value attributed to the vault. **Gross of unsettled fees** — see {_feeObligation}.
    function totalValue(address vault) external view returns (uint256);
    /// @notice The vault's stETH debt, denominated in stETH SHARES (not ether).
    function liabilityShares(address vault) external view returns (uint256);
    /// @notice `(sharesToBurn, feesToSettle)` — unsettled obligations owed to the Lido core protocol.
    function obligations(address vault) external view returns (uint256 sharesToBurn, uint256 feesToSettle);
}

/// @notice Lido core stETH — converts stETH SHARES to ether. A different exchange-rate object from anything
///         vault-local, which is why the Borrowed leg must route through it.
interface ILidoStETH {
    function getPooledEthByShares(uint256 shares) external view returns (uint256);
}

/// @title Lido stVaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter reporting an account's Lido V3 **stVault** positions across *any* vault on a chain.
///         Three gross legs per vault: `Staking` (the vault's total value, in the underlying), `Borrowed` (its stETH
///         liability) and `Fees` (unsettled Lido + node-operator fees, also a debt). The instance coordinate is the
///         **StakingVault** address widened to bytes32; the active set is governed on NAVCalculator via
///         `addMetaInstances`/`removeMetaInstances`. See ADR 0010.
///
/// @dev **FIXED-STIPEND PROBES: A STARVED READ DROPS THE INSTANCE SILENTLY, AND THAT IS ADJUDICATED, NOT
///      OVERLOOKED.** Every read of a LIDO contract goes through a fixed `PROBE_GAS` stipend -- four via
///      {StaticCallLib.probeWord} and `obligations()` via the hand-rolled two-word probe below, which forwards
///      the same constant. (Not "every NAV-bearing read": the three {_getAssetInfo} registry lookups are typed
///      calls with no cap, and an earlier revision of this block said otherwise.) The stipend forwards a fixed
///      `PROBE_GAS`. If a callee ever costs more than that -- a VaultHub upgrade, a longer proxy chain, a
///      replaced Dashboard; Lido V3 is pre-1.0 and all of these are upgradeable -- the probe fails, this adapter
///      absorbs its own out-of-gas and returns EMPTY. Because it absorbs it, `consumed` stays tiny against a
///      multi-megagas instance stipend, `GasStipendLib.exhausted` reads false, and `MetaBalanceAdapter`'s
///      {INAVCalculator.InstanceGasExhausted} DOES NOT FIRE FOR A STARVED LIDO READ. The position reports zero,
///      permanently and silently. (It can still fire for this adapter by another route -- the uncapped
///      {_getAssetInfo} calls propagate an out-of-gas rather than absorbing it -- so the accurate claim is about
///      the STIPENDED reads, not about the adapter as a whole. An earlier revision overstated it.)
///
///      **Why this deviates from `EulerVaultsMetaBalanceAdapter`, which uses `probeWordMetered` and REVERTS on
///      `starved`.** Direction. In Euler a starved debt read removes an instance's only leg while sibling vaults
///      keep reporting collateral in full -- an OVER-report, which nothing inside the instance can offset, so
///      only refusing to answer is safe. Here the credit leg drops with the debt legs, so starvation costs the
///      whole position and the direction is UNDER-report, which this repo tolerates. Adopting the metered route
///      would convert a bounded under-report into a reverted NAV read for the whole account whenever one Lido
///      contract becomes legitimately expensive -- trading a tolerated failure for an availability one.
///
///      **The residual is therefore silence, and silence is what is instrumented instead.**
///      `preflight_config.lido_stvaults_findings` eth_calls `totalValue`, `liabilityShares` and `obligations`
///      for every configured instance and raises an ERROR when any is unreadable, so a selector renamed by an
///      upgrade -- or a read grown past the stipend -- surfaces at the gate rather than as a vault that quietly
///      reports zero. That gate is the detection channel this adjudication depends on; if it is ever removed,
///      this decision must be revisited, not merely inherited.
///
/// @dev **THE OWNERSHIP PREDICATE IS `DEFAULT_ADMIN_ROLE`, AND THAT IS NARROWER THAN 'CONTROLS THE ETH'.**
///      A Dashboard splits duties: `FUND_ROLE` / `WITHDRAW_ROLE` / `MINT_ROLE` / `BURN_ROLE` are the operational
///      roles that actually move value, and they are routinely held by a DIFFERENT address from the admin.
///      Measured 2026-08-27 - on all three vaults inspected, the WITHDRAW_ROLE holder held NO admin role:
///        `0xd402937b...` admin `0xae6a126c...`, withdraw `0x9e14e047...`
///        `0x2df8CCb9...` admin `0x892bb7ee...`, withdraw `0xeb63cabd...`
///        `0x62e0D92c...` admin `0xc28317c7...`, withdraw `0x90f497ec...`
///      Keying on the admin is the DELIBERATE narrow choice: it is the ultimate owner (it can grant itself every
///      other role), and widening the accepted set would widen the double-count surface described below.
///
///      **CONSEQUENCE THAT MUST BE CHECKED BEFORE THE FIRST POSITION, NOT AFTER.** If a tracked Safe is wired as
///      the OPERATIONAL manager while `DEFAULT_ADMIN_ROLE` sits with a separate governance key or custodian, this
///      adapter reports NOTHING for that Safe - a silent under-report, position present and NAV zero. Verify the
///      Safe holds `DEFAULT_ADMIN_ROLE` on the Dashboard when a vault is first taken; if the shape turns out to be
///      operational-roles-only, this predicate needs revisiting rather than the config.
///
/// @dev **ORACLE-REPORT LAG, MEASURED AND DELIBERATELY NOT GATED.** Both `totalValue` and the two fee
///      components are written at oracle report, so between reports every figure this adapter reads LAGS reality.
///      Measured 2026-08-27 against Lido's own UI, which projects accrual forward off-chain:
///        FRESH  `0x2df8CCb9...` fee lag 0.0000 ETH (UI 0.0745 == chain 0.0745)
///        STALE  `0x62e0D92c...` fee lag 0.0122 ETH, value lag 0.0985 ETH
///        STALE  `0xd402937b...` fee lag 0.0898 ETH, value lag 0.6400 ETH
///        STALE  `0x5E25c5a4...` fee lag 0.1271 ETH, value lag 35.19 ETH - **7.46% of the vault**
///      That last row is the one to remember: the lag is bounded by accrual-since-report, not by anything small.
///      Note the middle row: a stale report does NOT make the fee read zero. `0xd402937b...` reads zero only
///      because its fees were zero at ITS last report, and generalising that one vault into a rule is a mistake
///      this file made once already.
///
///      `isReportFresh` is therefore NOT gated on, and the reason is structural rather than tolerant: the fee is a
///      FRACTION of the reward that generates it (a 5% node-operator fee plus the Lido share), so the un-reported
///      reward always exceeds the un-reported fee. A stale report consequently UNDER-reports net equity - measured
///      -0.086 and -0.55 ETH on the two stale vaults above - which is the safe direction. Gating the instance out
///      would trade that bounded under-report for a total one.
///
/// @dev **KNOWN, UNFIXABLE-ON-CHAIN OVER-REPORT: a Dashboard's `DEFAULT_ADMIN_ROLE` is not enumerable.** If TWO
///      tracked accounts both hold admin on one vault, both report the whole vault and the NAV double-counts it.
///      There is no on-chain fix — the role set cannot be read back — so the mitigation is governance: the MANAGER
///      curates the instance set so at most one tracked account controls each vault. This is not hypothetical:
///      measured on mainnet 2026-08-27, vault #10's Dashboard carries FIVE live `DEFAULT_ADMIN_ROLE` holders (every
///      other connected vault has exactly one, because the VaultFactory grants itself admin at creation and revokes
///      it in the same block). It is not a live risk for this repo today — no tracked account controls any vault —
///      but the shape is reachable in the protocol's real configuration.
///
///      **The instance is the VAULT, never its Dashboard.** A Dashboard is swappable by an ownership transfer while
///      the vault address is the protocol's own primary key, so keying on the Dashboard would silently re-point a
///      governed instance at a different position.
///
///      **Why a `Fees` debt leg exists at all, measured rather than assumed.** `VaultHub.totalValue` is GROSS of
///      unsettled fees: they reduce `maxLockableValue` and nothing else. Verified on mainnet 2026-08-27 across all
///      24 connected vaults — `totalValue - maxLockableValue == obligations().feesToSettle` held on 24 of 24, to the
///      wei. Reporting `totalValue` alone therefore OVER-reports by the outstanding fee obligation, which is the one
///      direction this repo does not tolerate.
contract LidoStVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice `DEFAULT_ADMIN_ROLE` in OpenZeppelin's `AccessControl` — the Dashboard role that denotes the owner.
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice The chain's Lido V3 VaultHub.
    IVaultHub public immutable VAULT_HUB;

    /// @notice The chain's stETH — the asset the `Borrowed` leg is denominated in, and the shares→ether rate source.
    address public immutable STETH;

    /// @notice The underlying staking asset a vault's value and fees are denominated in (the ETH sentinel on mainnet).
    address public immutable UNDERLYING_TOKEN;

    /// @param vaultHub_ The chain's Lido V3 `VaultHub`.
    /// @param steth_ The chain's stETH token.
    /// @param underlyingToken_ The underlying staking asset (the ETH sentinel on mainnet).
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vaultHub_, address steth_, address underlyingToken_, address navCalculator_)
        MetaBalanceAdapter(navCalculator_)
    {
        if (underlyingToken_ == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(vaultHub_, "vaultHub");
        AddressCheckLib.requireContract(steth_, "steth");
        // Aliasing any two of the three would mislabel legs (a Borrowed leg denominated in the underlying, or a
        // hub that is also the debt token). The artifact is immutable, so this is a deploy-time check or a redeploy.
        if (steth_ == underlyingToken_ || vaultHub_ == steth_ || vaultHub_ == underlyingToken_) {
            revert InvalidArguments();
        }
        VAULT_HUB = IVaultHub(vaultHub_);
        STETH = steth_;
        UNDERLYING_TOKEN = underlyingToken_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the StakingVault address. Order is load-bearing: connection, then ownership, then the
    ///      OBLIGATIONS, and only then the value legs — the Gearbox rule
    ///      (`GearboxV3CreditAccountsMetaBalanceAdapter._instancePositions`). If any debt read fails to produce a
    ///      value the WHOLE instance is dropped, because emitting a vault's assets without its offsetting debt
    ///      overstates equity, while dropping both merely under-reports.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        INAVCalculator.PositionBalance[] memory none = new INAVCalculator.PositionBalance[](0);
        if (assetFilter != address(0) && assetFilter != UNDERLYING_TOKEN && assetFilter != STETH) return none;

        address vault = _toAddress(instance);
        address owner = _connectionOwner(vault);
        // A never-connected or disconnected vault has no owner recorded here. Accepted under-report: an unconnected
        // vault's assets are not tracked by VaultHub at all, so there is nothing this adapter could report from it.
        if (owner == address(0)) return none;
        if (!_controls(owner, account)) return none;

        // OBLIGATIONS FIRST, all three fail-closed. `hasWord` rather than the raw success flag: a callee returning
        // ZERO bytes succeeds, and reading that as `debt == 0` is precisely the fail-open this ordering exists to
        // prevent (`StaticCallLib.safeUint` would do exactly that — it reports `ok` on an empty reply).
        (bool sharesOk, uint256 liabilityShares) =
            _word(address(VAULT_HUB), abi.encodeCall(IVaultHub.liabilityShares, (vault)));
        if (!sharesOk) return none;
        (bool feesOk, uint256 feeObligation) = _feeObligation(vault, owner, account);
        if (!feesOk) return none;

        // A debt that can be READ but not REPORTED is the same over-report as one that cannot be read — the vault's
        // value would be emitted with its stETH liability silently missing. Checked on REGISTRATION, deliberately
        // not on `assetFilter`: the filter is a per-asset slice, not an equity view.
        (INAVCalculator.Asset memory stethAsset, bool stethFound) = _getAssetInfo(STETH);
        uint256 stethDebt;
        if (liabilityShares > 0) {
            if (!stethFound) return none;
            (bool rateOk, uint256 converted) =
                _word(STETH, abi.encodeCall(ILidoStETH.getPooledEthByShares, (liabilityShares)));
            if (!rateOk) return none;
            stethDebt = converted;
        }

        (INAVCalculator.Asset memory underlying, bool underlyingFound) = _getAssetInfo(UNDERLYING_TOKEN);
        (bool valueOk, uint256 totalValue) = _word(address(VAULT_HUB), abi.encodeCall(IVaultHub.totalValue, (vault)));
        if (!valueOk) return none;
        // The underlying carries BOTH the Staking leg and the Fees leg, so an unregistered underlying would drop the
        // fee debt while the stETH debt still reported — dropping the instance keeps the legs together.
        if (!underlyingFound && (totalValue > 0 || feeObligation > 0)) return none;

        return _legs(underlying, stethAsset, totalValue, stethDebt, feeObligation, assetFilter, instance);
    }

    /// @dev Assembles the three legs, dropping zeros and applying `assetFilter` per leg. Split out of
    ///      {_instancePositions} to keep both frames inside the `via_ir` stack budget.
    function _legs(
        INAVCalculator.Asset memory underlying,
        INAVCalculator.Asset memory stethAsset,
        uint256 totalValue,
        uint256 stethDebt,
        uint256 feeObligation,
        address assetFilter,
        bytes32 instance
    ) private view returns (INAVCalculator.PositionBalance[] memory positions) {
        bytes memory pid = _instancePositionId(instance);
        bool wantUnderlying = assetFilter == address(0) || assetFilter == UNDERLYING_TOKEN;
        bool wantSteth = assetFilter == address(0) || assetFilter == STETH;

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](3);
        uint256 n;
        if (wantUnderlying && totalValue > 0) {
            temp[n++] = _leg(underlying, totalValue, false, pid, PositionKind.Staking);
        }
        if (wantSteth && stethDebt > 0) {
            temp[n++] = _leg(stethAsset, stethDebt, true, pid, PositionKind.Borrowed);
        }
        if (wantUnderlying && feeObligation > 0) {
            temp[n++] = _leg(underlying, feeObligation, true, pid, PositionKind.Fees);
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i = 0; i < n; i++) {
            positions[i] = temp[i];
        }
    }

    /// @notice The vault's logical owner per `VaultHub`, or `address(0)` if it is not connected.
    /// @dev **Never `vault.owner()`.** On connection the StakingVault's `Ownable` owner is transferred to the
    ///      VaultHub itself — measured on mainnet: `vault.owner()` returns the VaultHub address for every connected
    ///      vault — so an `owner()`-based predicate matches no account and the adapter would report nothing, silently.
    ///      The logical owner survives as the first word of `vaultConnection(vault)`.
    function _connectionOwner(address vault) private view returns (address owner) {
        (, owner) =
            StaticCallLib.safeAddr(address(VAULT_HUB), abi.encodeWithSignature("vaultConnection(address)", vault));
    }

    /// @dev `account` controls the vault when it IS the recorded owner, or when the owner is a Dashboard on which it
    ///      holds `DEFAULT_ADMIN_ROLE`. Fails closed: an unreadable role probe is "not controlled".
    function _controls(address owner, address account) private view returns (bool) {
        if (owner == account) return true;
        (bool ok, bool hasWord, uint256 word) = StaticCallLib.probeWord(
            owner, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, account)
        );
        return ok && hasWord && word == 1;
    }

    /// @notice Total unsettled fee obligation for the vault, in the underlying.
    /// @dev Two components, and they are DISTINCT rather than nested — measured on mainnet 2026-08-27: `accruedFee`
    ///      was ~2700x `feesToSettle` on the sampled vault, and `maxLockableValue` nets only `feesToSettle`.
    ///        * `obligations().feesToSettle` — owed to the Lido core protocol, read from the hub.
    ///        * the owner's `accruedFee()` — owed to the node operator. **PROBED ON BOTH PATHS, and an earlier
    ///          revision did not.** That revision skipped it whenever `account == owner`, reasoning that "there is
    ///          no Dashboard in the chain" — which the evidence refutes: `vaultConnection.owner` is a DASHBOARD on
    ///          every vault inspected on mainnet 2026-08-27 (the party Lido's UI calls "Vault Owner" is that
    ///          Dashboard's `DEFAULT_ADMIN`, not the recorded owner). So a tracked account that IS the recorded
    ///          owner would have had a real node-operator debt silently omitted — an OVER-report, the one direction
    ///          this adapter does not tolerate. Probing on both paths costs one staticcall and cannot over-report:
    ///          an owner that does not answer contributes zero, and one that answers with garbage adds a spurious
    ///          DEBT, which under-reports.
    ///      `sharesToBurn` is deliberately NOT added, for TWO independent reasons. It is a subset of
    ///      `liabilityShares` already carried by the Borrowed leg, so adding it double-counts; and per Lido's own
    ///      technical design the obligation categories it covers (health obligation, redemptions) are denominated
    ///      in stETH SHARES while `feesToSettle` is in ETH — so summing them would also be a UNIT error, not merely
    ///      a duplication.
    function _feeObligation(address vault, address owner, address account) private view returns (bool ok, uint256 fee) {
        (bool obOk, uint256 feesToSettle) =
            _secondWord(address(VAULT_HUB), abi.encodeCall(IVaultHub.obligations, (vault)));
        if (!obOk) return (false, 0);
        fee = feesToSettle;

        (bool accOk, uint256 accrued) = _word(owner, abi.encodeWithSignature("accruedFee()"));
        if (accOk) return (true, fee + accrued);
        // An owner that does not ANSWER `accruedFee()` carries no node-operator fee, so a missing reply is zero
        // rather than a failure — but ONLY when the account is the owner itself. On the ROLE path the owner is a
        // Dashboard by construction (we reached here through its `hasRole`), so a Dashboard that cannot answer its
        // own fee getter is a broken read on a DEBT, and the whole instance drops.
        if (owner == account) return (true, fee);
        return (false, 0);
    }

    /// @dev First returned word, requiring the callee actually produced one. `hasWord`, never the bare success flag.
    function _word(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        bool hasWord;
        (, hasWord, value) = StaticCallLib.probeWord(target, data);
        ok = hasWord;
    }

    /// @dev Second returned word of a two-word reply — `obligations()` returns `(sharesToBurn, feesToSettle)` and it
    ///      is the SECOND that this adapter needs. {StaticCallLib.probeWord} reads only the first, so this is the one
    ///      read that cannot route through it; the 64-byte output window is the whole difference.
    function _secondWord(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        uint256 size;
        bool success;
        // Routed through a local so the SYMBOLIC stipend reaches the assembly block — the
        // `AaveUmbrellaBalanceAdapter` idiom. A bare numeric literal here was the only one in `src/`, and it would
        // have silently kept the OLD ceiling on a DEBT read if `PROBE_GAS` were ever raised repo-wide to rescue an
        // honest-but-expensive call: the repo-wide fix would look applied while this instance kept dropping.
        uint256 probeGas = StaticCallLib.PROBE_GAS;
        assembly ("memory-safe") {
            let out := mload(0x40)
            mstore(out, 0)
            mstore(add(out, 0x20), 0)
            success := staticcall(probeGas, target, add(data, 0x20), mload(data), out, 0x40)
            size := returndatasize()
            value := mload(add(out, 0x20))
        }
        ok = success && size >= 64;
        if (!ok) value = 0;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32) internal view override returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = UNDERLYING_TOKEN;
        assets[1] = STETH;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `["stVault", "<underlying symbol> <vault address>"]`. Neither StakingVault nor Dashboard exposes a
    ///      `name()` — checked on mainnet — so unlike the ERC20-backed meta-adapters there is no tier-1 name read to
    ///      attempt, and the address IS the leaf. Display-only and must never revert.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        // Exactly one word, not `< 32`: `abi.decode` ignores trailing bytes, so a `< 32` guard would label a foreign
        // MULTI-word coordinate from its first word — a confident, wrong breadcrumb for a position never emitted here.
        if (pid.length != 32) return new string[](0);
        // Raw word, not `abi.decode(pid, (address))`, which REVERTS on dirty upper bits and would turn a malformed
        // coordinate into a revert of a view that must never revert.
        uint256 raw = abi.decode(pid, (uint256));
        if (raw >> 160 != 0) return _labels("stVault", "");
        address vault = address(uint160(raw));

        string memory leaf = Strings.toHexString(vault);
        (INAVCalculator.Asset memory underlying, bool found) = _getAssetInfo(UNDERLYING_TOKEN);
        if (found && bytes(underlying.symbol).length != 0) {
            leaf = string.concat(underlying.symbol, " ", leaf);
        }
        return _labels("stVault", leaf);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.LIDO;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Reuses `LIDO` rather than minting a Lido-V3 id: a stVault is a second Lido PRODUCT, not a second
    ///      protocol, and the family rule is "name the protocol, never the product". `protocolSubId` is what tells it
    ///      apart from `LIDO_WITHDRAWAL`. `ProtocolNames.forProtocolId` already has a `LIDO` branch, so this needs no
    ///      change there.
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.LIDO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.LIDO_STVAULTS;
    }
}
