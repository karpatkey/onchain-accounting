// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
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
contract MorphoMarketBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using Math for uint256;
    using SafeCast for uint256;
    using MorphoBalancesLib for IMorpho;

    //
    // Type Definitions
    //

    /// @notice Asset balance data structure
    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice The Morpho contract
    IMorpho public immutable MORPHO;

    /// @notice The market id to query
    Id public immutable MARKET_ID;

    /// @notice The collateral token address
    address public immutable COLLATERAL_TOKEN;

    /// @notice The loan token address
    address public immutable LOAN_TOKEN;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice JSON metadata base (no closing `}`)
    string private _positionDetail;
    /// @notice Stable hex identifier for this adapter instance (marketId as hex)
    string private _positionId;
    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param morpho_ The Morpho contract address.
    /// @param marketId_ The market id to query.
    /// @param protocol_ Protocol identifier (e.g., "Morpho").
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (marketId as hex string).
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(
        address morpho_,
        bytes32 marketId_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) {
        require(morpho_.code.length > 0, "Morpho must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        MORPHO = IMorpho(morpho_);
        MARKET_ID = Id.wrap(marketId_);
        MarketParams memory marketParams = MORPHO.idToMarketParams(MARKET_ID);
        COLLATERAL_TOKEN = marketParams.collateralToken;
        LOAN_TOKEN = marketParams.loanToken;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        _positionId = positionId_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Returns the positionDetail JSON string for a given asset and debt flag.
    function _positionDetailFor(address asset, bool isDebt) internal view returns (string memory) {
        if (asset == COLLATERAL_TOKEN) {
            return string.concat(_positionDetail, ",\"type\":\"Collateral\"}");
        }
        if (asset == LOAN_TOKEN) {
            return isDebt
                ? string.concat(_positionDetail, ",\"type\":\"Borrow\"}")
                : string.concat(_positionDetail, ",\"type\":\"Supply\"}");
        }
        return string.concat(_positionDetail, "}");
    }

    /// @notice Internal helper to calculate balance for a specific asset.
    /// @dev Uses Morpho's `expectedMarketBalances` (projected) rather than `market(id)` (stored).
    ///      That folds IRM-implied interest accrued since `lastUpdate` into both
    ///      `totalSupplyAssets` and `totalBorrowAssets`, so the user's share fraction
    ///      maps to the same number of assets they would receive on next interaction.
    ///      This is the same convention Morpho's UI uses, but it diverges from indexers
    ///      (e.g. Debank) that report stored values: for markets that haven't been touched
    ///      in a long time at high utilization, our NAV will exceed indexer-based readings
    ///      by the projected delta. This is intentional and tracked in
    ///      `docs/decisions/0004-morpho-projected-vs-stored-balances.md` — read that ADR
    ///      before changing the call.
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return amount Balance magnitude (non-negative)
    /// @return isDebt True if debt, false if credit
    function _calculateBalance(address underlyingAsset, address account)
        internal
        view
        returns (uint256 amount, bool isDebt)
    {
        MarketParams memory marketParams = MORPHO.idToMarketParams(MARKET_ID);

        Position memory position = MORPHO.position(MARKET_ID, account);

        if (underlyingAsset == LOAN_TOKEN) {
            (
                uint256 totalSupplyAssets,
                uint256 totalSupplyShares,
                uint256 totalBorrowAssets,
                uint256 totalBorrowShares
            ) = MORPHO.expectedMarketBalances(marketParams);

            uint256 suppliedAssets = 0;
            if (totalSupplyShares != 0 && position.supplyShares != 0) {
                suppliedAssets = totalSupplyAssets.mulDiv(position.supplyShares, totalSupplyShares, Math.Rounding.Floor); // Round down to avoid overestimating the supply
            }

            uint256 borrowedAssets = 0;
            if (totalBorrowShares != 0 && position.borrowShares != 0) {
                borrowedAssets = totalBorrowAssets.mulDiv(position.borrowShares, totalBorrowShares, Math.Rounding.Ceil); // Round up to avoid underestimating the debt
            }

            // Net: supplied - borrowed (can be negative)
            if (suppliedAssets >= borrowedAssets) {
                return (suppliedAssets - borrowedAssets, false);
            }
            return (borrowedAssets - suppliedAssets, true);
        }
        if (underlyingAsset == COLLATERAL_TOKEN) {
            return (uint256(position.collateral), false); // Collateral is always credit
        }
        revert InvalidArguments();
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](2);
        assets[0] = COLLATERAL_TOKEN;
        assets[1] = LOAN_TOKEN;
        return assets;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt)
    {
        return _calculateBalance(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        bool[] memory tempIsDebt = new bool[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            (uint256 amt, bool debt) = _calculateBalance(asset, account);
            if (amt != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = amt;
                tempIsDebt[count] = debt;
                count++;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
            isDebt[i] = tempIsDebt[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Morpho positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by Morpho and registered in NAVCalculator.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData;
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            assetBalanceData = new AssetBalanceData[](0);
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    (uint256 amount, bool isDebt) = _calculateBalance(assetFilter, account);
                    if (amount != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: amount, isDebt: isDebt});
                    }
                    break;
                }
            }
        } else {
            // Pre-allocate temporary array (max size)
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                (uint256 amount, bool isDebt) = _calculateBalance(registeredSupportedAssets[i], account);
                if (amount != 0) {
                    tempData[count] =
                        AssetBalanceData({asset: registeredSupportedAssets[i], amount: amount, isDebt: isDebt});
                    count++;
                }
            }

            // Resize to actual count
            assetBalanceData = new AssetBalanceData[](count);
            for (uint256 i = 0; i < count; i++) {
                assetBalanceData[i] = tempData[i];
            }
        }
        positions = _buildPositions(assetBalanceData);
    }

    //
    // Internal Functions - Asset Registry & Lookup
    //

    /// @notice Gets asset information from NAVCalculator by iterating through registered assets
    /// @param asset The asset address to look up
    /// @return assetInfo The Asset struct containing asset address, symbol, and decimals
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory assetInfo) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) {
                return reg[i];
            }
        }
        revert("Asset not found in NAVCalculator");
    }

    //
    // Internal Functions - Position Building
    //

    /// @notice Internal helper that builds all positions for this oracle
    /// @param assetBalanceData Array of AssetBalanceData to build positions from
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev All assets are guaranteed to be registered (filtered in getOraclePositions).
    function _buildPositions(AssetBalanceData[] memory assetBalanceData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetBalanceData.length == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array
        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](assetBalanceData.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetBalanceData.length; i++) {
            address asset = assetBalanceData[i].asset;

            // Get asset info from NAVCalculator (all assets are guaranteed to be registered)
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(asset);

            // Build position (balance-only, pricing will be added by NAVCalculator)
            tempPositions[positionCount] = INAVCalculator.PositionBalance({
                underlyingAsset: underlyingAsset,
                balanceOracle: address(this),
                amount: assetBalanceData[i].amount,
                isDebt: assetBalanceData[i].isDebt,
                protocol: _protocol,
                positionDetail: _positionDetailFor(asset, assetBalanceData[i].isDebt),
                positionId: _positionId
            });

            positionCount++;
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
}
