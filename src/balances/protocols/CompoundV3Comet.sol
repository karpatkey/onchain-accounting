// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/errors.sol";

/// @title CompoundV3Comet
/// @notice This contract provides an implementation of a balance oracle for a Compound V3 Comet.
///   This balance oracle can return the base token, collateral assets, and owed rewards for a user on a given Comet
/// contract.
contract CompoundV3Comet is IBalanceOracleAdapter {
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
    ICompoundRewards public immutable COMPOUND_REWARDS;

    /// @notice The Compound reward token.
    IERC20 public immutable REWARD_TOKEN;

    /// @notice The Comet base token.
    address public immutable BASE_TOKEN;

    /// @notice The Comet contract address.
    address public immutable COMET;

    /// @notice The CometExtInterface contract address.
    CometExtInterface public immutable COMET_EXT_INTERFACE;

    /// @notice The descale factor for the accrual.
    uint256 public immutable ACCRUAL_DESCALE_FACTOR;

    /// @notice List of collateral asset addresses for this comet.
    address[] public collaterals;
    /// @notice Mapping to check if an asset is collateral.
    mapping(address asset => bool collateral) public isCollateral;

    /// @notice Protocol identifier for this oracle
    string private _protocol;
    /// @notice Position detail identifier for this oracle
    string private _positionDetail;
    /// @notice Reference to Balances contract for asset registry access
    IBalances public immutable BALANCES;

    //
    // Errors
    //

    /// @notice Indicates that the provided arguments are invalid.
    error InvalidTimestamp();

    /// @param compoundRewards_ The address of the Compound rewards contract.
    /// @param comet_ The address of the Comet contract we want to get the balance of.
    /// @param rewardToken_ The address of the compound reward token contract.
    /// @param protocol_ Protocol identifier (e.g., "Compound v3").
    /// @param positionDetail_ Position detail identifier (e.g., "Comet").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(
        address compoundRewards_,
        address comet_,
        address rewardToken_,
        string memory protocol_,
        string memory positionDetail_,
        address balances_
    ) {
        if (compoundRewards_ == address(0) || comet_ == address(0) || rewardToken_ == address(0)) {
            revert InvalidArguments();
        }
        COMPOUND_REWARDS = ICompoundRewards(compoundRewards_);
        REWARD_TOKEN = IERC20(rewardToken_);

        BASE_TOKEN = CometInterface(comet_).baseToken();
        COMET = comet_;
        COMET_EXT_INTERFACE = CometExtInterface(comet_);

        // https://etherscan.io/address/0x1B0e765F6224C21223AeA2af16c1C46E38885a40#code
        ACCRUAL_DESCALE_FACTOR = COMET_EXT_INTERFACE.baseScale() / BASE_ACCRUAL_SCALE;

        uint8 assetCount = CometExtInterface(comet_).numAssets();

        for (uint8 i = 0; i < assetCount; i++) {
            (, address asset,,,,,,) = CometExtInterface(COMET).getAssetInfo(i);
            isCollateral[asset] = true;
            collaterals.push(asset);
        }

        _protocol = protocol_;
        _positionDetail = positionDetail_;
        BALANCES = IBalances(balances_);
    }

    /// @notice Returns the number of collateral assets for the Comet contract.
    /// @return The number of collateral assets
    function getCollateralsCount() internal view returns (uint256) {
        return collaterals.length;
    }

    /// @notice Internal helper to calculate balance for a specific asset
    /// @param underlyingAsset The asset address
    /// @param account The account address
    /// @return balance The calculated balance
    function _calculateBalance(address underlyingAsset, address account) internal view returns (int256 balance) {
        if (underlyingAsset != address(REWARD_TOKEN) && underlyingAsset != BASE_TOKEN && !isCollateral[underlyingAsset])
        {
            revert InvalidArguments();
        }

        if (underlyingAsset == address(REWARD_TOKEN)) {
            balance += _getRewardOwed(account).toInt256();
        }

        if (underlyingAsset == BASE_TOKEN) {
            balance += getUnderlying(COMET, account);
        }

        if (isCollateral[underlyingAsset]) {
            balance += CometExtInterface(COMET).collateralBalanceOf(account, underlyingAsset).toInt256();
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        // Return baseToken + collaterals + rewardToken
        uint256 totalAssets = 1 + collaterals.length + 1; // baseToken + collaterals + rewardToken
        address[] memory assets = new address[](totalAssets);
        uint256 idx = 0;

        assets[idx++] = BASE_TOKEN;

        for (uint256 i = 0; i < collaterals.length; i++) {
            assets[idx++] = collaterals[i];
        }

        assets[idx] = address(REWARD_TOKEN);

        return assets;
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
            total = int256(principal) * uint256(baseSupplyIndex).toInt256();
        } else {
            total = int256(principal) * uint256(baseBorrowIndex).toInt256();
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
        (address token, uint64 rescaleFactor, bool shouldUpscale) = COMPOUND_REWARDS.rewardConfig(COMET);
        if (token == address(0)) return 0;

        uint256 claimed = COMPOUND_REWARDS.rewardsClaimed(COMET, src);
        uint256 accrued = _getRewardAccrued(COMET, src, shouldUpscale, rescaleFactor);

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
        return n * COMET_EXT_INTERFACE.baseScale() / baseWei;
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
            uint256 utilization = COMET_EXT_INTERFACE.getUtilization();
            uint256 supplyRate = COMET_EXT_INTERFACE.getSupplyRate(utilization);
            uint256 borrowRate = COMET_EXT_INTERFACE.getBorrowRate(utilization);
            baseSupplyIndex_ += (_mulFactor(baseSupplyIndex_, supplyRate * timeElapsed)).toUint64();
            baseBorrowIndex_ += (_mulFactor(baseBorrowIndex_, borrowRate * timeElapsed)).toUint64();
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
        ) = COMET_EXT_INTERFACE.totalsBasic();

        uint40 now_ = _getNowInternal();
        uint256 timeElapsed = uint256(now_ - lastAccrualTime);
        if (timeElapsed > 0) {
            (baseSupplyIndex, baseBorrowIndex) = _accruedInterestIndices(timeElapsed, baseSupplyIndex, baseBorrowIndex);
            uint256 baseMinForRewards = COMET_EXT_INTERFACE.baseMinForRewards();

            if (totalSupplyBase >= baseMinForRewards) {
                trackingSupplyIndex += (_divBaseWei(
                        COMET_EXT_INTERFACE.baseTrackingSupplySpeed() * timeElapsed, totalSupplyBase
                    ))
                .toUint64();
            }
            if (totalBorrowBase >= baseMinForRewards) {
                trackingBorrowIndex += (_divBaseWei(
                        COMET_EXT_INTERFACE.baseTrackingBorrowSpeed() * timeElapsed, totalBorrowBase
                    ))
                .toUint64();
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

            // casting to 'uint104' is safe because principal is int104 and we've checked it's >= 0
            // forge-lint: disable-next-line(unsafe-typecast)
            baseTrackingAccrued += (uint104(principal)
                * indexDelta
                / COMET_EXT_INTERFACE.trackingIndexScale()
                / ACCRUAL_DESCALE_FACTOR)
            .toUint64();
        } else {
            uint256 indexDelta = uint256(trackingBorrowIndex - baseTrackingIndex);
            // casting to 'uint104' is safe because -principal is positive when principal < 0, and principal is int104
            // forge-lint: disable-next-line(unsafe-typecast)
            baseTrackingAccrued += (uint104(-principal)
                * indexDelta
                / COMET_EXT_INTERFACE.trackingIndexScale()
                / ACCRUAL_DESCALE_FACTOR)
            .toUint64();
        }
    }

    /// @notice Calculates the total rewards accrued for a user in the Comet contract.
    /// @param comet_ The address of the Comet contract.
    /// @param account The address of the user's account.
    /// @param shouldUpscale Whether the rewards should be upscaled.
    /// @param rescaleFactor The factor by which to rescale the rewards.
    /// @return The total accrued rewards for the user.
    function _getRewardAccrued(address comet_, address account, bool shouldUpscale, uint64 rescaleFactor)
        internal
        view
        returns (uint256)
    {
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
        return accrued;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance) {
        // Sum all balances for this asset across all positions
        // _buildPositions with asset filter already returns only positions for this asset
        INAVCalculator.Position[] memory positions = _buildPositions(account, asset);
        for (uint256 i = 0; i < positions.length; i++) {
            balance += positions[i].balance;
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOracleBalance(address account)
        external
        view
        returns (address[] memory assets, int256[] memory amounts)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        // Pre-allocate arrays
        address[] memory tempAssets = new address[](assetCount);
        int256[] memory tempAmounts = new int256[](assetCount);
        uint256 count = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];
            int256 balance = this.getOracleBalanceForAsset(account, asset);

            // Only include non-zero balances
            if (balance != 0) {
                tempAssets[count] = asset;
                tempAmounts[count] = balance;
                count++;
            }
        }

        // Resize to actual count
        assets = new address[](count);
        amounts = new int256[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = tempAssets[i];
            amounts[i] = tempAmounts[i];
        }
    }

    /// @notice Internal helper that builds all positions for this oracle
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of Position structs from this oracle
    function _buildPositions(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        address[] memory supportedAssets = this.underlyingAssetsSupported();
        uint256 assetCount = supportedAssets.length;

        if (assetCount == 0) {
            return new INAVCalculator.Position[](0);
        }

        // Pre-allocate array (estimate max size)
        INAVCalculator.Position[] memory tempPositions = new INAVCalculator.Position[](assetCount);
        uint256 positionCount = 0;

        for (uint256 i = 0; i < assetCount; i++) {
            address asset = supportedAssets[i];

            // Apply asset filter if specified
            if (assetFilter != address(0) && asset != assetFilter) {
                continue;
            }

            // Get balance for this asset
            int256 balance = _calculateBalance(asset, account);

            // Only include non-zero balances
            if (balance != 0) {
                // Get asset info from registry (if registered)
                uint8 decimals;
                string memory symbol;
                try BALANCES.getAssetDecimals(asset) returns (uint8 dec) {
                    decimals = dec;
                } catch {
                    // Asset not registered, skip it (NAVCalculator will filter anyway)
                    continue;
                }
                try BALANCES.getAssetSymbol(asset) returns (string memory sym) {
                    symbol = sym;
                } catch {
                    symbol = "";
                }

                // Build underlying asset struct
                INAVCalculator.Asset memory underlyingAsset =
                    INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals});

                // Build position (pricing will be added by NAVCalculator)
                tempPositions[positionCount] = INAVCalculator.Position({
                    underlyingAsset: underlyingAsset,
                    balanceOracle: address(this),
                    balance: balance,
                    quoteAsset: INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), // Will be set by NAVCalculator
                    value: 0, // Will be calculated by NAVCalculator
                    price: 0, // Will be set by NAVCalculator
                    priceDecimals: 0, // Will be set by NAVCalculator
                    stale: false, // Will be set by NAVCalculator
                    protocol: _protocol,
                    positionDetail: _positionDetail
                });

                positionCount++;
            }
        }

        // Resize to actual count
        positions = new INAVCalculator.Position[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }

    /// @inheritdoc IBalanceOracleAdapter
    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.Position[] memory positions)
    {
        return _buildPositions(account, assetFilter);
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
    function rewardConfig(address comet) external view returns (address token, uint64 rescaleFactor, bool shouldUpscale);

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
