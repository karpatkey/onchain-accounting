// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "../IBalanceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "src/errors.sol";

/// @title ISavingsUSDS Interface
/// @notice Interface for interacting with the Savings USDS (sUSDS) vault
interface ISavingsUSDS is IERC4626 {
    /// @notice Returns the address of the underlying USDS token
    /// @return Address of the USDS stablecoin
    function usds() external view returns (address);
}

/// @title SavingsUSDS Balance Oracle
/// @notice Balance oracle for Savings USDS (sUSDS), an ERC4626 yield-bearing vault for USDS stablecoin
/// This contract provides balance information by converting sUSDS vault shares to their underlying USDS value
contract SkySavingsUsdsBalanceOracle is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;

    //
    // State
    //

    /// @notice The underlying USDS stablecoin address
    address public immutable USDS;

    /// @notice The Savings USDS (sUSDS) vault contract
    ISavingsUSDS public immutable SAVINGS_USDS;

    /// @notice Position tags associated with the balance oracle.
    PositionMetadata internal _positionMetadata;

    //
    // Constructor
    //

    /// @notice Initializes the balance oracle for Savings USDS. Reverts if savingsUsds_ is zero address
    /// @param savingsUsds_ Address of the Savings USDS (sUSDS) vault contract
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(address savingsUsds_, PositionMetadata memory positionMetadata_) {
        if (savingsUsds_ == address(0)) revert InvalidArguments();
        SAVINGS_USDS = ISavingsUSDS(savingsUsds_);
        USDS = SAVINGS_USDS.usds();
        _positionMetadata = positionMetadata_;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address account) external view returns (int256) {
        // Ensure token matches the underlying USDS token
        if (underlyingAsset != USDS) {
            revert InvalidArguments();
        }
        // Get user's sUSDS balance and convert to underlying USDS amount:
        // 1. balanceOf() - Get user's sUSDS vault shares
        // 2. convertToAssets() - Convert shares to USDS based on current exchange rate
        // 3. toInt256() - Convert uint256 to int256 for interface compatibility
        return SAVINGS_USDS.convertToAssets(SAVINGS_USDS.balanceOf(account)).toInt256();
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = USDS; // Only USDS is supported
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
