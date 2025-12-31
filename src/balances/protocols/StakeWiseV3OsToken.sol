// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title StakeWise osToken Balance Oracle
/// @author kpk
/// @notice Returns the underlying token equivalent balance for a given amount of StakeWise osTokens held by an account.
/// @dev Queries the osToken contract for the user's share balance, then uses the vault controller's `convertToAssets`
///      to compute the equivalent amount of the underlying asset.
contract StakeWiseV3OsTokenBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The osToken whose balance this oracle wraps.
    address public immutable osToken;

    /// @notice The underlying token of the osToken for which we compute equivalent balances.
    address public immutable underlyingToken;

    /// @notice Position metadata tags describing the DeFi position this oracle is associated to.
    PositionMetadata internal _positionMetadata;

    /// @notice The StakeWise vault controller contract interface
    IOsTokenVaultController public immutable osTokenVaultController;

    //
    // Constructor
    //

    /// @param osToken_ The address of the osToken.
    /// @param underlyingToken_ The address of the underlying asset.
    /// @param osTokenvaultController_ The address of the OsTokenVaultController.
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(
        address osToken_,
        address underlyingToken_,
        address osTokenvaultController_,
        PositionMetadata memory positionMetadata_
    ) {
        if (osToken_ == address(0) || underlyingToken_ == address(0) || osTokenvaultController_ == address(0)) {
            revert InvalidArguments();
        }
        osToken = osToken_;
        underlyingToken = underlyingToken_;
        osTokenVaultController = IOsTokenVaultController(osTokenvaultController_);
        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        if (underlyingAsset != underlyingToken) {
            revert InvalidArguments();
        }
        uint256 sharesAmount = IERC20(osToken).balanceOf(account);
        uint256 underlyingAmount = osTokenVaultController.convertToAssets(sharesAmount);
        return underlyingAmount.toInt256();
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

/// @notice Interface for interacting with StakeWise v3 osToken Vault Controllers
interface IOsTokenVaultController {
    /// @notice Converts a given amount of vault shares to the underlying asset amount
    /// @param shares The amount of shares to convert
    /// @return assets The equivalent amount of underlying assets
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
