// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/errors.sol";

/// @title CompoundV3Comet
/// @notice This contract provides an implementation of a balance oracle for a Compound V3 Comet.
///   This balance oracle can return the base token, collateral assets, and owed rewards for a user on a given Comet
/// contract.
contract CompoundV3CometWithMultiplier is IBalanceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;

    //
    // Constants
    //

    /// @notice Scale factor used to normalize the balance values.
    /// Derived from the CometCore contract
    /// https://github.com/compound-finance/comet/blob/f41fec9858ae7e53be6cde96c74c3fa16782fa2a/contracts/CometCore.sol#L51
    int64 public constant BASE_INDEX_SCALE = 1e15;

    /// @dev The scale for factors
    /// Derived from CometCore contract
    /// https://github.com/compound-finance/comet/blob/1d30582704b16930275806337f2efe4984f5ed32/contracts/CometCore.sol#L56C5-L57
    uint64 public constant FACTOR_SCALE = 1e18;

    /// @dev The scale for base tracking accrual
    /// Derived from CometCore contract
    /// https://github.com/compound-finance/comet/blob/1d30582704b16930275806337f2efe4984f5ed32/contracts/CometCore.sol#L47C1-L48C55
    uint64 public constant BASE_ACCRUAL_SCALE = 1e6;

    //
    // State
    //

    /// @notice The Compound rewards contract.
    ICompoundRewards public immutable compoundRewards;

    /// @notice The Compound reward token.
    IERC20 public immutable rewardToken;

    /// @notice The Comet base token.
    address public immutable baseToken;

    /// @notice The Comet contract address.
    address public immutable comet;

    /// @notice The CometExtInterface contract address.
    CometExtInterface public immutable cometExtInterface;

    /// @notice The descale factor for the accrual.
    uint256 public immutable accrualDescaleFactor;

    /// @notice List of collateral asset addresses for this comet.
    address[] public collaterals;
    /// @notice Mapping to check if an asset is collateral.
    mapping(address asset => bool collateral) public isCollateral;

    /// @notice Position metadata tags describing the DeFi position this oracle is associated to.
    PositionMetadata private _positionMetadata;

    //
    // Errors
    //

    /// @notice Indicates that the provided arguments are invalid.
    error InvalidTimestamp();

    /// @param compoundRewards_ The address of the Compound rewards contract.
    /// @param comet_ The address of the Comet contract we want to get the balance of.
    /// @param rewardToken_ The address of the compound reward token contract.
    /// @param positionMetadata_ Metadata for the DeFi position associated with this oracle.
    constructor(
        address compoundRewards_,
        address comet_,
        address rewardToken_,
        PositionMetadata memory positionMetadata_
    ) {
        if (compoundRewards_ == address(0) || comet_ == address(0) || rewardToken_ == address(0)) {
            revert InvalidArguments();
        }
        compoundRewards = ICompoundRewards(compoundRewards_);
        rewardToken = IERC20(rewardToken_);

        baseToken = CometInterface(comet_).baseToken();
        comet = comet_;
        cometExtInterface = CometExtInterface(comet_);

        // https://etherscan.io/address/0x1B0e765F6224C21223AeA2af16c1C46E38885a40#code
        accrualDescaleFactor = cometExtInterface.baseScale() / BASE_ACCRUAL_SCALE;

        uint8 assetCount = CometExtInterface(comet_).numAssets();

        for (uint8 i = 0; i < assetCount; i++) {
            (, address asset,,,,,,) = CometExtInterface(comet).getAssetInfo(i);
            isCollateral[asset] = true;
            collaterals.push(asset);
        }

        _positionMetadata = positionMetadata_;
    }

    /// @notice Returns the number of collateral assets for the Comet contract.
    /// @return The number of collateral assets
    function getCollateralsCount() external view returns (uint256) {
        return collaterals.length;
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IBalanceOracleCustom
    function balanceOf(address underlyingAsset, address safe) external view returns (int256 balance) {
        if (underlyingAsset != address(rewardToken) && underlyingAsset != baseToken && !isCollateral[underlyingAsset]) {
            revert InvalidArguments();
        }

        if (underlyingAsset == address(rewardToken)) {
            balance += _getRewardOwed(safe).toInt256();
        }

        if (underlyingAsset == baseToken) {
            balance += getUnderlying(comet, safe);
        }

        if (isCollateral[underlyingAsset]) {
            balance += CometExtInterface(comet).collateralBalanceOf(safe, underlyingAsset).toInt256();
        }

        return balance;
    }

    //
    // Internal API
    //

    /// @notice Calculates the underlying balance of the base token for a given account.
    /// @param comet_ The address of the Comet contract.
    /// @param src The address of the user's account.
    /// @return The underlying balance of the base token for the user.
    function getUnderlying(address comet_, address src) public view returns (int256) {
        (int104 principal,,,,) = CometExtInterface(comet_).userBasic(src);
        (,, uint64 baseSupplyIndex, uint64 baseBorrowIndex) = accrueInternal();

        int256 total;

        // https://github.com/compound-finance/comet/blob/f41fec9858ae7e53be6cde96c74c3fa16782fa2a/contracts/CometCore.sol#L90
        if (principal >= 0) {
            total = int256(principal) * uint256(baseSupplyIndex).toInt256().toInt64();
        } else {
            total = int256(principal) * uint256(baseBorrowIndex).toInt256().toInt64();
        }

        return total / BASE_INDEX_SCALE;
    }

    /// @notice Calculates the unclaimed rewards owed to a user for a given Comet contract.
    ///   This function is a modified version of the getRewardOwed function in the CompoundV3Comet
    ///   contract, which is part of the Balances system. The original function is not view, as it
    ///   calls the Comet contract's accrueAccount function, which updates the user's rewards.
    ///   https://etherscan.io/address/0x1B0e765F6224C21223AeA2af16c1C46E38885a40#code
    /// @param src The address of the user's account.
    /// @return The amount of rewards owed to the user.
    function _getRewardOwed(address src) internal view returns (uint256) {
        (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier) =
            compoundRewards.rewardConfig(comet);
        if (token == address(0)) return 0;

        uint256 claimed = compoundRewards.rewardsClaimed(comet, src);
        uint256 accrued = _getRewardAccrued(comet, src, shouldUpscale, rescaleFactor, multiplier);

        if (accrued > claimed) {
            unchecked {
                return accrued - claimed;
            }
        }

        return 0;
    }

    /// @notice The current timestamp
    /// @return The current timestamp
    function _getNowInternal() internal view virtual returns (uint40) {
        if (block.timestamp >= 2 ** 40) revert InvalidTimestamp();
        return uint40(block.timestamp);
    }

    /// @dev Multiply a number by a factor
    /// @param n The number to multiply
    /// @param factor The factor to multiply by
    /// @return The result of the multiplication
    function _mulFactor(uint256 n, uint256 factor) internal pure returns (uint256) {
        return n * factor / FACTOR_SCALE;
    }

    /// @dev Divide a number by an amount of base
    /// @param n The number to divide
    /// @param baseWei The base to divide by
    /// @return The result of the division
    function _divBaseWei(uint256 n, uint256 baseWei) internal view returns (uint256) {
        return n * cometExtInterface.baseScale() / baseWei;
    }

    /// @notice Calculate the accrued interest indices
    /// @param timeElapsed The time elapsed
    /// @param baseSupplyIndex The base supply index
    /// @param baseBorrowIndex The base borrow index
    /// @return baseSupplyIndex_ The base supply index
    /// @return baseBorrowIndex_ The base borrow index
    function _accruedInterestIndices(uint256 timeElapsed, uint64 baseSupplyIndex, uint64 baseBorrowIndex)
        internal
        view
        returns (uint64 baseSupplyIndex_, uint64 baseBorrowIndex_)
    {
        baseSupplyIndex_ = baseSupplyIndex;
        baseBorrowIndex_ = baseBorrowIndex;

        if (timeElapsed > 0) {
            uint256 utilization = cometExtInterface.getUtilization();
            uint256 supplyRate = cometExtInterface.getSupplyRate(utilization);
            uint256 borrowRate = cometExtInterface.getBorrowRate(utilization);
            baseSupplyIndex_ += _mulFactor(baseSupplyIndex_, supplyRate * timeElapsed).toUint64();
            baseBorrowIndex_ += _mulFactor(baseBorrowIndex_, borrowRate * timeElapsed).toUint64();
        }
    }

    /// @dev Accrue interest (and rewards) in base token supply and borrows
    /// @return The tracking supply index
    /// @return The tracking borrow index
    /// @return The base supply index
    /// @return The base borrow index
    function accrueInternal() public view returns (uint64, uint64, uint64, uint64) {
        (
            uint64 baseSupplyIndex,
            uint64 baseBorrowIndex,
            uint64 trackingSupplyIndex,
            uint64 trackingBorrowIndex,
            uint104 totalSupplyBase,
            uint104 totalBorrowBase,
            uint40 lastAccrualTime,
        ) = cometExtInterface.totalsBasic();

        uint40 now_ = _getNowInternal();
        uint256 timeElapsed = uint256(now_ - lastAccrualTime);
        if (timeElapsed > 0) {
            (baseSupplyIndex, baseBorrowIndex) = _accruedInterestIndices(timeElapsed, baseSupplyIndex, baseBorrowIndex);
            uint256 baseMinForRewards = cometExtInterface.baseMinForRewards();

            if (totalSupplyBase >= baseMinForRewards) {
                trackingSupplyIndex +=
                    _divBaseWei(cometExtInterface.baseTrackingSupplySpeed() * timeElapsed, totalSupplyBase).toUint64();
            }
            if (totalBorrowBase >= baseMinForRewards) {
                trackingBorrowIndex +=
                    _divBaseWei(cometExtInterface.baseTrackingBorrowSpeed() * timeElapsed, totalBorrowBase).toUint64();
            }
        }

        return (trackingSupplyIndex, trackingBorrowIndex, baseSupplyIndex, baseBorrowIndex);
    }

    /// @dev Write updated principal to store and tracking participation
    /// @param baseTrackingAccrued_ The base tracking accrued
    /// @param principal The principal
    /// @param baseTrackingIndex The base tracking index
    /// @param trackingSupplyIndex The tracking supply index
    /// @param trackingBorrowIndex The tracking borrow index
    /// @return baseTrackingAccrued The base tracking accrued
    function updateBasePrincipal(
        uint64 baseTrackingAccrued_,
        int104 principal,
        uint64 baseTrackingIndex,
        uint64 trackingSupplyIndex,
        uint64 trackingBorrowIndex
    ) public view returns (uint64 baseTrackingAccrued) {
        baseTrackingAccrued = baseTrackingAccrued_;

        if (principal >= 0) {
            uint256 indexDelta = uint256(trackingSupplyIndex - baseTrackingIndex);

            baseTrackingAccrued += (
                uint104(principal) * indexDelta / cometExtInterface.trackingIndexScale() / accrualDescaleFactor
            ).toUint64();
        } else {
            uint256 indexDelta = uint256(trackingBorrowIndex - baseTrackingIndex);
            baseTrackingAccrued += (
                uint104(-principal) * indexDelta / cometExtInterface.trackingIndexScale() / accrualDescaleFactor
            ).toUint64();
        }
    }

    /// @notice Calculates the total rewards accrued for a user in the Comet contract.
    /// @param comet_ The address of the Comet contract.
    /// @param account The address of the user's account.
    /// @param shouldUpscale Whether the rewards should be upscaled.
    /// @param rescaleFactor The factor by which to rescale the rewards.
    /// @param multiplier The multiplier to apply to the rewards.
    /// @return The total accrued rewards for the user.
    function _getRewardAccrued(
        address comet_,
        address account,
        bool shouldUpscale,
        uint64 rescaleFactor,
        uint256 multiplier
    ) internal view returns (uint256) {
        (uint64 trackingSupplyIndex, uint64 trackingBorrowIndex,,) = accrueInternal();

        (int104 principal, uint64 baseTrackingIndex, uint64 baseTrackingAccrued,,) =
            CometExtInterface(comet_).userBasic(account);

        (uint256 accrued) = updateBasePrincipal(
            baseTrackingAccrued, principal, baseTrackingIndex, trackingSupplyIndex, trackingBorrowIndex
        );

        if (shouldUpscale) {
            accrued *= rescaleFactor;
        } else {
            accrued /= rescaleFactor;
        }
        return accrued * multiplier / FACTOR_SCALE;
    }

    /// @inheritdoc IBalanceOracleCustom
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory assets = new address[](1);
        assets[0] = address(0); // FIXME
        return assets;
    }

    /// @inheritdoc IBalanceOracleCustom
    function positionMetadata() external view override returns (PositionMetadata memory) {
        return _positionMetadata;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IBalanceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title ICompoundRewards
/// @notice This interface defines the functions for interacting with Compound's rewards system.
interface ICompoundRewards {
    /// @notice Retrieves the reward configuration for a specific Comet contract (Compound's money market).
    /// @param comet The address of the Comet contract for which the reward configuration is requested.
    /// @return token The address of the reward token associated with the Comet contract.
    /// @return rescaleFactor A scaling factor to adjust the reward token's value.
    /// @return shouldUpscale A boolean indicating whether the reward token should be upscaled.
    /// @return multiplier A multiplier used to calculate the rewards
    function rewardConfig(address comet)
        external
        view
        returns (address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier);

    /// @notice Returns the amount of rewards that have been claimed by a specific user for a given Comet contract.
    /// @param comet The address of the Comet contract.
    /// @param src The address of the user whose claimed rewards are being queried.
    /// @return The total amount of rewards claimed by the user for the specified Comet contract.
    function rewardsClaimed(address comet, address src) external view returns (uint256);
}

/// @title CometExtInterface
/// @notice This interface defines the functions for interacting with the Comet protocol, a part of Compound's lending
/// system.
interface CometExtInterface {
    /// @notice Gets the balance of a specific collateral asset held by a user.
    /// @param account The address of the user account.
    /// @param asset The address of the collateral asset.
    /// @return The balance of the specified collateral asset held by the user.
    function collateralBalanceOf(address account, address asset) external view returns (uint256);

    /// @notice Fetches information about a specific asset within the Comet protocol.
    /// @param i The index of the asset in the protocol's asset list.
    /// @return offset The offset position of the asset in the protocol's data structure.
    /// @return asset The address of the asset.
    /// @return priceFeed The address of the price feed contract for the asset.
    /// @return scale A scaling factor used for the asset's price and calculations.
    /// @return borrowCollateralFactor The collateral factor for borrowing against this asset.
    /// @return liquidateCollateralFactor The collateral factor used during liquidation.
    /// @return liquidationFactor The factor applied to the asset during liquidation.
    /// @return supplyCap The maximum supply of this asset that the protocol allows.
    function getAssetInfo(uint8 i)
        external
        view
        returns (
            uint8 offset,
            address asset,
            address priceFeed,
            uint64 scale,
            uint64 borrowCollateralFactor,
            uint64 liquidateCollateralFactor,
            uint64 liquidationFactor,
            uint128 supplyCap
        );

    /// @notice Returns the total number of assets supported by the Comet protocol.
    /// @return The number of assets as a uint8.
    function numAssets() external view returns (uint8);

    /// @notice Fetches basic user data for a specific account in the protocol.
    /// @param account The address of the user account.
    /// @return principal The principal amount the user has borrowed.
    /// @return baseTrackingIndex The index used to track rewards accrual for the user.
    /// @return baseTrackingAccrued The total rewards accrued by the user.
    /// @return assetsIn The number of collateral assets the user has deposited.
    /// @return reserved Reserved field for future use or padding.
    function userBasic(address account)
        external
        view
        returns (
            int104 principal,
            uint64 baseTrackingIndex,
            uint64 baseTrackingAccrued,
            uint16 assetsIn,
            uint8 reserved
        );

    /// @notice Fetches basic protocol-wide statistics.
    /// @return baseSupplyIndex The index used for calculating interest on supplied assets.
    /// @return baseBorrowIndex The index used for calculating interest on borrowed assets.
    /// @return trackingSupplyIndex The index used for tracking rewards on supplied assets.
    /// @return trackingBorrowIndex The index used for tracking rewards on borrowed assets.
    /// @return totalSupplyBase The total amount of the base asset supplied to the protocol.
    /// @return totalBorrowBase The total amount of the base asset borrowed from the protocol.
    /// @return lastAccrualTime The timestamp of the last accrual event in the protocol.
    /// @return pauseFlags A set of flags indicating paused states within the protocol.
    function totalsBasic()
        external
        view
        returns (
            uint64 baseSupplyIndex,
            uint64 baseBorrowIndex,
            uint64 trackingSupplyIndex,
            uint64 trackingBorrowIndex,
            uint104 totalSupplyBase,
            uint104 totalBorrowBase,
            uint40 lastAccrualTime,
            uint8 pauseFlags
        );

    /// @notice Returns the scale factor used for the base token.
    /// @return The scale factor used for the base token.
    function baseScale() external view returns (uint256);

    /// @notice Returns the utilization rate of the protocol.
    /// @return The utilization rate of the protocol.

    function getUtilization() external view returns (uint256);
    /// @notice Returns the supply rate for the protocol.
    /// @param utilization The utilization rate of the protocol.
    /// @return The supply rate for the protocol.

    function getSupplyRate(uint256 utilization) external view returns (uint256);

    /// @notice Returns the borrow rate for the protocol.
    /// @param utilization The utilization rate of the protocol.
    /// @return The borrow rate for the protocol.
    function getBorrowRate(uint256 utilization) external view returns (uint256);

    /// @notice Returns the base min for rewards
    /// @return The base min for rewards
    function baseMinForRewards() external view returns (uint256);

    /// @notice Returns the base tracking supply speed
    /// @return The base tracking supply speed
    function baseTrackingSupplySpeed() external view returns (uint256);

    /// @notice Returns the base tracking borrow speed
    /// @return The base tracking borrow speed
    function baseTrackingBorrowSpeed() external view returns (uint256);

    /// @notice Returns the tracking index scale
    /// @return The tracking index scale
    function trackingIndexScale() external view returns (uint256);
}

/// @title CometInterface
/// @notice This interface defines the functions for interacting with the Comet protocol, a part of Compound's lending
/// system.
interface CometInterface {
    /// @notice Returns the address of the base token used by the Comet protocol.
    /// @return The address of the base token.
    function baseToken() external view returns (address);
}
