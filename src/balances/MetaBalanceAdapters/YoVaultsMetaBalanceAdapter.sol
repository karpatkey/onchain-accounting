// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {ERC4626RedeemLib} from "src/balances/ERC4626RedeemLib.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice A YoVault read ran out of the gas its frame was given; the position must not be silently dropped (same
///         contract as {ERC4626RedeemLib.RedeemValueGasExhausted}).
error YoVaultReadGasExhausted(address vault, uint256 stipend, uint256 consumed);

/// @title YO Vaults Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter for YO Protocol vaults (`YoVault`, e.g. yoUSD Edge
///         `0x5DD8BFa6C5C68D05d25EF6143E05C11E26c4cDB7`). For each governed vault it reports up to TWO legs in the
///         vault's ERC-4626 asset, sharing one static `positionId = abi.encode(vault)` (ADR 0016):
///           - **held** shares: `Supplied`, `isLocked = false`, value `previewRedeem(balanceOf(account))`;
///           - **pending** redeem (shares escrowed by `requestRedeem`): `Supplied`, `isLocked = true`.
/// @dev **Why a YO adapter and not a `MorphoVaultsMeta` instance.** The held leg alone is plain ERC-4626 and the
///      Morpho meta adapter would value it correctly, but it would stamp a YO vault with `morpho` identity
///      (`protocolSubId = morpho-vaults`, `protocolName = "Morpho"`), which consumers key on (the Portal maps
///      `protocolSubId` to its protocol registry). Same reasoning as `SymbioticVaultsMetaBalanceAdapter`. YO's own
///      Morpho Vault V2 (YO Ecosystem) is a genuine Morpho vault and stays on `MorphoVaultsMeta`.
///
///      **Pending redeem mechanics** (verified against impl `0xc84a6E01…78DC` and on a fork). `requestRedeem(shares,
///      receiver, owner)` redeems instantly when idle liquidity covers it; otherwise it MOVES the shares from `owner`
///      to the vault and records `_pendingRedeem[receiver] = {assets, shares}`, settled later by a YO operator via
///      `fulfillRedeem(receiver, shares, atCurrentPrice)`. Without the pending leg the position would vanish from NAV
///      between request and fulfilment. `pendingRedeemRequest(user)` returns `(assets, shares)` — ASSETS FIRST — and
///      `assets` is the GROSS (pre-fee) `convertToAssets` reserved at request time (pinned in the fork test). The
///      entry is keyed on the RECEIVER, so a Safe that requests with `receiver != itself` correctly moves the claim
///      out of its own NAV.
///
///      **Pending valuation (conservative).** The operator pays the reserved gross, or — `atCurrentPrice`, allowed
///      only when the current value is LOWER — the current value; the fee is then taken from that gross at the LIVE
///      `feeOnWithdraw`. The leg reports the lower bound:
///
///          amount = min( net(pendingAssets), previewRedeem(pendingShares) )
///          net(x) = x - ceil(x * fee / (fee + 1e18))      (= YoVault._feeOnTotal)
///
///      `previewRedeem` is already fee-net and `net()` applies the fee once to the gross reservation: the fee is
///      applied exactly once on both branches, a price drop is reflected, a price rise is never credited.
///
///      **Fail closed.** The held leg uses {ERC4626RedeemLib.redeemValue} (0 on failure). The pending reads are
///      gas-stipended staticcalls that report 0 on a revert/short return — so a broken pending read drops only the
///      pending leg, never the held one — and revert on gas exhaustion rather than dropping silently. Any other
///      revert inside an instance (e.g. `asset()`) drops that instance via the base's per-instance isolation.
contract YoVaultsMetaBalanceAdapter is MetaBalanceAdapter {
    /// @dev YoVault's fee denominator (`DENOMINATOR`, 1e18 = 100%).
    uint256 private constant FEE_DENOMINATOR = 1e18;

    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) MetaBalanceAdapter(navCalculator_) {}

    //
    // Valuation (public views, for monitoring and tests)
    //

    /// @notice Fee-net value of `account`'s held (non-escrowed) shares in `vault`. 0 if unreadable.
    function heldValue(address vault, address account) public view returns (uint256) {
        if (account == address(0)) return 0;
        return ERC4626RedeemLib.redeemValue(vault, IYoVault(vault).balanceOf(account));
    }

    /// @notice Fee-net lower-bound value of `account`'s pending redeem in `vault`. 0 on any read failure.
    function pendingValue(address vault, address account) public view returns (uint256) {
        if (account == address(0)) return 0;

        (bool ok, uint256 pendingAssets, uint256 pendingShares) =
            _call2(vault, abi.encodeCall(IYoVault.pendingRedeemRequest, (account)), 64);
        if (!ok || pendingAssets == 0 || pendingShares == 0) return 0;

        (bool feeOk, uint256 fee,) = _call2(vault, abi.encodeCall(IYoVault.feeOnWithdraw, ()), 32);
        if (!feeOk) return 0;

        uint256 reservedNet = pendingAssets - Math.mulDiv(pendingAssets, fee, fee + FEE_DENOMINATOR, Math.Rounding.Ceil);
        uint256 currentNet = ERC4626RedeemLib.redeemValue(vault, pendingShares);
        return reservedNet < currentNet ? reservedNet : currentNet;
    }

    /// @dev Gas-stipended staticcall decoding up to two words; `ok` requires at least `need` bytes of return data.
    ///      Reverts {YoVaultReadGasExhausted} when the failure was gas starvation, so a starved read is never
    ///      mistaken for 0.
    function _call2(address vault, bytes memory cd, uint256 need)
        private
        view
        returns (bool ok, uint256 w0, uint256 w1)
    {
        uint256 available = gasleft();
        uint256 stipend = GasStipendLib.stipendFrom(available);
        uint256 size;
        // 64-byte output window at the free pointer, not bumped (nothing allocates across this block); zeroed first.
        assembly ("memory-safe") {
            let out := mload(0x40)
            mstore(out, 0)
            mstore(add(out, 0x20), 0)
            ok := staticcall(stipend, vault, add(cd, 0x20), mload(cd), out, 0x40)
            size := returndatasize()
            w0 := mload(out)
            w1 := mload(add(out, 0x20))
        }
        if (ok && size >= need) return (true, w0, w1);
        uint256 consumed = available - gasleft();
        if (GasStipendLib.exhausted(stipend, consumed)) revert YoVaultReadGasExhausted(vault, stipend, consumed);
        return (false, 0, 0);
    }

    //
    // MetaBalanceAdapter hooks
    //

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Up to two legs (held, pending), both `Supplied` in the vault asset under `abi.encode(vault)`; zero legs
    ///      are omitted. Empty when the asset is filtered out or not registered on the NAV.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address vault = _toAddress(instance);
        address asset = IYoVault(vault).asset();
        if (assetFilter != address(0) && assetFilter != asset) return positions;

        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(asset);
        if (!found) return positions;

        uint256 held = heldValue(vault, account);
        uint256 pending = pendingValue(vault, account);
        uint256 n = (held > 0 ? 1 : 0) + (pending > 0 ? 1 : 0);
        positions = new INAVCalculator.PositionBalance[](n);
        if (n == 0) return positions;

        bytes memory pid = _instancePositionId(instance);
        uint256 i;
        if (held > 0) positions[i++] = _leg(assetInfo, held, false, pid, PositionKind.Supplied);
        if (pending > 0) {
            positions[i] = _leg(assetInfo, pending, false, pid, PositionKind.Supplied);
            positions[i].isLocked = true;
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = IYoVault(_toAddress(instance)).asset();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `["Vault", <vault name>]` (e.g. `["Vault", "yoUSD Edge"]`); the held and pending legs share it and are
    ///      told apart by `isLocked`. An unreadable name collapses to `["Vault"]`.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        return _addressLabels(pid, "Vault", false);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.YO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.YO;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.YO_VAULTS;
    }
}

/// @notice Minimal read surface of a YO vault (`YoVault`).
interface IYoVault {
    /// @notice ERC-4626 underlying asset.
    function asset() external view returns (address);

    /// @notice ERC-20 share balance.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Pending redeem of `user` (the RECEIVER of the request).
    /// @return assets Gross (pre-fee) assets reserved at request time.
    /// @return pendingShares Shares escrowed in the vault.
    function pendingRedeemRequest(address user) external view returns (uint256 assets, uint256 pendingShares);

    /// @notice Withdrawal fee on a 1e18 scale, applied to the gross at fulfilment.
    function feeOnWithdraw() external view returns (uint256);
}
