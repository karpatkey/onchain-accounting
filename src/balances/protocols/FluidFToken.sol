// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title Fluid fToken Balance Oracle
/// @author kpk
/// @notice Returns the underlying-asset balance for an account's Fluid Lending fToken position,
///         converting shares to underlying via ERC4626 `convertToAssets()`.
/// @dev Fluid fTokens (e.g. fUSDC, fWETH, fUSDT) are fully ERC4626-compliant — see
///      `Instadapp/fluid-contracts-public/contracts/protocols/lending/fToken/main.sol`.
///      Lending APY accrues via share-price growth on `convertToAssets()`; FLUID/Merkl reward
///      emissions are NOT included here (separate Merkl adapter).
contract FluidFTokenBalanceOracle is IBalanceOracleAdapter {
    //
    // Type Definitions
    //

    struct AssetBalanceData {
        address asset;
        uint256 amount;
        bool isDebt;
    }

    //
    // State
    //

    /// @notice The Fluid fToken (ERC4626 vault) contract
    IERC4626 public immutable F_TOKEN;

    /// @notice The fToken's underlying asset (cached from F_TOKEN.asset() at construction)
    address public immutable ASSET;

    /// @notice Reference to NAVCalculator for asset registry access
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier (e.g. "Fluid Lending")
    string private _protocol;
    /// @notice Position detail (e.g. "fUSDC")
    string private _positionDetail;

    //
    // Constructor
    //

    /// @param fToken_ The Fluid Lending fToken contract address (ERC4626).
    /// @param protocol_ Protocol identifier (e.g. "Fluid Lending").
    /// @param positionDetail_ Position detail (e.g. "fUSDC").
    /// @param navCalculator_ NAVCalculator address (asset registry source).
    constructor(address fToken_, string memory protocol_, string memory positionDetail_, address navCalculator_) {
        if (fToken_ == address(0)) revert InvalidArguments();
        require(fToken_.code.length > 0, "fToken must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        F_TOKEN = IERC4626(fToken_);
        ASSET = F_TOKEN.asset();
        require(ASSET != address(0), "fToken asset must be non-zero");
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        return assets;
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != ASSET) return (0, false);
        return (_calculateBalance(account), false);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 balance = _calculateBalance(account);

        if (balance == 0) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = ASSET;
        amounts[0] = balance;
        isDebt[0] = false;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns balance-only positions for the account's Fluid Lending position.
    /// @dev Only emits a position if the underlying asset is registered in NAVCalculator.
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

        // Only proceed if the fToken's underlying asset is registered in NAVCalculator
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData = new AssetBalanceData[](0);
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            // Apply asset filter: only emit a position if the filter matches the underlying
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    uint256 balance = _calculateBalance(account);
                    if (balance != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: balance, isDebt: false});
                    } else {
                        assetBalanceData = new AssetBalanceData[](0);
                    }
                    break;
                }
            }
        } else {
            AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length);
            uint256 count = 0;

            uint256 balance = _calculateBalance(account);
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (balance != 0) {
                    tempData[count] =
                        AssetBalanceData({asset: registeredSupportedAssets[i], amount: balance, isDebt: false});
                    count++;
                }
            }

            assetBalanceData = new AssetBalanceData[](count);
            for (uint256 i = 0; i < count; i++) {
                assetBalanceData[i] = tempData[i];
            }
        }

        positions = _buildPositions(assetBalanceData);
    }

    //
    // Internal Helpers
    //

    /// @notice Converts the account's fToken shares to underlying assets via ERC4626 convertToAssets
    function _calculateBalance(address account) internal view returns (uint256) {
        return F_TOKEN.convertToAssets(F_TOKEN.balanceOf(account));
    }

    /// @notice Looks up asset metadata from the NAVCalculator registry
    function _getAssetInfo(address asset) internal view returns (INAVCalculator.Asset memory) {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return reg[i];
        }
        revert("Asset not found in NAVCalculator");
    }

    /// @notice Builds PositionBalance array from pre-computed asset balance data
    function _buildPositions(AssetBalanceData[] memory assetBalanceData)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (assetBalanceData.length == 0) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory tempPositions =
            new INAVCalculator.PositionBalance[](assetBalanceData.length);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetBalanceData.length; i++) {
            INAVCalculator.Asset memory underlyingAsset = _getAssetInfo(assetBalanceData[i].asset);

            tempPositions[positionCount] = INAVCalculator.PositionBalance({
                underlyingAsset: underlyingAsset,
                balanceOracle: address(this),
                amount: assetBalanceData[i].amount,
                isDebt: assetBalanceData[i].isDebt,
                protocol: _protocol,
                positionDetail: _positionDetail
            });
            positionCount++;
        }

        positions = new INAVCalculator.PositionBalance[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
}
