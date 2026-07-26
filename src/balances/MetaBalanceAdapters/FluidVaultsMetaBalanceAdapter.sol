// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {FluidVaultLib} from "src/balances/MetaBalanceAdapters/FluidVaultLib.sol";
import {LabelLib} from "src/balances/LabelLib.sol";

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
    /// @notice The Fluid VaultResolver (chain-level constant; used for NFT enumeration + per-NFT position reads).
    address public immutable VAULT_RESOLVER;

    /// @param vaultResolver_ The Fluid VaultResolver address.
    /// @param protocolName_ Human-readable protocol name (e.g. "Fluid").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vaultResolver_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        AddressCheckLib.requireContract(vaultResolver_, "VaultResolver");
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
        (uint256 collateral, uint256 debt) = FluidVaultLib.aggregate(vault, VAULT_RESOLVER, account);

        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](2);
        uint256 count;

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
    /// @dev Returns `["Vault", "<collateral>/<debt>"]` — e.g. `["Vault", "wstETH/USDC"]` — mirroring the
    ///      Morpho markets adapter, since a Fluid vault is likewise identified by its isolated token pair. A
    ///      Fluid vault is NOT an ERC20 (`name()`/`symbol()` revert), so the pair is the only on-chain
    ///      distinguishing property. Leaf is "" (collapsing to `["Vault"]`) for a non-T1 or unreadable vault.
    ///      Returns an empty array for a short positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address vault = abi.decode(pid, (address));
        // External self-call so a revert anywhere in the type-check/constantsView/symbol chain fails open to the
        // category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.vaultPairSymbols(vault) returns (string memory leaf) {
            return _labels("Vault", leaf);
        } catch {
            return _labels("Vault", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the vault's
    ///         "<collateral>/<debt>" token symbols.
    /// @dev Prefers the NAV's registered-asset symbol, which already resolves `NATIVE_ADDRESS` to the chain's
    ///      native symbol — several Fluid T1 vaults use the ERC-7528 native sentinel as one side, and it has no
    ///      `symbol()` to call. Falls back to a direct ERC20 read for a token that is not registered.
    /// @param vault The T1 vault address.
    /// @return The pair label, or "" if the vault is not a readable T1 vault.
    function vaultPairSymbols(address vault) external view returns (string memory) {
        (address collToken, address debtToken) = FluidVaultLib.tokens(vault, VAULT_RESOLVER);
        if (collToken == address(0) && debtToken == address(0)) return "";
        return string.concat(_assetSymbol(collToken), "/", _assetSymbol(debtToken));
    }

    /// @notice Symbol for `token`: the NAV registry's (native-aware), else a direct ERC20 `symbol()`, else "".
    function _assetSymbol(address token) internal view returns (string memory) {
        (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(token);
        if (found && bytes(info.symbol).length > 0) return info.symbol;
        return LabelLib.symbol(token, "");
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
