// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

/// @title Aave Umbrella balance-oracle unit-test mocks
/// @notice Minimal stand-ins for the live Umbrella surface the adapter discovers at runtime, so the
///         balance math (the ERC4626 walk + reward bare-reserve resolution + position emission) can
///         be exercised deterministically without a fork. The fork companion
///         (test/balances/protocols/fork/AaveUmbrellaBalanceAdapter.fork.t.sol) covers the real contracts.
/// @dev Conversions use a 1e18-scaled `rate` (assets per share); convertToAssets(0) == 0 so the
///      wrapper-detection probe in the adapter classifies MockErc4626Wrapper as a wrapper and a
///      plain Mock_ERC20 (no asset()/convertToAssets) as a bare reserve.

/// @notice ERC4626-shaped wrapper (e.g. a `waEth*` StataTokenV2 layer): exposes asset() + convertToAssets.
contract MockErc4626Wrapper {
    address public immutable asset;
    uint256 public immutable rate;

    constructor(address asset_, uint256 rate_) {
        asset = asset_;
        rate = rate_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }
}

/// @notice Umbrella stake token (ERC4626 vault): balanceOf + convertToAssets + asset(). `asset` may be a
///         wrapper (wa* family → two-hop walk) or a bare reserve directly (stkGHO-style → one hop).
contract MockUmbrellaStakeToken {
    address public immutable asset;
    uint256 public immutable rate;
    string public symbol;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_, uint256 rate_, string memory symbol_) {
        asset = asset_;
        rate = rate_;
        symbol = symbol_;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }
}

/// @notice aToken-shaped reward token: exposes UNDERLYING_ASSET_ADDRESS() so the adapter maps the
///         reward onto its bare reserve. Plain reward tokens (no such getter) resolve to themselves.
contract MockAToken {
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    // solhint-disable-next-line func-name-mixedcase
    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return underlying;
    }
}

/// @notice Umbrella RewardsController: enumerates stake tokens and returns per-(stakeToken,user) rewards.
contract MockUmbrellaRewardsController {
    address[] internal _all;
    mapping(bytes32 => address[]) internal _rewardTokens;
    mapping(bytes32 => uint256[]) internal _rewardAmounts;

    function addStakeToken(address stakeToken) external {
        _all.push(stakeToken);
    }

    function getAllAssets() external view returns (address[] memory) {
        return _all;
    }

    function setRewards(address stakeToken, address user, address[] calldata tokens, uint256[] calldata amounts)
        external
    {
        bytes32 k = keccak256(abi.encode(stakeToken, user));
        _rewardTokens[k] = tokens;
        _rewardAmounts[k] = amounts;
    }

    function calculateCurrentUserRewards(address stakeToken, address user)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        bytes32 k = keccak256(abi.encode(stakeToken, user));
        return (_rewardTokens[k], _rewardAmounts[k]);
    }
}
