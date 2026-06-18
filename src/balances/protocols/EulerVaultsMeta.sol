// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Euler Vaults Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports the underlying-asset balance for an account's supplied position in
///         *any* Euler V2 eVault. The set of eVaults to query is configured on NAVCalculator (per-adapter,
///         MANAGER-gated) and passed in as `bytes32` instance coordinates (eVault addresses widened to bytes32).
/// @dev Euler V2 eVaults (EVK) are ERC4626-compliant, so the supplied balance is `convertToAssets(balanceOf(account))`
///      — identical in shape to the Morpho-vault adapter. This reports the **supply leg only**; it does not model
///      Euler borrowing. That is sufficient for supply/earn usage (deposit/withdraw/redeem) and intentionally does
///      NOT net any debt — wire this adapter only for accounts that do not borrow on Euler. Per-instance identity is
///      `abi.encode(address(eVault))`.
contract EulerVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.EULER_VAULTS;

    /// @param protocolName_ Human-readable protocol name (e.g. "Euler").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns an empty array (rather than reverting) when the eVault asset is unregistered or the balance is
    ///      zero, so a single eVault never zeroes out the rest of the configured set.
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

        uint256 amount = vault.convertToAssets(vault.balanceOf(account));
        if (amount == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            balanceAsset: assetInfo,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: _instancePositionId(instance),
            positionKind: PositionKind.Supplied
        });
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
