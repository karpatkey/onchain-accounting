// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {FluidVaultLib} from "src/balances/MetaBalanceAdapters/FluidVaultLib.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Fluid Vaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's collateral + debt across *any* Fluid T1 vault — a
///         `Collateral` leg (supply) and a `Borrowed` leg (debt) per vault, aggregated over the account's NFT
///         positions. The instance coordinate is the vault address, widened to bytes32; the active vault set
///         lives on NAVCalculator (`addMetaInstances`/`removeMetaInstances`). The Fluid VaultResolver is the chain-level constant
///         pinned in the constructor. Identity is encoded as `abi.encode(address(vault))`. See ADR 0010.
/// @dev Read logic (tokens via `constantsView`, NFT aggregation) is delegated to `FluidVaultLib`, supporting
///      T1 vaults only — Smart vaults (T2/T3/T4) have a different `constantsView` layout and must not be
///      configured.
contract FluidVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Thrown when the pinned resolver does not implement `getVaultType`, which token resolution needs.
    error ResolverMissingVaultType(address resolver);

    /// @notice The Fluid VaultResolver (chain-level constant; used for NFT enumeration + per-NFT position reads).
    address public immutable VAULT_RESOLVER;

    /// @param vaultResolver_ The Fluid VaultResolver address.
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    /// @dev Also asserts the resolver actually implements `getVaultType`. Token resolution is gated on it, so a
    ///      resolver version without it would make every vault read as non-T1 and silently zero the whole
    ///      adapter on that chain — a failure that would otherwise surface only as "no positions". Probed with
    ///      `address(0)`, which a conforming resolver answers with 0 rather than reverting.
    constructor(address vaultResolver_, address navCalculator_) MetaBalanceAdapter(navCalculator_) {
        AddressCheckLib.requireContract(vaultResolver_, "VaultResolver");
        if (!FluidVaultLib.supportsVaultType(vaultResolver_)) revert ResolverMissingVaultType(vaultResolver_);
        VAULT_RESOLVER = vaultResolver_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the T1 vault address. Emits a `Collateral` leg (supply token) and a `Borrowed` leg
    ///      (debt token), dropping zeros and unregistered assets, respecting `assetFilter`.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        address vault = _toAddress(instance);
        (address collToken, address debtToken) = FluidVaultLib.tokens(vault, VAULT_RESOLVER);
        // Gated (non-T1) vault, or a vault missing a token side: no complete pair means the legs cannot be
        // reported correctly, so skip `aggregate`'s scan of every Fluid NFT the account holds. `||`, not `&&`
        // — a half-zero pair would otherwise emit an unoffset Collateral leg while the Borrowed leg was
        // dropped by `_eligible(address(0))`.
        // The unregistered-debt form of the same shape is closed just below, by the `debtRegistered` check.
        if (collToken == address(0) || debtToken == address(0)) {
            return new INAVCalculator.PositionBalance[](0);
        }
        (uint256 collateral, uint256 debt) = FluidVaultLib.aggregate(vault, VAULT_RESOLVER, account);

        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;

        // A debt this adapter cannot report must never leave its collateral standing alone: the position would
        // be counted as pure credit, overstated by the whole borrow. Registration is checked WITHOUT the
        // assetFilter, and that asymmetry is deliberate — the two cases are different in kind:
        //
        //   - Unregistered debt token — nobody can price that debt, on any path, so emitting the collateral
        //     alone states a figure no consumer is able to offset. Dropping the whole position is the safe
        //     direction, and that is what the guard below does.
        //   - Excluded by `assetFilter` — the debt is perfectly priceable and merely outside the caller's query.
        //     A per-asset read is a PROJECTION, not a sub-portfolio valuation: ask for asset X and you get the
        //     legs denominated in X. Omitting the borrow leg there is the requested answer, not a failed report.
        //
        // Scope, so this is not mistaken for a live NAV hazard: no NAV figure is ever computed with a filter.
        // `getAccountNav`, `getAccountNavForAdapters` and `getAccountNavVerbose` take no filter and reach
        // `PriceFeedLib.computeNav` with `address(0)`. The only non-zero-filter entrypoints are
        // `NAVCalculator.getAccountPositionsForAsset` / `…ForAssetVerbose`, which return `Position[]`. The
        // residual risk is a CONSUMER summing a filtered position list as if it were a net position — a
        // contract stated on those entrypoints, not something this adapter fixes by hiding a requested leg.
        if (debt > 0) {
            (, bool debtRegistered) = _getAssetInfo(debtToken);
            if (!debtRegistered) return new INAVCalculator.PositionBalance[](0);
        }

        if (collateral > 0) {
            (INAVCalculator.Asset memory a, bool ok) = _eligible(collToken, assetFilter);
            if (ok) {
                temp[count++] = _leg(a, collateral, false, pid, PositionKind.Collateral);
            }
        }
        if (debt > 0) {
            (INAVCalculator.Asset memory a, bool ok) = _eligible(debtToken, assetFilter);
            if (ok) temp[count++] = _leg(a, debt, true, pid, PositionKind.Borrowed);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        (address collToken, address debtToken) = FluidVaultLib.tokens(_toAddress(instance), VAULT_RESOLVER);
        // Gated (non-T1) vault, or a vault missing a token side: report no underlying assets rather than
        // publishing address(0) as one. `||` for the same reason as in `_instancePositions`.
        if (collToken == address(0) || debtToken == address(0)) {
            return new address[](0);
        }
        if (collToken == debtToken) {
            assets = new address[](1);
            assets[0] = collToken;
        } else {
            assets = new address[](2);
            assets[0] = collToken;
            assets[1] = debtToken;
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Vault", "<collateral>/<debt> #<vaultId>"]` — e.g. `["Vault", "wstETH/USDC #4"]`. A Fluid
    ///      vault is NOT an ERC20 (`name()`/`symbol()` revert), so the pair is the only human-readable property
    ///      available, but the pair alone does NOT identify a vault: Fluid runs several isolated T1 vaults over
    ///      the same pair (mainnet: 101 T1 vaults, 91 distinct pairs — every configured vault has a live
    ///      same-pair twin), so Fluid's own per-vault id is appended. Leaf is "" (collapsing to `["Vault"]`) for
    ///      a non-T1 or unreadable vault. Returns an empty array for a malformed positionId (see {_pidAddress}).
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        (address vault, bool ok) = _pidAddress(pid);
        if (!ok) return new string[](0);
        // External self-call so a revert anywhere in the type-check/constantsView/symbol chain fails open to the
        // category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.vaultPairSymbols{gas: LABEL_LEAF_GAS}(vault) returns (string memory leaf) {
            return _labels("Vault", leaf);
        } catch {
            return _labels("Vault", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the vault's label leaf,
    ///         `"<collateral>/<debt> #<vaultId>"` — e.g. `"wstETH/USDC #4"`.
    /// @dev Symbols prefer the NAV's registered-asset record, which already resolves `NATIVE_ADDRESS` to the
    ///      chain's native symbol — several Fluid T1 vaults use the ERC-7528 native sentinel as one side, and it
    ///      has no `symbol()` to call. Falls back to a direct ERC20 read for a token that is not registered.
    ///      The trailing id is required for uniqueness: several T1 vaults share one collateral/debt pair.
    /// @param vault The T1 vault address.
    /// @return The label leaf, or "" if the vault is not a readable T1 vault.
    function vaultPairSymbols(address vault) external view returns (string memory) {
        (address collToken, address debtToken, uint256 vaultId) = FluidVaultLib.vaultInfo(vault, VAULT_RESOLVER);
        if (collToken == address(0) || debtToken == address(0)) return "";
        // ONE registry fetch, shared by both sides. The fetch pulls the entire registered-asset array across the
        // call boundary, so its cost is O(registered assets) — a Fluid breadcrumb is therefore coupled to how
        // many assets happen to be registered protocol-wide, and registering an unrelated asset is a routine
        // config TX. Fetching once per leaf rather than once per side is what keeps that coupling linear instead
        // of quadratic; see {LABEL_LEAF_GAS} for the headroom this leaf is sized against.
        INAVCalculator.Asset[] memory registry = NAV_CALCULATOR.getRegisteredAssets();
        return string.concat(
            _symbolFrom(registry, collToken), "/", _symbolFrom(registry, debtToken), " #", Strings.toString(vaultId)
        );
    }

    /// @notice The registered symbol for `token`, falling back to its on-chain `symbol()` and then to "?".
    /// @dev Takes the registry the caller already holds rather than fetching its own, which is what keeps the
    ///      leaf to a single fetch regardless of how many sides it labels.
    ///
    ///      Registry-first, deliberately, rather than `MetaBalanceAdapter._joinTokenSymbols`: that helper reads
    ///      `symbol()` directly and so cannot resolve the ERC-7528 native sentinel, which several Fluid T1 vaults
    ///      use as one side and which has no `symbol()` to call. The registry record already carries the chain's
    ///      native symbol. It also means a *registered* token's symbol costs no external call into that token.
    ///      Falls back to "?" to match `_joinTokenSymbols` and the Morpho markets adapter, so an unreadable side
    ///      renders "?/USDC" rather than "/USDC".
    function _symbolFrom(INAVCalculator.Asset[] memory registry, address token) private view returns (string memory) {
        (INAVCalculator.Asset memory info, bool found) = RegisteredAssetLib.find(registry, token);
        if (found && bytes(info.symbol).length > 0) return info.symbol;
        return LabelLib.symbol(token, "?");
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.FLUID;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.FLUID;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.FLUID_VAULTS;
    }
}
