// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal Convex Booster interface — resolves a Curve-LP pool's deposit/reward contracts by pid.
interface IConvexBooster {
    function poolInfo(uint256 pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
}

/// @notice Minimal Convex BaseRewardPool interface — the staked-LP balance, CRV earned, and extra reward tokens.
interface IConvexRewarder {
    function pid() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 index) external view returns (address);
}
