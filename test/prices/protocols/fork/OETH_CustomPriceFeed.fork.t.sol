// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {OETH_CustomPriceFeed} from "src/prices/protocols/OETH_CustomPriceFeed.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title OETH_CustomPriceFeed fork tests
/// @notice Verifies pricing Origin OETH as `OETH/USD = (ETH/USD) * (OETH/ETH)` via the generic
///         OETH_CustomPriceFeed. OETH rebases ~1:1 to ETH; the Chainlink OETH/ETH feed captures any
///         genuine deviation. As with the stETH instance, the ETH/USD reads cancel when NAV is quoted
///         in ETH, leaving the single dedicated OETH/ETH feed.
contract OETH_CrossRatePriceForkTest is TestEnvConfigurator {
    OETH_CustomPriceFeed oracle;

    address constant OETH = 0x856c4Efb76C1D1AE02e20CEB03A2A6a08b0b8dC3;
    address constant ETH_TO_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // X/USD
    address constant OETH_TO_ETH = 0x703118C4CbccCBF2AB31913e0f8075fbbb15f563; // Y/X (18 decimals)
    uint256 constant ETH_TO_USD_HEARTBEAT = 3600;
    uint256 constant OETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_345_348;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new OETH_CustomPriceFeed(OETH, OETH_TO_ETH, ETH_TO_USD, OETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT);
    }

    /// @dev In-EVM ground truth: price == (ETH/USD) * (OETH/ETH) / 1e18 (OETH/ETH is 18 decimals).
    function test_getLatestPrice() public view {
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD).latestRoundData();
        (, int256 oethEth,,,) = AggregatorV3Interface(OETH_TO_ETH).latestRoundData();
        uint256 expected = (uint256(ethUsd) * uint256(oethEth)) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == ETH/USD * OETH/ETH / 1e18");
        assertFalse(stale);
        assertEq(oracle.decimals(), 8, "8-decimal USD price (matches ETH/USD)");
    }

    /// @notice In the ETH-denominated NAV the asset's USD price is divided by ETH/USD; that recovers the
    ///         single OETH/ETH feed (the ETH/USD reads cancel modulo integer-rounding dust).
    function test_ethQuoteCancelsToOethEthFeed() public view {
        (, int256 ethUsd,,,) = AggregatorV3Interface(ETH_TO_USD).latestRoundData();
        (, int256 oethEth,,,) = AggregatorV3Interface(OETH_TO_ETH).latestRoundData();

        (uint256 price,) = oracle.getLatestPrice();
        uint256 oethInEth = (price * 1e18) / uint256(ethUsd);
        assertApproxEqAbs(oethInEth, uint256(oethEth), 1e10, "ETH-quote recovers the OETH/ETH feed (cancellation)");
    }

    function test_stale() public {
        vm.warp(block.timestamp + OETH_TO_ETH_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertTrue(stale, "marked stale past heartbeat");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), OETH, "underlying == OETH");
    }
}
