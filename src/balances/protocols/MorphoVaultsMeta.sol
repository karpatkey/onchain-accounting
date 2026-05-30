// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Morpho Vaults Meta Balance Oracle
/// @author kpk
/// @notice One immutable adapter that reports the underlying-asset balance for an account's position in *any*
///         Morpho ERC4626 vault. The set of vaults to query is configured on NAVCalculator (per-oracle,
///         MANAGER-gated) and passed in as `bytes32` instance coordinates (vault addresses widened to bytes32).
/// @dev Per-instance identity is derived on-chain: `positionId` is the vault address as hex, and the
///      `positionDetail` name is read from the vault's ERC20 `name()`. Supports ERC4626-compliant Morpho vaults
///      (V1 and V2). Does not include Merkl or Universal Rewards Distributor rewards.
contract MorphoVaultsMetaBalanceOracle is MetaBalanceOracle {
    using Strings for address;

    /// @param protocol_ Protocol identifier (e.g. "Morpho").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_) MetaBalanceOracle(protocol_, navCalculator_) {}

    /// @inheritdoc MetaBalanceOracle
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

        uint256 amount = vault.convertToAssets(vault.balanceOf(account));
        if (amount == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            underlyingAsset: assetInfo,
            balanceOracle: address(this),
            amount: amount,
            isDebt: false,
            protocol: _protocol,
            positionDetail: PositionType.withType(_positionDetailBase(vault), PositionType.SUPPLY),
            positionId: address(vault).toHexString()
        });
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IERC4626(_toAddress(instance)).asset();
    }

    /// @notice Builds the positionDetail JSON base (no closing `}`), deriving the vault name on-chain.
    /// @dev e.g. `{"protocol":"Morpho","product":"Vault","name":"Steakhouse USDC"`.
    function _positionDetailBase(IERC4626 vault) internal view returns (string memory) {
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"Vault\",\"name\":\"", vault.name(), "\"");
    }
}
