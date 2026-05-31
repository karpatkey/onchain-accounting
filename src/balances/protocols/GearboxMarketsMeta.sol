// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Gearbox Markets Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's supply position in *any* Gearbox V3 ERC4626 farming
///         pool — `convertToAssets(balanceOf(account))` emitted as a single `Supply` leg in the pool's underlying.
///         The instance coordinate is the market (pool) address, widened to bytes32; the active market set lives
///         on NAVCalculator (`setMetaInstances`). Identity is derived on-chain (positionId = market address; name
///         = market ERC20 `name()`). See ADR 0010.
/// @dev Mirrors the per-market `GearboxMarketBalanceOracle` leg-for-leg. Does not include Merkl rewards (same as
///      the per-market adapter).
contract GearboxMarketsMetaBalanceAdapter is MetaBalanceOracle {
    using Strings for address;

    /// @param protocol_ Protocol identifier (e.g. "Gearbox").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_) MetaBalanceOracle(protocol_, navCalculator_) {}

    /// @inheritdoc MetaBalanceOracle
    /// @dev `instance` is the market (ERC4626 pool) address. Emits one `Supply` leg in the market's underlying,
    ///      dropping a zero balance and skipping an unregistered/filtered asset.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IERC4626 market = IERC4626(_toAddress(instance));
        address asset = market.asset();
        if (assetFilter != address(0) && assetFilter != asset) {
            return new INAVCalculator.PositionBalance[](0);
        }
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) return new INAVCalculator.PositionBalance[](0);

        uint256 amount = market.convertToAssets(market.balanceOf(account));
        if (amount == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            underlyingAsset: assetInfo,
            balanceOracle: address(this),
            amount: amount,
            isDebt: false,
            protocol: _protocol,
            positionDetail: PositionType.withType(_detailBase(address(market)), PositionType.SUPPLY),
            positionId: address(market).toHexString()
        });
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @notice positionDetail JSON base (no closing `}`); name derived on-chain from the market's ERC20 `name()`.
    function _detailBase(address market) private view returns (string memory) {
        string memory name;
        try IERC20Metadata(market).name() returns (string memory n) {
            name = bytes(n).length == 0 ? market.toHexString() : n;
        } catch {
            name = market.toHexString();
        }
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"Market\",\"name\":\"", name, "\"");
    }
}
