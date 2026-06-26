// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

// Mock contracts extracted from CompoundV3Comet.t.sol for use by CompoundV3CometsMetaBalanceAdapter.t.sol

/// @notice Rewards mock with a valid reward config so `_rewardOwed` follows the accrual path.
///         `accrued − claimed` is exposed via `setClaimed`. With `rescaleFactor=1, shouldUpscale=false`
///         and a `baseTrackingIndex == trackingSupplyIndex` configuration in the Comet mock, the
///         accrual formula collapses to `baseTrackingAccrued − claimed`.
contract MockCompoundRewardsConfigurable {
    address public token;
    uint64 public rescaleFactor;
    bool public shouldUpscale;
    mapping(address comet => mapping(address user => uint256)) public claimed;

    constructor(address token_) {
        token = token_;
        rescaleFactor = 1;
        shouldUpscale = false;
    }

    function rewardConfig(address) external view returns (address, uint64, bool) {
        return (token, rescaleFactor, shouldUpscale);
    }

    function rewardsClaimed(address comet, address src) external view returns (uint256) {
        return claimed[comet][src];
    }

    function setClaimed(address comet, address src, uint256 amount) external {
        claimed[comet][src] = amount;
    }
}

/// @notice Comet mock with a configurable collateral list. Used for multi-collateral + COMP-overlap tests.
///         Indices are static (no accrual), so reward math reduces to `baseTrackingAccrued`.
contract MockCometRich {
    address private _baseToken;
    address[] private _assets;
    mapping(address user => int104) public principalOf;
    mapping(address user => uint64) public baseTrackingAccruedOf;
    mapping(address user => mapping(address asset => uint256)) public collateralFor;

    uint64 public constant MOCK_BASE_INDEX = 1e15;
    uint64 public constant MOCK_TRACK_INDEX = 1;

    constructor(address baseToken_, address[] memory assets_) {
        _baseToken = baseToken_;
        _assets = assets_;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function numAssets() external view returns (uint8) {
        return uint8(_assets.length);
    }

    function getAssetInfo(uint8 i)
        external
        view
        returns (uint8, address, address, uint64, uint64, uint64, uint64, uint128)
    {
        return (i, _assets[i], address(0), 1e18, 0, 0, 0, 0);
    }

    function userBasic(address user) external view returns (int104, uint64, uint64, uint16, uint8) {
        // baseTrackingIndex == trackingSupplyIndex, so `_updateTrackingAccrued` collapses to baseTrackingAccrued.
        return (principalOf[user], MOCK_TRACK_INDEX, baseTrackingAccruedOf[user], 0, 0);
    }

    function collateralBalanceOf(address user, address asset) external view returns (uint256) {
        return collateralFor[user][asset];
    }

    function totalsBasic() external view returns (uint64, uint64, uint64, uint64, uint104, uint104, uint40, uint8) {
        return (MOCK_BASE_INDEX, MOCK_BASE_INDEX, MOCK_TRACK_INDEX, MOCK_TRACK_INDEX, 0, 0, uint40(block.timestamp), 0);
    }

    function baseScale() external pure returns (uint256) {
        return 1e6;
    }

    function baseMinForRewards() external pure returns (uint256) {
        return 1;
    }

    function baseTrackingSupplySpeed() external pure returns (uint256) {
        return 0;
    }

    function baseTrackingBorrowSpeed() external pure returns (uint256) {
        return 0;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function getBorrowRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function trackingIndexScale() external pure returns (uint256) {
        return 1e15;
    }

    function setPrincipal(address user, int104 amount) external {
        principalOf[user] = amount;
    }

    function setBaseTrackingAccrued(address user, uint64 amount) external {
        baseTrackingAccruedOf[user] = amount;
    }

    function setCollateral(address user, address asset, uint256 amount) external {
        collateralFor[user][asset] = amount;
    }
}
