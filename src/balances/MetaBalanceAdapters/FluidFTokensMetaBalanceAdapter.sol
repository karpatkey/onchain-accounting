// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Fluid fTokens Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's supply position in *any* Fluid fToken (ERC4626
///         lending vault) — `convertToAssets(balanceOf(account))` emitted as a single `Supplied` leg in the
///         fToken's underlying. The instance coordinate is the fToken address, widened to bytes32; the active
///         fToken set lives on NAVCalculator (`addMetaInstances`/`removeMetaInstances`). Identity is encoded as
///         `abi.encode(address(fToken))`. See ADR 0010.
/// @dev Reports one Supply leg per fToken (convertToAssets(balanceOf)) in its underlying.
contract FluidFTokensMetaBalanceAdapter is MetaBalanceAdapter {
    /// @param protocolName_ Human-readable protocol name (e.g. "Fluid").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the fToken (ERC4626) address. Emits one `Supplied` leg in the fToken's underlying.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IERC4626 fToken = IERC4626(_toAddress(instance));
        address asset = fToken.asset();
        if (assetFilter != address(0) && assetFilter != asset) {
            return new INAVCalculator.PositionBalance[](0);
        }
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) return new INAVCalculator.PositionBalance[](0);

        uint256 amount = fToken.convertToAssets(fToken.balanceOf(account));
        if (amount == 0) return new INAVCalculator.PositionBalance[](0);

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
    /// @dev Returns `["Lending", <fToken symbol>]` (leaf "" if unreadable). Returns an empty array for a short
    ///      positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        address fToken = abi.decode(pid, (address));
        return _labels("Lending", LabelLib.symbol(fToken, ""));
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
        return ProtocolIds.FLUID_FTOKENS;
    }
}
