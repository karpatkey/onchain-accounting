// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

contract Mock_CustomBalanceAdapter is IBalanceAdapter {
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
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amountOut, bool isDebtOut)
    {
        (amountOut, isDebtOut) = this.balanceOf(asset, account);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
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

        uint256 count =
            _populateBalanceArrays(account, supportedAssets, assetCount, tempAssets, tempAmounts, tempIsDebt);

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

    /// @notice Helper to populate balance arrays
    /// @param account The account to query
    /// @param supportedAssets Array of supported assets
    /// @param assetCount Number of assets
    /// @param tempAssets Temporary assets array
    /// @param tempAmounts Temporary amounts array
    /// @param tempIsDebt Temporary debt flags array
    /// @return count The number of non-zero balances found
    function _populateBalanceArrays(
        address account,
        address[] memory supportedAssets,
        uint256 assetCount,
        address[] memory tempAssets,
        uint256[] memory tempAmounts,
        bool[] memory tempIsDebt
    ) internal view returns (uint256 count) {
        count = 0;
        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            // Directly access storage to avoid stack depth issues
            uint256 amount = amounts[asset][account];
            bool debt = isDebt[asset][account];

            // Only include non-zero balances
            if (amount != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = amount;
                tempIsDebt[count] = debt;
                count++;
            }
        }
    }

    /// @notice Internal helper that builds all positions for this adapter
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of balance-only PositionBalance structs from this adapter
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

            // Get balance for this asset (directly from storage to avoid stack depth)
            uint256 amount = amounts[asset][account];
            bool debt = isDebt[asset][account];

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

                // Build balance asset struct
                INAVCalculator.Asset memory balanceAsset =
                    INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});

                // Build position (balance-only, pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.PositionBalance({
                    balanceAsset: balanceAsset,
                    balanceAdapter: address(this),
                    amount: amount,
                    isDebt: debt,
                    protocolId: bytes32(0),
                    positionId: abi.encode(address(this)),
                    positionKind: debt ? PositionKind.Borrowed : PositionKind.Supplied
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

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns balance-only positions for the account
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        positions = _buildPositions(account, assetFilter);
    }
}
