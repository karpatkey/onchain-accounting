// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Fluid fTokens Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's supply position in *any* Fluid fToken (ERC4626
///         lending vault) — `convertToAssets(balanceOf(account))` emitted as a single `Supply` leg in the
///         fToken's underlying. The instance coordinate is the fToken address, widened to bytes32; the active
///         fToken set lives on NAVCalculator (`setMetaInstances`). Identity is derived on-chain (positionId =
///         fToken address; name = fToken `symbol()`, e.g. "fUSDC"). See ADR 0010.
/// @dev Mirrors the per-fToken `FluidFTokenBalanceOracle` leg-for-leg.
contract FluidFTokensMetaBalanceAdapter is MetaBalanceOracle {
    using Strings for address;

    /// @param protocol_ Protocol identifier (e.g. "Fluid").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_) MetaBalanceOracle(protocol_, navCalculator_) {}

    /// @inheritdoc MetaBalanceOracle
    /// @dev `instance` is the fToken (ERC4626) address. Emits one `Supply` leg in the fToken's underlying.
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
        positions[0] = INAVCalculator.PositionBalance({
            underlyingAsset: assetInfo,
            balanceOracle: address(this),
            amount: amount,
            isDebt: false,
            protocol: _protocol,
            positionDetail: PositionType.withType(_detailBase(address(fToken)), PositionType.SUPPLY),
            positionId: address(fToken).toHexString()
        });
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @notice positionDetail JSON base (no closing `}`); name derived on-chain from the fToken `symbol()`.
    function _detailBase(address fToken) private view returns (string memory) {
        string memory name;
        try IERC20Metadata(fToken).symbol() returns (string memory s) {
            name = bytes(s).length == 0 ? fToken.toHexString() : s;
        } catch {
            name = fToken.toHexString();
        }
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"Lending\",\"name\":\"", name, "\"");
    }
}
