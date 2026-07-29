// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626RedeemLib} from "src/balances/ERC4626RedeemLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Morpho Vaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports the underlying-asset balance for an account's position in *any*
///         Morpho ERC4626 vault. The set of vaults to query is configured on NAVCalculator (per-adapter,
///         MANAGER-gated) and passed in as `bytes32` instance coordinates (vault addresses widened to bytes32).
/// @dev Per-instance identity is encoded as `abi.encode(address(vault))`. Supports ERC4626-compliant Morpho vaults
///      (V1 and V2). Does not include Merkl or Universal Rewards Distributor rewards.
contract MorphoVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns an empty array (rather than reverting) when the vault asset is unregistered or the balance is
    ///      zero, so a single vault never zeroes out the rest of the configured set.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IERC4626 vault = IERC4626(_toAddress(instance));
        address asset = vault.asset();

        // Apply asset filter
        if (assetFilter != address(0) && assetFilter != asset) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Skip unregistered assets (NAVCalculator would drop them anyway)
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Fee-aware share→asset value: previewRedeem, net of any EIP-4626 §4.3 exit fee. Reports 0 — dropping
        // the position via the `amount == 0` return below — if that read cannot be completed, rather than
        // substituting `convertToAssets`, which ignores the fee and so can only value the position UPWARD.
        // See {ERC4626RedeemLib.redeemValue}.
        uint256 amount = ERC4626RedeemLib.redeemValue(address(vault), vault.balanceOf(account));
        if (amount == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = _leg(assetInfo, amount, false, _instancePositionId(instance), PositionKind.Supplied);
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Vault", <name>]` using the vault's ERC4626 `name()`; an unreadable name collapses to just
    ///      `["Vault"]` (empty-leaf convention in {_labels}). Returns an empty array for a malformed positionId (see {_pidAddress}).
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Vault", false);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.MORPHO_VAULTS;
    }
}
