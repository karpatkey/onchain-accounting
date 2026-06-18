// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal interface for the Euler V2 core-eVault (EVK) borrow accessor. EulerEarn aggregator vaults do NOT
///         implement this, so the adapter calls it under try/catch and treats a revert as "no debt".
interface IEulerEVaultDebt {
    /// @return The account's current debt in the vault's underlying asset (interest-accrued), 0 if none.
    function debtOf(address account) external view returns (uint256);
}

/// @title Euler Vaults Meta Balance Adapter
/// @author kpk
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
///      Supply that is enabled as EVC collateral is still reported as `Supplied` (its NAV value is identical; the
///      Supplied-vs-Collateral label is not distinguished, which would require an EVC collateral lookup).
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
        try IEulerEVaultDebt(vaultAddr).debtOf(account) returns (uint256 d) {
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
                positionKind: PositionKind.Supplied
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
                positionKind: PositionKind.Borrowed
            });
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @inheritdoc MetaBalanceAdapter
    function describePosition(bytes calldata pid) external view override returns (string memory) {
        if (pid.length < 32) return "";
        address vault = abi.decode(pid, (address));
        try IERC4626(vault).name() returns (string memory n) {
            return n;
        } catch {
            return "";
        }
    }
}
