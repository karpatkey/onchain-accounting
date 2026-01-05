// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "src/errors.sol";

/// @title StakeWise Vault Balance Oracle
/// @author kpk
/// @notice This contract tracks user positions in StakeWise vaults, calculating their net balance
/// by considering both their direct vault shares and any osToken debt positions.
/// The balance calculation works as follows:
/// 1. Gets the user's direct vault shares and converts them to underlying asset value
/// 2. Gets the user's osToken minted debt position (if any) and converts it to underlying asset value
/// 3. Returns the net balance as: vaultAssets - osTokenDebt
contract StakeWiseV3VaultBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The underlying token address
    address public immutable underlyingToken;

    /// @notice The vault
    IStakeWiseVault public immutable vault;

    /// @notice Position tags associated with the balance oracle.
    PositionMetadata internal _positionMetadata;

    /// @notice List of underlying assets supported by this oracle.
    address[] internal _underlyingAssetsSupported;

    //
    // Constructor
    //

    /// @param underlyingToken_ The address of the underlying token for this oracle.
    /// @param vault_ The address of the vault.
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(address underlyingToken_, address vault_, PositionMetadata memory positionMetadata_) {
        if (underlyingToken_ == address(0) || vault_ == address(0)) revert InvalidArguments();
        underlyingToken = underlyingToken_;
        vault = IStakeWiseVault(vault_);
        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view override returns (int256 balance) {
        if (underlyingAsset != address(underlyingToken)) {
            revert InvalidArguments();
        }

        uint256 directBalance = vault.getShares(account);
        uint256 osTokenPosition = vault.osTokenPositions(account);

        uint256 vaultAssets = vault.convertToAssets(directBalance);
        uint256 mintedOs = vault.convertToAssets(osTokenPosition);

        return vaultAssets.toInt256() - mintedOs.toInt256();
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = underlyingToken;
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
