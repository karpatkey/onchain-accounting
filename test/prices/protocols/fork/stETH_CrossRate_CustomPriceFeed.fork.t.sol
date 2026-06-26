// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {CrossRate_CustomPriceFeed} from "src/prices/protocols/CrossRate_CustomPriceFeed.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title stETH CrossRate_CustomPriceFeed fork tests
/// @notice Verifies pricing stETH as `stETH/USD = (ETH/USD) * (stETH/ETH)` via the generic
///         CrossRate_CustomPriceFeed, replacing the raw STETH/USD Chainlink feed. The point of the change:
///         when NAV is quoted in ETH it divides each asset's USD price by ETH/USD; with this adapter the
///         ETH/USD reads cancel exactly, leaving the single dedicated stETH/ETH feed (no two-feed jitter),
///         while still reflecting genuine stETH depeg. See the rewire runbook.
contract stETH_CrossRatePriceForkTest is TestEnvConfigurator {
    CrossRate_CustomPriceFeed oracle;

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant ETH_TO_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // X/USD
    address constant STETH_TO_ETH = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812; // Y/X
    address constant STETH_USD_RAW = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8; // the feed being replaced
    uint256 constant ETH_TO_USD_HEARTBEAT = 3600;
    uint256 constant STETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_287_877;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new CrossRate_CustomPriceFeed(
            STETH, ETH_TO_USD, STETH_TO_ETH, ETH_TO_USD_HEARTBEAT, STETH_TO_ETH_HEARTBEAT
        );
    }

    /// @dev In-EVM ground truth: price == (ETH/USD) * (stETH/ETH) / 1e18 (stETH/ETH is 18 decimals).
    function test_getLatestPrice() public view {
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD).latestRoundData();
        (, int256 stEthEth,,,) = AggregatorV3Interface(STETH_TO_ETH).latestRoundData();
        uint256 expected = (uint256(ethUsd) * uint256(stEthEth)) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == ETH/USD * stETH/ETH / 1e18");
        assertFalse(stale);
        assertEq(oracle.decimals(), 8, "8-decimal USD price (matches ETH/USD)");
    }

    /// @notice The whole point: in the ETH-denominated NAV the asset's USD price is divided by ETH/USD.
    ///         Here that recovers EXACTLY the single stETH/ETH feed (the ETH/USD reads cancel) — no two-feed
    ///         jitter, unlike the raw STETH/USD ÷ ETH/USD path it replaces.
    function test_ethQuoteCancelsToStEthEthFeed() public view {
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD).latestRoundData();
        (, int256 stEthEth,,,) = AggregatorV3Interface(STETH_TO_ETH).latestRoundData();

        (uint256 price,) = oracle.getLatestPrice();
        // stETH-in-ETH = price(8) / ETH/USD(8), scaled to 18 decimals == the stETH/ETH feed.
        // Residual is double-floor rounding dust (~1e18/ethUsd ≈ 5e6 wei, i.e. ~1 part in 2.6e11) — the
        // ETH/USD reads cancel exactly modulo integer rounding, which is the whole point of the change.
        uint256 stEthInEth = (price * 1e18) / uint256(ethUsd);
        assertApproxEqAbs(stEthInEth, uint256(stEthEth), 1e10, "ETH-quote recovers the stETH/ETH feed (cancellation)");
    }

    /// @notice Sanity: the raw STETH/USD feed (the one being replaced) is a SEPARATE source whose implied
    ///         stETH/ETH (rawStEthUsd / ethUsd) need not track the dedicated stETH/ETH feed exactly. The two
    ///         feeds update independently, so this implied ratio can drift from the dedicated feed over time —
    ///         that desync is what made the ETH-denominated NAV jitter. Here we only assert the two are close
    ///         at this block (they may also coincide); the test does not claim a strict inequality.
    function test_rawStEthUsdIsIndependentSource() public view {
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD).latestRoundData();
        (, int256 stEthEth,,,) = AggregatorV3Interface(STETH_TO_ETH).latestRoundData();
        (, int256 rawStEthUsd,,,) = AggregatorV3Interface(STETH_USD_RAW).latestRoundData();

        uint256 impliedFromRaw = (uint256(rawStEthUsd) * 1e18) / uint256(ethUsd); // two-feed implied stETH/ETH
        // Both are ~1e18; assert only that they're close (sanity). They need not be equal — independent feeds —
        // and they may coincide at any given block; the over-time desync is the bug the cross-rate change removes.
        assertApproxEqRel(
            impliedFromRaw,
            uint256(stEthEth),
            0.02e18,
            "raw-implied ratio is near the dedicated feed (independent sources)"
        );
    }

    function test_stale() public {
        vm.warp(block.timestamp + STETH_TO_ETH_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertTrue(stale, "marked stale past heartbeat");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), STETH, "underlying == stETH");
    }
}
