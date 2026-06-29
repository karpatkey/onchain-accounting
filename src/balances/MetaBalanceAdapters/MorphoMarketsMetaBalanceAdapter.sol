// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LabelLib} from "src/balances/LabelLib.sol";
import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Morpho Markets Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's positions on *any* Morpho Blue market. The set of
///         markets to query is configured on NAVCalculator (per-adapter, MANAGER-gated) and passed as `bytes32`
///         instance coordinates — here the coordinate is the Morpho **marketId** itself (used directly, not an
///         address). Emits up to three gross rows per market (collateral, loan-supply, loan-borrow).
///         See ADR 0010 (meta-adapters) and ADR 0004 (projected balances).
contract MorphoMarketsMetaBalanceAdapter is MetaBalanceAdapter {
    using Math for uint256;
    using MorphoBalancesLib for IMorpho;

    /// @notice The Morpho Blue singleton (protocol-global).
    IMorpho public immutable MORPHO;

    /// @param morpho_ The Morpho Blue contract address.
    /// @param protocolName_ Human-readable protocol name (e.g. "Morpho").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address morpho_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        AddressCheckLib.requireContract(morpho_, "Morpho");
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
            temp[count++] = _leg(collAsset, uint256(pos.collateral), false, pid, PositionKind.Collateral);
        }

        if (loanEligible) {
            (uint256 supplied, uint256 borrowed) = _loanLegs(mp, pos);
            if (supplied > 0) {
                temp[count++] = _leg(loanAsset, supplied, false, pid, PositionKind.Supplied);
            }
            if (borrowed > 0) {
                temp[count++] = _leg(loanAsset, borrowed, true, pid, PositionKind.Borrowed);
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

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Market", <leaf>]` where the leaf is "<collateral>/<loan>" ("" if the marketId cannot
    ///      be resolved). Returns an empty array for a short positionId.
    function positionLabels(bytes calldata pid) external view override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        bytes32 marketId = abi.decode(pid, (bytes32));
        string memory leaf = "";
        try MORPHO.idToMarketParams(Id.wrap(marketId)) returns (MarketParams memory mp) {
            string memory collSym = _symbol(mp.collateralToken);
            string memory loanSym = _symbol(mp.loanToken);
            leaf = string.concat(collSym, "/", loanSym);
        } catch {}
        return _labels("Market", leaf);
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
        return ProtocolIds.MORPHO_MARKETS;
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

    /// @notice Reads an ERC20 symbol, falling back to "?" for non-standard tokens or a codeless address (e.g. an idle
    ///         market with no collateral token) — so the concatenated leaf stays well-formed (no leading `/` segment).
    function _symbol(address token) private view returns (string memory) {
        return LabelLib.symbol(token, "?");
    }
}
