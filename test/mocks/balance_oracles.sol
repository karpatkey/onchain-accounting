// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Mock_CustomBalanceOracle is IBalanceOracleAdapter {
    mapping(address => mapping(address => uint256)) public amounts;
    mapping(address => mapping(address => bool)) public isDebt;
    address[] public underlyingAassetsSupported;
    string internal _protocol;
    string internal _positionDetail;
    IBalances public balances;

    constructor() {}

    function setBalances(IBalances balances_) external {
        balances = balances_;
    }

    function setBalance(address token, address account, uint256 amount, bool debt) external {
        amounts[token][account] = amount;
        isDebt[token][account] = debt;
    }

    function balanceOf(address token, address account) external view returns (uint256 amount, bool debt) {
        return (amounts[token][account], isDebt[token][account]);
    }

    function setUnderlyingAssetsSupported(address[] calldata underlyingAssets) external {
        for (uint256 i = 0; i < underlyingAssets.length; i++) {
            underlyingAassetsSupported.push(underlyingAssets[i]);
        }
    }

    function underlyingAssetsSupported() external view returns (address[] memory) {
        return underlyingAassetsSupported;
    }

    function setPositionMetadata(string memory protocol, string memory positionDetail) external {
        _protocol = protocol;
        _positionDetail = positionDetail;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amountOut, bool isDebtOut)
    {
        (amountOut, isDebtOut) = this.balanceOf(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amountsOut, bool[] memory isDebtOut)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        bool[] memory tempIsDebt = new bool[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            (uint256 amount, bool debt) = this.balanceOf(asset, account);

            // Only include non-zero balances
            if (amount != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = amount;
                tempIsDebt[count] = debt;
                count++;
            }
        }

        // Resize to actual count
        assets = new address[](count);
        amountsOut = new uint256[](count);
        isDebtOut = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amountsOut[i] = tempAmounts[i];
            isDebtOut[i] = tempIsDebt[i];
        }
    }

    /// @notice Internal helper that builds all positions for this oracle
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    function _buildPositions(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        if (assetCount == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.PositionBalance[] memory tempPositions = new INAVCalculator.PositionBalance[](assetCount);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];

            // Apply asset filter if specified
            if (assetFilter != address(0) && asset != assetFilter) {
                continue;
            }

            // Get balance for this asset
            (uint256 amount, bool debt) = this.balanceOf(asset, account);

            // Only include non-zero amounts
            if (amount != 0) {
                // Get asset info from registry (if registered) or from token directly
                uint8 decimals;
                string memory symbol;
                if (address(balances) != address(0)) {
                    // Check if asset is registered
                    if (!INAVCalculator(address(balances)).isAssetRegistered(asset)) {
                        // Asset not registered, skip it (NAVCalculator will filter anyway)
                        continue;
                    }
                    // Get asset info from registered assets
                    INAVCalculator.Asset[] memory assets = INAVCalculator(address(balances)).getRegisteredAssets();
                    bool found = false;
                    for (uint256 j = 0; j < assets.length; j++) {
                        if (assets[j].asset == asset) {
                            decimals = assets[j].decimals;
                            symbol = assets[j].symbol;
                            found = true;
                            break;
                        }
                    }
                    if (!found) continue;
                } else {
                    // Fallback to ERC20 metadata if balances not set
                    try IERC20Metadata(asset).decimals() returns (uint8 dec) {
                        decimals = dec;
                    } catch {
                        // Asset not registered, skip it (NAVCalculator will filter anyway)
                        continue;
                    }
                    try IERC20Metadata(asset).symbol() returns (string memory sym) {
                        symbol = sym;
                    } catch {
                        symbol = "";
                    }
                }

                // Build underlying asset struct
                INAVCalculator.Asset memory underlyingAsset =
                    INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});

                // Build position (balance-only, pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    amount: amount,
                    isDebt: debt,
                    protocol: _protocol,
                    positionDetail: _positionDetail
                });

                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = _buildPositions(account, assetFilter);
    }
}
