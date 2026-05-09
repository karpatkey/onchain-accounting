// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "../IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionType} from "src/utils/PositionType.sol";

/// @title StakeWise Vault Balance Oracle
/// @author kpk
/// @notice Tracks user positions in StakeWise V3 vaults.
/// @dev `getOraclePositions` emits two legs per asset when both are present:
///        - type "Staking" (isDebt=false): direct vault shares converted to underlying assets
///        - type "Borrow"  (isDebt=true):  osToken debt position converted to underlying assets
///      `getOracleBalanceForAsset` and `getOracleBalances` return the signed net (staking − debt)
///      for simple balance queries and backward compatibility.
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
    /// @notice JSON metadata base (no closing `}`)
    string private _positionDetail;
    /// @notice Stable hex identifier for this adapter instance (vault address)
    string private _positionId;
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
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (vault address).
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry and pricing access
    constructor(
        address underlyingToken_,
        address vault_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
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
        _positionId = positionId_;
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    /// @notice Returns the gross staking and borrow amounts separately.
    function _getGrossBalances(address underlyingAsset, address account)
        internal
        view
        returns (uint256 vaultAssets, uint256 mintedOs)
    {
        if (underlyingAsset != address(UNDERLYING_TOKEN)) revert InvalidArguments();
        vaultAssets = VAULT.convertToAssets(VAULT.getShares(account));
        mintedOs = VAULT.convertToAssets(VAULT.osTokenPositions(account));
    }

    /// @notice Returns the signed net balance (staking − debt) for simple balance queries.
    function _calculateBalance(address underlyingAsset, address account)
        internal
        view
        returns (uint256 amount, bool isDebt)
    {
        (uint256 vaultAssets, uint256 mintedOs) = _getGrossBalances(underlyingAsset, account);
        if (vaultAssets >= mintedOs) return (vaultAssets - mintedOs, false);
        return (mintedOs - vaultAssets, true);
    }

    /// @notice Returns the positionDetail JSON for a given leg.
    function _positionDetailFor(bool isDebt_) internal view returns (string memory) {
        return isDebt_
            ? PositionType.withType(_positionDetail, PositionType.BORROW)
            : PositionType.withType(_positionDetail, PositionType.STAKING);
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
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        address[] memory supportedAssets = this.underlyingAssetsSupported();
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory registeredAssets = new address[](reg.length);
        for (uint256 i = 0; i < reg.length; i++) {
            registeredAssets[i] = reg[i].asset;
        }

        address[] memory registeredSupportedAssets = ArrayLib.intersection(supportedAssets, registeredAssets);

        // Up to 2 legs per asset (Staking + Borrow).
        AssetBalanceData[] memory tempData = new AssetBalanceData[](registeredSupportedAssets.length * 2);
        uint256 count = 0;

        for (uint256 i = 0; i < registeredSupportedAssets.length; i++) {
            address asset = registeredSupportedAssets[i];
            if (assetFilter != address(0) && asset != assetFilter) continue;
            (uint256 vaultAssets, uint256 mintedOs) = _getGrossBalances(asset, account);
            if (vaultAssets > 0) {
                tempData[count++] = AssetBalanceData({asset: asset, amount: vaultAssets, isDebt: false});
            }
            if (mintedOs > 0) {
                tempData[count++] = AssetBalanceData({asset: asset, amount: mintedOs, isDebt: true});
            }
        }

        AssetBalanceData[] memory assetBalanceData = new AssetBalanceData[](count);
        for (uint256 i = 0; i < count; i++) {
            assetBalanceData[i] = tempData[i];
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
                positionDetail: _positionDetailFor(assetBalanceData[i].isDebt),
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
