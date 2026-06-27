// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {IPositionDescribable} from "../IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title ERC-4626 Wrap Balance Adapter
/// @author KPK
/// @notice Generic balance adapter for any ERC-4626 share token whose `asset()` returns a NAV-priced
///         underlying. Reports the account's holding as `convertToAssets(balanceOf(account))`
///         denominated in `asset()`. The position is emitted with `type = Supply` (the wrapper
///         represents a credit position in the underlying).
/// @dev    Designed for thin wrappers like Aave V3 stata-tokens (`staticATokenLM`),
///         Maker-DAI savings wrappers, and any ERC-4626 vault whose share price
///         is derived purely from `convertToAssets`. Morpho ERC-4626 vaults have their own
///         dedicated meta-adapter (`MorphoVaultsMeta`) because the chain-config catalog tracks
///         Morpho vaults as a distinct family.
/// @dev    **Asset-registration policy:** the wrapped underlying MUST be registered with
///         NAVCalculator at deploy time — the constructor reverts otherwise. This makes wiring
///         errors loud (rather than silently producing a zero-value adapter). A defensive
///         runtime check also drops positions if the asset gets later unregistered via
///         `nav.unregisterAsset`, mirroring the conservative pattern in the Morpho vaults adapter.
contract ERC4626WrapBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    //
    // Type Definitions
    //

    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice The ERC-4626 wrapper contract
    IERC4626 public immutable WRAPPER;

    /// @notice The wrapper's underlying asset (cached from WRAPPER.asset() at construction)
    address public immutable ASSET;

    /// @notice Reference to NAVCalculator for asset registry access.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol ID for generic ERC4626 wrappers
    bytes32 private constant PROTOCOL_ID = ProtocolIds.ERC4626;

    //
    // Constructor
    //

    /// @param wrapper_ The address of the ERC-4626 wrapper (e.g. a Nexus Mutual RWI Vault share).
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access.
    /// @dev    Constructor enforces that `WRAPPER.asset()` is registered with NAVCalculator at
    ///         deploy time. Deploying an adapter whose underlying lacks a price feed is a useless
    ///         no-op (positions would always be dropped), so we fail loudly instead. The harness
    ///         and production deploy flows must register the underlying asset before deploying
    ///         the adapter — production: Safe-TX bundles place `registerAsset(...)` before
    ///         `addBalanceAdapters(...)`; harness: `_registerAllAssets()` runs before
    ///         `_deployAllBalanceAdapters()`.
    constructor(address wrapper_, address navCalculator_) {
        if (wrapper_ == address(0)) revert InvalidArguments();
        require(wrapper_.code.length > 0, "Wrapper must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WRAPPER = IERC4626(wrapper_);
        ASSET = WRAPPER.asset();
        require(ASSET != address(0), "Wrapper asset must be non-zero");

        require(
            INAVCalculator(navCalculator_).isAssetRegistered(ASSET), "Wrapper underlying must be a NAV-registered asset"
        );

        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IPositionDescribable).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) {
        return "ERC4626";
    }

    function positionLabels(bytes calldata) external pure returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "Vault";
        return out;
    }

    //
    // IBalanceAdapter
    //

    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        return assets;
    }

    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != ASSET) return (0, false);
        return (_calculateBalance(account), false);
    }

    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 balance = _calculateBalance(account);
        if (balance == 0) return (new address[](0), new uint256[](0), new bool[](0));

        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = ASSET;
        amounts[0] = balance;
        isDebt[0] = false;
    }

    /// @notice Returns one PositionBalance per registered underlying with a non-zero account balance.
    /// @dev Drops the position entirely if `ASSET` is not currently registered in NAVCalculator —
    ///      this is the "discard if no price" policy. Per-account registered-asset intersection
    ///      mirrors the pattern in the Morpho vaults adapter.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = new address[](1);
        supportedAssets[0] = ASSET;

        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);
        if (registeredSupportedAssets.length == 0) return new INAVCalculator.PositionBalance[](0);

        if (assetFilter != address(0) && assetFilter != ASSET) {
            return new INAVCalculator.PositionBalance[](0);
        }

        uint256 balance = _calculateBalance(account);
        if (balance == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(ASSET);
        positions = new INAVCalculator.PositionBalance[](1);
        positions[0] = INAVCalculator.PositionBalance({
            balanceAsset: underlyingAsset,
            balanceAdapter: address(this),
            amount: balance,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: abi.encode(address(WRAPPER)),
            positionKind: PositionKind.Supplied,
            isLocked: false
        });
    }

    //
    // Internal Helpers
    //

    /// @notice Convert the account's wrapper shares to the underlying via ERC-4626 `convertToAssets`.
    function _calculateBalance(address account) internal view returns (uint256) {
        return WRAPPER.convertToAssets(WRAPPER.balanceOf(account));
    }

    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }
}
