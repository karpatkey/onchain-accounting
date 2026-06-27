// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal Euler V2 vault accessors beyond ERC4626. `debtOf` exists only on core eVaults (EVK); `EVC()` is
///         exposed by both core eVaults and EulerEarn vaults. Both are read under try/catch so a vault lacking them
///         (or a non-Euler ERC4626) degrades gracefully.
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
///      EVC `getCollaterals` lookup (under try/catch, so non-Euler/EulerEarn vaults degrade to `Supplied`).
contract EulerVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.EULER_VAULTS;

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

        // Skip unregistered assets (NAVCalculator would drop them anyway).
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
            positions[i++] = INAVCalculator.PositionBalance({
                balanceAsset: assetInfo,
                balanceAdapter: address(this),
                amount: supplied,
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: _supplyKind(account, vaultAddr),
                isLocked: false,
                labels: _legLabels(positionId)
            });
        }
        if (debt > 0) {
            positions[i] = INAVCalculator.PositionBalance({
                balanceAsset: assetInfo,
                balanceAdapter: address(this),
                amount: debt,
                isDebt: true,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: PositionKind.Borrowed,
                isLocked: false,
                labels: _legLabels(positionId)
            });
        }
        return positions;
    }

    /// @dev Classifies a supply leg: `Collateral` if the account has enabled this vault as EVC collateral, else
    ///      `Supplied`. Read under try/catch so a vault without `EVC()`/`getCollaterals` (EulerEarn aggregators —
    ///      never usable as collateral — or a non-Euler ERC4626) degrades to `Supplied`. EVC caps the collateral
    ///      list at a small length, so the membership scan is bounded.
    function _supplyKind(address account, address vaultAddr) private view returns (PositionKind) {
        try IEulerEVault(vaultAddr).EVC() returns (address evc) {
            if (evc != address(0)) {
                try IEVC(evc).getCollaterals(account) returns (address[] memory collaterals) {
                    for (uint256 j = 0; j < collaterals.length; j++) {
                        if (collaterals[j] == vaultAddr) return PositionKind.Collateral;
                    }
                } catch {}
            }
        } catch {}
        return PositionKind.Supplied;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @dev Per-leg display labels (filled on every emitted PositionBalance.labels): `["Vault", <leaf>]` where the
    ///      leaf is the vault's ERC4626 name ("" if unreadable). Empty array for a short positionId.
    function _legLabels(bytes memory positionId) private view returns (string[] memory) {
        if (positionId.length < 32) return new string[](0);
        address vault = abi.decode(positionId, (address));
        if (vault.code.length == 0) return new string[](0);
        string memory leaf = "";
        try IERC4626(vault).name() returns (string memory n) {
            leaf = n;
        } catch {}
        return _labels("Vault", leaf);
    }
}
