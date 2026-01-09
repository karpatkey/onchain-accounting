// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "src/errors.sol";

import {Id, IMorpho, MarketParams, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

/// @title Morpho Market Balance Oracle
/// @author kpk
/// @notice Returns the underlying token equivalent balance for either the supplied/loan asset or the collateral asset
/// for a given account. There are two cases for the calculation of the balance:
///    1. Supplied/Loan Token: The balance for the supplied/loan token is calculated as the difference between the
///       supplied assets and borrowed assets. The supplied assets are determined based on the user's supply
///       shares relative to the total supply shares of the market. Similarly, the borrowed assets are determined based
///       on the user's borrow shares relative to the total borrow shares. Both values are scaled by the total supply
///       and borrow assets to obtain the corresponding amounts in terms of the underlying asset.
///    2. Collateral Token: The balance for the collateral token is simply the amount of collateral held by the user in
///       the market position, without any need for scaling or adjustments.
/// @dev The rounding for the borrow and supply amounts is done conservatively:
///    - Borrowed Assets: Rounded up (`Math.Rounding.Ceil`) to ensure that the debt is not underestimated.
///    - Supplied Assets: Rounded down (`Math.Rounding.Floor`) to ensure that the supplied assets are not
/// overestimated.
contract MorphoMarketBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using Math for uint256;
    using SafeCast for uint256;
    using MorphoBalancesLib for IMorpho;

    //
    // State
    //

    /// @notice The Morpho contract
    IMorpho public immutable morpho;

    /// @notice The market id to query
    Id public immutable marketId;

    /// @notice The collateral token address
    address public immutable collateralToken;

    /// @notice The loan token address
    address public immutable loanToken;

    /// @notice Position metadata tags describing the DeFi position this oracle is associated to.
    PositionMetadata internal _positionMetadata;

    //
    // Constructor
    //

    /// @param morpho_ The Morpho contract address.
    /// @param marketId_ The market id to query.
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(address morpho_, bytes32 marketId_, PositionMetadata memory positionMetadata_) {
        morpho = IMorpho(morpho_);
        marketId = Id.wrap(marketId_);
        MarketParams memory marketParams = morpho.idToMarketParams(marketId);
        collateralToken = marketParams.collateralToken;
        loanToken = marketParams.loanToken;
        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        MarketParams memory marketParams = morpho.idToMarketParams(marketId);

        Position memory position = morpho.position(marketId, account);

        if (underlyingAsset == loanToken) {
            (
                uint256 totalSupplyAssets,
                uint256 totalSupplyShares,
                uint256 totalBorrowAssets,
                uint256 totalBorrowShares
            ) = morpho.expectedMarketBalances(marketParams);

            if (totalBorrowShares == 0 || totalSupplyShares == 0) {
                return 0;
            }

            uint256 borrowedAssets =
                totalBorrowAssets.mulDiv(position.borrowShares, totalBorrowShares, Math.Rounding.Ceil); // Round up to avoid
            // underestimating the debt

            uint256 suppliedAssets =
                totalSupplyAssets.mulDiv(position.supplyShares, totalSupplyShares, Math.Rounding.Floor); // Round down to
            // avoid overestimating the supply

            return suppliedAssets.toInt256() - borrowedAssets.toInt256();
        } else if (underlyingAsset == collateralToken) {
            return uint256(position.collateral).toInt256();
        } else {
            revert InvalidArguments();
        }
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](2);
        assets[0] = collateralToken;
        assets[1] = loanToken;
        return assets;
    }

    /// @inheritdoc IBalanceOracleCustom
    function positionMetadata() external view override returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
