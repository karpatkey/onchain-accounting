// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {IBalances} from "../IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Constructor
    //

    /// @param morpho_ The Morpho contract address.
    /// @param marketId_ The market id to query.
    /// @param protocol_ Protocol identifier (e.g., "Morpho").
    /// @param positionDetail_ Position detail identifier (e.g., "Market").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(
        address morpho_,
        bytes32 marketId_,
        string memory protocol_,
        string memory positionDetail_,
        address balances_
    ) {
        MORPHO = IMorpho(morpho_);
        MARKET_ID = Id.wrap(marketId_);
        MarketParams memory marketParams = MORPHO.idToMarketParams(MARKET_ID);
        COLLATERAL_TOKEN = marketParams.collateralToken;
        LOAN_TOKEN = marketParams.loanToken;
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        BALANCES = IBalances(balances_);
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
        // Sum all balances for this asset across all positions
        // _buildPositions with asset filter already returns only positions for this asset
        INAVCalculator.Position[] memory positions = _buildPositions(account, asset);
        for (uint256 i = 0; i < positions.length; i++) {
            balance += positions[i].balance;
        }
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

    /// @notice Internal helper that builds all positions for this oracle
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of Position structs from this oracle
    function _buildPositions(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        if (assetCount == 0) {
            return new INAVCalculator.Position[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](assetCount);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];

            // Apply asset filter if specified
            if (assetFilter != address(0) && asset != assetFilter) {
                continue;
            }

            // Get balance for this asset
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero BALANCES
            if (balance != 0) {
                // Get asset info from registry (if registered)
                uint8 decimals;
                string memory symbol;
                try BALANCES.getAssetDecimals(asset) returns (uint8 dec) {
                    decimals = dec;
                } catch {
                    // Asset not registered, skip it (NAVCalculator will filter anyway)
                    continue;
                }
                try BALANCES.getAssetSymbol(asset) returns (string memory sym) {
                    symbol = sym;
                } catch {
                    symbol = "";
                }

                // Build underlying asset struct
                INAVCalculator.Asset memory underlyingAsset =
                    INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});

                // Build position (pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.Position({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    balance: balance,
                    quoteAsset: INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), // Will be set by NAVCalculator
                    value: 0, // Will be calculated by NAVCalculator
                    price: 0, // Will be set by NAVCalculator
                    priceDecimals: 0, // Will be set by NAVCalculator
                    stale: false, // Will be set by NAVCalculator
                    protocol: _protocol,
                    positionDetail: _positionDetail
                });

                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.Position[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        return _buildPositions(account, assetFilter);
    }
}
