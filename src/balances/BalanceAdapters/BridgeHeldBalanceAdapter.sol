// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "../BalanceAdapterBase.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title Bridge Escrow Held-Balance Adapter (ADR 0024)
/// @author KPK
/// @notice Reports the account's **delivered-but-unclaimed** funds sitting in the destination `BridgeEscrow`
///         custody (ADR 0024 "hold-then-claim"). Between `recordDelivery` (funds arrive on the destination and are
///         held by the escrow) and `claim` (MANAGER moves them to the safe), the value is not yet in the safe's
///         wallet, so the ordinary ERC20 balance adapter would miss it. This adapter closes that gap by reading the
///         escrow's per-account custody so NAV counts held value continuously across the bridge hop. The three
///         windows — source in-transit → destination held (this adapter) → safe balance (the ERC20 adapter) — are
///         disjoint by construction, so nothing is double-counted; the MANAGER-gated `claim` is the controlled block
///         where value transitions from "held" to "safe balance".
/// @dev Immutable, view-only, per-chain: pin the destination `BridgeEscrow` for this chain in the constructor. Every
///      leg is `PositionKind.Supplied` with `isLocked = true` (the account owns the value but cannot use it until a
///      claim moves it to the safe). Only assets registered on `NAVCalculator` are emitted (unregistered held assets
///      cannot be priced). The custody amount is the escrow's measured balance-delta, so it can never over-report.
contract BridgeHeldBalanceAdapter is BalanceAdapterBase {
    /// @dev Single-product taxonomy: brand == protocolId == protocolSubId == `bridge-escrow`.
    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.BRIDGE_ESCROW;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.BRIDGE_ESCROW;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.BRIDGE_ESCROW;

    /// @notice NAVCalculator, for looking up registered-asset metadata when emitting positions.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice The destination BridgeEscrow on this chain whose held custody this adapter reports.
    IBridgeEscrow public immutable BRIDGE_ESCROW;

    /// @param navCalculator The NAVCalculator address (registered-asset lookups).
    /// @param bridgeEscrow The BridgeEscrow proxy on this chain.
    constructor(address navCalculator, address bridgeEscrow) {
        if (navCalculator == address(0) || bridgeEscrow == address(0)) revert InvalidArguments();
        AddressCheckLib.requireContract(navCalculator, "NAVCalculator");
        AddressCheckLib.requireContract(bridgeEscrow, "BridgeEscrow");
        NAV_CALCULATOR = INAVCalculator(navCalculator);
        BRIDGE_ESCROW = IBridgeEscrow(bridgeEscrow);
    }

    //
    // IPositionDescribable
    //

    function protocolName() external pure returns (string memory) {
        return ProtocolNames.BRIDGE_ESCROW;
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "Held (pending claim)";
        return out;
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice The assets the escrow can hold custody of on this chain (its registered bridge assets).
    function underlyingAssetsSupported() external view override returns (address[] memory underlyingAssets) {
        (, underlyingAssets) = BRIDGE_ESCROW.registeredAssets();
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        return (BRIDGE_ESCROW.getHeldBalanceForAsset(asset, account), false);
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Per-asset held custody for the account (credit; skips zeros).
    function getAdapterBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) return (new address[](0), new uint256[](0), new bool[](0));
        (assets, amounts) = BRIDGE_ESCROW.getHeldBalancesForAccount(account);
        isDebt = new bool[](assets.length); // all false (credit)
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice One `Supplied` (`isLocked = true`) leg per held asset that is also registered on NAVCalculator, under
    ///         `positionId = abi.encode(bridgeEscrow)`; the held token rides in `balanceAsset`.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        (address[] memory heldAssets, uint256[] memory heldAmounts) = BRIDGE_ESCROW.getHeldBalancesForAccount(account);
        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();
        bytes memory pid = abi.encode(address(BRIDGE_ESCROW));

        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](heldAssets.length);
        uint256 count;
        for (uint256 i; i < heldAssets.length; ++i) {
            address asset = heldAssets[i];
            uint256 amount = heldAmounts[i];
            if (amount == 0) continue;
            if (assetFilter != address(0) && assetFilter != asset) continue;

            (INAVCalculator.Asset memory assetMeta, bool found) = RegisteredAssetLib.find(registered, asset);
            if (!found) continue; // unregistered assets cannot be priced — skip (under-report, safe direction)

            tmp[count++] = INAVCalculator.PositionBalance({
                balanceAsset: assetMeta,
                balanceAdapter: address(this),
                amount: amount,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: pid,
                positionKind: PositionKind.Supplied,
                isLocked: true,
                positionInstanceId: bytes32(0)
            });
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }
}
