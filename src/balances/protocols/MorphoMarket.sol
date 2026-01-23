// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayUtils} from "src/utils/ArrayUtils.sol";
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
        int256 balance;
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
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param morpho_ The Morpho contract address.
    /// @param marketId_ The market id to query.
    /// @param protocol_ Protocol identifier (e.g., "Morpho").
    /// @param positionDetail_ Position detail identifier (e.g., "Market").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(
        address morpho_,
        bytes32 marketId_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        MORPHO = IMorpho(morpho_);
        MARKET_ID = Id.wrap(marketId_);
        MarketParams memory marketParams = MORPHO.idToMarketParams(MARKET_ID);
        COLLATERAL_TOKEN = marketParams.collateralToken;
        LOAN_TOKEN = marketParams.loanToken;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance
    function _calculateBalance(address underlyingAsset, address account) internal view returns (int256) {
        MarketParams memory marketParams = MORPHO.idToMarketParams(MARKET_ID);

        Position memory position = MORPHO.position(MARKET_ID, account);

        if (underlyingAsset == LOAN_TOKEN) {
            (
                uint256 totalSupplyAssets,
                uint256 totalSupplyShares,
                uint256 totalBorrowAssets,
                uint256 totalBorrowShares
            ) = MORPHO.expectedMarketBalances(marketParams);

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
        } else if (underlyingAsset == COLLATERAL_TOKEN) {
            return uint256(position.collateral).toInt256();
        } else {
            revert InvalidArguments();
        }
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
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance) {
        // Optimized: directly calculate balance without building full Position structs
        balance = _calculateBalance(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero BALANCES
            if (balance != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = balance;
                count++;
            }
        }

        // Resize to actual count
        assets = new address[](count);
        amounts = new int256[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
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
        address[] memory registeredAssets = NAV_CALCULATOR.assets();

        // Find intersection: assets that are both supported and registered
        address[] memory registeredSupportedAssets = ArrayUtils.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData;
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    int256 balance = _calculateBalance(assetFilter, account);
                    if (balance != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, balance: balance});
                    } else {
                        assetBalanceData = new AssetBalanceData[](0);
                    }
                    break;
                }
            }
        } else {
            // Pre-allocate temporary array (max size)
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                int256 balance = _calculateBalance(registeredSupportedAssets[i], account);
                if (balance != 0) {
                    tempData[count] = AssetBalanceData({asset: registeredSupportedAssets[i], balance: balance});
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
        uint256 assetCount = NAV_CALCULATOR.assetCount();
        for (uint256 i = 0; i < assetCount; i++) {
            INAVCalculator.Asset memory a = NAV_CALCULATOR.assetAt(i);
            if (a.asset == asset) {
                return a;
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
                balance: assetBalanceData[i].balance,
                protocol: _protocol,
                positionDetail: _positionDetail
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
