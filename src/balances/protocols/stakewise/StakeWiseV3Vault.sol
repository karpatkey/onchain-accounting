// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StakeWise Vault Balance Oracle
/// @author kpk
/// @notice This contract tracks user positions in StakeWise vaults, calculating their net balance
/// by considering both their direct vault shares and any osToken debt positions.
/// The balance calculation works as follows:
/// 1. Gets the user's direct vault shares and converts them to underlying asset value
/// 2. Gets the user's osToken minted debt position (if any) and converts it to underlying asset value
/// 3. Returns the net balance as: vaultAssets - osTokenDebt
contract StakeWiseV3VaultBalanceOracle is IBalanceOracleAdapter {
    //
    // Libraries
    //
    using SafeCast for uint256;

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

    /// @notice The underlying token address
    address public immutable UNDERLYING_TOKEN;

    /// @notice The vault
    IStakeWiseVault public immutable VAULT;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice List of underlying assets supported by this oracle.
    address[] internal _underlyingAssetsSupported;
    /// @notice Reference to NAVCalculator for asset registry and pricing access
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param underlyingToken_ The address of the underlying token for this oracle.
    /// @param vault_ The address of the vault.
    /// @param protocol_ Protocol identifier (e.g., "Stakewise v3").
    /// @param positionDetail_ Position detail identifier (e.g., "Some vault").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(
        address underlyingToken_,
        address vault_,
        string memory protocol_,
        string memory positionDetail_,
        address navCalculator_
    ) {
        if (underlyingToken_ == address(0) || vault_ == address(0)) {
            revert InvalidArguments();
        }
        require(vault_.code.length > 0, "Vault must be a contract");
        require(navCalculator_.code.length > 0, "NAVCalculator must be a contract");

        UNDERLYING_TOKEN = underlyingToken_;
        VAULT = IStakeWiseVault(vault_);
        _protocol = protocol_;
        _positionDetail = positionDetail_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return amount Balance magnitude (non-negative)
    /// @return isDebt True if debt, false if credit
    function _calculateBalance(address underlyingAsset, address account)
        internal
        view
        returns (uint256 amount, bool isDebt)
    {
        if (underlyingAsset != address(UNDERLYING_TOKEN)) {
            revert InvalidArguments();
        }

        uint256 directBalance = VAULT.getShares(account);
        uint256 osTokenPosition = VAULT.osTokenPositions(account);

        uint256 vaultAssets = VAULT.convertToAssets(directBalance);
        uint256 mintedOs = VAULT.convertToAssets(osTokenPosition);

        // Net: vaultAssets - mintedOs (can be negative)
        if (vaultAssets >= mintedOs) {
            return (vaultAssets - mintedOs, false);
        }
        return (mintedOs - vaultAssets, true);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
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
        if (asset == address(0) || asset != address(UNDERLYING_TOKEN)) {
            return (0, false);
        }
        return _calculateBalance(asset, account);
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        address[] memory tempAssets = new address[](assetCount);
        uint256[] memory tempAmounts = new uint256[](assetCount);
        bool[] memory tempIsDebt = new bool[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            (uint256 amount, bool isDebt_) = _calculateBalance(asset, account);
            if (amount != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = amount;
                tempIsDebt[count] = isDebt_;
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
    /// @notice Returns balance-only positions for the account's StakeWise V3 Vault positions
    /// @dev Returns PositionBalance structs (balance-only data) without pricing information.
    /// @dev NAVCalculator enriches these positions with pricing data to create full Position structs.
    /// @dev Only returns positions for assets that are both supported by StakeWise and registered in NAVCalculator.
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
            // Check if assetFilter is in the registered supported assets
            for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
                if (registeredSupportedAssets[i] == assetFilter) {
                    (uint256 amount, bool isDebt) = _calculateBalance(assetFilter, account);
                    if (amount != 0) {
                        assetBalanceData = new AssetBalanceData[](1);
                        assetBalanceData[0] = AssetBalanceData({asset: assetFilter, amount: amount, isDebt: isDebt});
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

/// @notice Interface for interacting with StakeWise v3 vaults
interface IStakeWiseVault {
    /// @notice Converts a given amount of vault shares to the underlying asset amount
    /// @param shares The amount of shares to convert
    /// @return The equivalent amount of underlying assets
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Gets the amount of vault shares owned by an account
    /// @param account The address to check shares for
    /// @return The amount of vault shares owned by the account
    function getShares(address account) external view returns (uint256);

    /// @notice Gets the amount of osTokens minted against an account's position
    /// @param account The address to check osToken positions for
    /// @return The amount of osTokens minted by the account (debt position)
    function osTokenPositions(address account) external view returns (uint256);
}
