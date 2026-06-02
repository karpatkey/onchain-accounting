// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title ERC-4626 Wrap Balance Oracle
/// @author kpk
/// @notice Generic balance oracle for any ERC-4626 share token whose `asset()` returns a
///         NAV-priced underlying. Reports the account's holding as
///         `convertToAssets(balanceOf(account))` denominated in `asset()`.
/// @dev Designed for thin ERC-4626 wrappers whose share price is derived purely from
///      `convertToAssets` — e.g. Savings GHO (`sGHO`, underlying GHO), Aave V3 stata-tokens,
///      and Maker DAI savings wrappers. Morpho ERC-4626 vaults have their own dedicated adapter
///      (`MorphoVaultBalanceOracle`) because the chain-config catalog tracks them as a distinct
///      family. Does not include any external reward streams (Merkl, URD).
contract ERC4626WrapBalanceOracle is IBalanceOracleAdapter {
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

    /// @notice The ERC-4626 wrapper contract
    IERC4626 public immutable WRAPPER;

    /// @notice The wrapper's underlying asset (cached from WRAPPER.asset() at construction)
    address public immutable ASSET;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param wrapper_ The address of the ERC-4626 wrapper (e.g. sGHO)
    /// @param protocol_ Protocol identifier (e.g., "Aave")
    /// @param positionDetail_ Position detail (e.g., "Savings GHO")
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access
    constructor(address wrapper_, string memory protocol_, string memory positionDetail_, address navCalculator_) {
        if (wrapper_ == address(0)) revert InvalidArguments();
        require(wrapper_.code.length > 0, "Wrapper must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        WRAPPER = IERC4626(wrapper_);
        ASSET = WRAPPER.asset();
        require(ASSET != address(0), "Wrapper asset must be non-zero");
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
    /// @notice Returns balance-only positions for the account's ERC-4626 wrapper position.
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns a position if the wrapper asset is registered in NAVCalculator.
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

        // Only proceed if the wrapper asset is registered in NAVCalculator
        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        AssetBalanceData[] memory assetBalanceData = new AssetBalanceData[](0);
        if (registeredSupportedAssets.length == 0) {
            assetBalanceData = new AssetBalanceData[](0);
        } else if (assetFilter != address(0)) {
            // Apply asset filter: only return a position if the filter matches the wrapper asset
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

    /// @notice Converts the account's wrapper shares to underlying assets via ERC4626 convertToAssets
    function _calculateBalance(address account) internal view returns (uint256) {
        return WRAPPER.convertToAssets(WRAPPER.balanceOf(account));
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
