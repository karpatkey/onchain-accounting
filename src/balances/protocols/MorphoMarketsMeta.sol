// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title Morpho Markets Meta Balance Oracle
/// @author kpk
/// @notice One immutable adapter that reports an account's positions on *any* Morpho Blue market. The set of
///         markets to query is configured on NAVCalculator (per-oracle, MANAGER-gated) and passed as `bytes32`
///         instance coordinates — here the coordinate is the Morpho **marketId** itself (used directly, not an
///         address). Emits up to three gross rows per market (collateral, loan-supply, loan-borrow), matching
///         the per-market `MorphoMarket` adapter. See ADR 0010 (meta-adapters) and ADR 0004 (projected balances).
contract MorphoMarketsMetaBalanceOracle is MetaBalanceOracle {
    using Math for uint256;
    using Strings for uint256;
    using MorphoBalancesLib for IMorpho;

    /// @notice The Morpho Blue singleton (protocol-global).
    IMorpho public immutable MORPHO;

    /// @param morpho_ The Morpho Blue contract address.
    /// @param protocol_ Protocol identifier (e.g. "Morpho").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address morpho_, string memory protocol_, address navCalculator_)
        MetaBalanceOracle(protocol_, navCalculator_)
    {
        require(morpho_.code.length > 0, "Morpho must be a contract");
        MORPHO = IMorpho(morpho_);
    }

    /// @inheritdoc MetaBalanceOracle
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
        string memory base = _detailBase(collateral, loan);
        string memory positionId = uint256(instance).toHexString(32);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](3);
        uint256 count;

        if (collateralEligible && uint256(pos.collateral) > 0) {
            temp[count++] = _row(
                collAsset,
                uint256(pos.collateral),
                false,
                positionId,
                PositionType.withType(base, PositionType.COLLATERAL)
            );
        }

        if (loanEligible) {
            (uint256 supplied, uint256 borrowed) = _loanLegs(mp, pos);
            if (supplied > 0) {
                temp[count++] =
                    _row(loanAsset, supplied, false, positionId, PositionType.withType(base, PositionType.SUPPLY));
            }
            if (borrowed > 0) {
                temp[count++] =
                    _row(loanAsset, borrowed, true, positionId, PositionType.withType(base, PositionType.BORROW));
            }
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(instance));
        assets = new address[](2);
        assets[0] = mp.collateralToken;
        assets[1] = mp.loanToken;
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

    /// @notice Builds the positionDetail JSON base (no closing `}`), deriving the market name on-chain from the
    ///         collateral/loan token symbols, e.g. `{"protocol":"Morpho","product":"Market","name":"cbBTC/USDC"`.
    function _detailBase(address collateral, address loan) private view returns (string memory) {
        return string.concat(
            "{\"protocol\":\"",
            _protocol,
            "\",\"product\":\"Market\",\"name\":\"",
            IERC20Metadata(collateral).symbol(),
            "/",
            IERC20Metadata(loan).symbol(),
            "\""
        );
    }

    /// @notice Assembles a single PositionBalance row with this adapter's identity.
    function _row(
        INAVCalculator.Asset memory asset,
        uint256 amount,
        bool isDebt,
        string memory positionId,
        string memory positionDetail
    ) private view returns (INAVCalculator.PositionBalance memory) {
        return INAVCalculator.PositionBalance({
            underlyingAsset: asset,
            balanceOracle: address(this),
            amount: amount,
            isDebt: isDebt,
            protocol: _protocol,
            positionDetail: positionDetail,
            positionId: positionId
        });
    }
}
