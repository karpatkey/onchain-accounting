// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Minimal mock for the cUSD token (ERC20 balance + burn-quote).
/// @dev Shared by both Cap leg suites so the two adapters are exercised against the SAME quote oracle — which is
///      what makes "the split did not move either leg's amount" assertable in the first place.
contract MockCUsd {
    address private _usdc;
    mapping(address => uint256) public balanceOf;

    constructor(address usdc_) {
        _usdc = usdc_;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    /// @notice Returns amountIn as amountOut (1:1, no fee) for unit-test simplicity.
    function getBurnAmount(address, uint256 amountIn) external pure returns (uint256 amountOut, uint256 fee) {
        return (amountIn, 0);
    }
}

/// @notice Minimal mock for the stcUSD token (ERC4626-like — `convertToAssets` at a settable rate).
/// @dev The rate is settable, unlike the pre-split mock's hardcoded 1:1, so the savings suite can pin the
///      intermediate-zero path (`shares > 0` converting to 0 cUSD) that must not reach the burn quote.
contract MockStcUsd {
    mapping(address => uint256) public balanceOf;

    /// @notice cUSD per share, in 1e18 fixed point. 1e18 = 1:1.
    uint256 public rate = 1e18;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }
}

/// @notice Minimal USDC mock.
contract MockUsdc {
    string public symbol = "USDC";
    uint8 public decimals = 6;
}
