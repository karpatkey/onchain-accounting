// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {FluidVaultLib} from "src/balances/MetaBalanceAdapters/FluidVaultLib.sol";

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
        (address collToken, address debtToken) = FluidVaultLib.tokens(vault);
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
        (address collToken, address debtToken) = FluidVaultLib.tokens(_toAddress(instance));
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
    /// @dev Returns `["Vault", <leaf>]` where the leaf is the vault's ERC20 name ("" if unreadable). Returns an
    ///      empty array for a short positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Vault", false);
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
