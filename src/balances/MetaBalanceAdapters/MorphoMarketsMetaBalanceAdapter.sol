// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Morpho Markets Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's positions on *any* Morpho Blue market. The set of
///         markets to query is configured on NAVCalculator (per-adapter, MANAGER-gated) and passed as `bytes32`
///         instance coordinates — here the coordinate is the Morpho **marketId** itself (used directly, not an
///         address). Emits up to three gross rows per market (collateral, loan-supply, loan-borrow), matching
///         the per-market `MorphoMarket` adapter. See ADR 0010 (meta-adapters) and ADR 0004 (projected balances).
contract MorphoMarketsMetaBalanceAdapter is MetaBalanceAdapter {
    using Math for uint256;
    using MorphoBalancesLib for IMorpho;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.MORPHO_MARKETS;

    /// @notice The Morpho Blue singleton (protocol-global).
    IMorpho public immutable MORPHO;

    /// @param morpho_ The Morpho Blue contract address.
    /// @param protocolName_ Human-readable protocol name (e.g. "Morpho").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address morpho_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(morpho_.code.length > 0, "Morpho must be a contract");
        MORPHO = IMorpho(morpho_);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the Morpho marketId. Returns up to three rows (each guarded by `> 0`): collateral,
    ///      loan-supplied (credit), loan-borrowed (debt). Skips unregistered assets and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        Id marketId = Id.wrap(instance);
        MarketParams memory mp = MORPHO.idToMarketParams(marketId);
        address collateral = mp.collateralToken;
        address loan = mp.loanToken;

        (INAVCalculator.Asset memory collAsset, bool collReg) = _getAssetInfo(collateral);
        (INAVCalculator.Asset memory loanAsset, bool loanReg) = _getAssetInfo(loan);

        bool collateralEligible = collReg && (assetFilter == address(0) || assetFilter == collateral);
        bool loanEligible = loanReg && (assetFilter == address(0) || assetFilter == loan);
        if (!collateralEligible && !loanEligible) {
            return new INAVCalculator.PositionBalance[](0);
        }

        Position memory pos = MORPHO.position(marketId, account);
        bytes memory pid = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](3);
        uint256 count;

        if (collateralEligible && uint256(pos.collateral) > 0) {
            temp[count++] = _row(collAsset, uint256(pos.collateral), false, pid, PositionKind.Collateral);
        }

        if (loanEligible) {
            (uint256 supplied, uint256 borrowed) = _loanLegs(mp, pos);
            if (supplied > 0) {
                temp[count++] = _row(loanAsset, supplied, false, pid, PositionKind.Supplied);
            }
            if (borrowed > 0) {
                temp[count++] = _row(loanAsset, borrowed, true, pid, PositionKind.Borrowed);
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(instance));
        assets = new address[](2);
        assets[0] = mp.collateralToken;
        assets[1] = mp.loanToken;
    }

    /// @dev Per-leg display labels, filled on every emitted PositionBalance.labels.
    /// @dev Returns `["Market", <leaf>]` where the leaf is "<collateral>/<loan> market" ("" if the marketId cannot
    ///      be resolved). Returns an empty array for a short positionId.
    function _legLabels(bytes memory positionId) private view returns (string[] memory) {
        if (positionId.length < 32) return new string[](0);
        bytes32 marketId = abi.decode(positionId, (bytes32));
        string memory leaf = "";
        try MORPHO.idToMarketParams(Id.wrap(marketId)) returns (MarketParams memory mp) {
            string memory collSym = _symbol(mp.collateralToken);
            string memory loanSym = _symbol(mp.loanToken);
            leaf = string.concat(collSym, "/", loanSym, " market");
        } catch {}
        return _labels("Market", leaf);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Morpho market instance is a raw bytes32 marketId, not an address.
    function _instancePositionId(bytes32 instance) internal pure override returns (bytes memory) {
        return abi.encode(instance);
    }

    /// @notice Projected loan-token supply/borrow amounts for the account (ADR 0004: expectedMarketBalances).
    ///         Supply rounds down (avoid overstating credit); borrow rounds up (avoid understating debt).
    function _loanLegs(MarketParams memory mp, Position memory pos)
        private
        view
        returns (uint256 supplied, uint256 borrowed)
    {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MORPHO.expectedMarketBalances(mp);
        if (totalSupplyShares != 0 && pos.supplyShares != 0) {
            supplied = totalSupplyAssets.mulDiv(pos.supplyShares, totalSupplyShares, Math.Rounding.Floor);
        }
        if (totalBorrowShares != 0 && pos.borrowShares != 0) {
            borrowed = totalBorrowAssets.mulDiv(pos.borrowShares, totalBorrowShares, Math.Rounding.Ceil);
        }
    }

    /// @notice Assembles a single PositionBalance row with this adapter's identity.
    function _row(INAVCalculator.Asset memory asset, uint256 amount, bool isDebt, bytes memory pid, PositionKind kind)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: isDebt,
            protocolId: PROTOCOL_ID,
            positionId: pid,
            positionKind: kind,
            isLocked: false,
            labels: _legLabels(pid)
        });
    }

    /// @notice Reads an ERC20 symbol, falling back to "?" for non-standard tokens or a codeless address (e.g. an idle
    ///         market with no collateral token) — so the concatenated leaf stays well-formed (no leading `/` segment).
    function _symbol(address token) private view returns (string memory) {
        if (token.code.length == 0) return "?";
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return bytes(s).length == 0 ? "?" : s;
        } catch {
            return "?";
        }
    }
}
