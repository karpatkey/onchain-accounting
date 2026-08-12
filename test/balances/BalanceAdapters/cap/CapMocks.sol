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

    /// @notice Burn fee in basis points, taken off `amountIn`. Default 0 — 1:1, the historical behaviour.
    uint256 public feeBps;

    /// @notice USDC out per 1e18 cUSD in, in 1e18 fixed point. Default 1e18 — 1:1, the historical behaviour.
    /// @dev ⚠️ **Real cUSD is 18-decimal and USDC is 6-decimal, so the production quote rescales by ~1e12.** The
    ///      identity default does NOT model that, which is why both suites assert 18-decimal figures against a
    ///      6-decimal asset and read fine. That is tolerable for the arithmetic-invariance tests (the split must not
    ///      move either leg's amount, and 1:1 makes the sum obvious) but it means an adapter that silently assumed
    ///      1:1 would pass every one of them. `setScale` exists so at least one test drives a realistic rescale.
    uint256 public scale = 1e18;

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function setScale(uint256 scale_) external {
        scale = scale_;
    }

    /// @notice Quote mirroring the real signature: amount out AFTER fee, and the fee separately.
    /// @dev Defaults to the historical `(amountIn, 0)` identity so existing expectations are unchanged; the
    ///      settable fee and scale are what let a test prove the adapter PROPAGATES the quote rather than
    ///      reproducing its input. With an identity quote, replacing `_usdcForCUsd`'s body with
    ///      `return cUsdAmount` passes every assertion in both suites — the mock was hiding the call entirely.
    function getBurnAmount(address, uint256 amountIn) external view returns (uint256 amountOut, uint256 fee) {
        uint256 scaled = (amountIn * scale) / 1e18;
        fee = (scaled * feeBps) / 10_000;
        return (scaled - fee, fee);
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
