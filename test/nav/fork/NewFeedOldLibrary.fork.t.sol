// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {wstETH_CustomPriceFeed} from "src/prices/protocols/wstETH_CustomPriceFeed.sol";
import {wstETH_L2_CustomPriceFeed} from "src/prices/protocols/wstETH_L2_CustomPriceFeed.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IwstETHRate {
    function stEthPerToken() external view returns (uint256);
}

interface ISequencerFeedView {
    function chainlinkL2SequencerUptimeFeed() external view returns (address);
}

/// @title NewFeedOldLibraryForkTest
/// @notice The rollout's transient state (ADR 0029, `script/deploy/ADR0029_ROLLOUT.md` Rule 1): this tree's custom feeds
///         are swapped in BEFORE the NAV implementation is upgraded, so for a while they run against the LIVE, old
///         `PriceFeedLib`. The ADR's claim is that this is safe: the old library prices a stale base at 0, so a new
///         feed returns `(0, true)` exactly as an old one does, and a fresh base — including during an L2 sequencer
///         outage — prices normally. These tests read the deployed proxy WITHOUT etching the new library or
///         implementation (unlike every other feed fork test), and first assert the live implementation is the one
///         in production when this PR was written.
contract NewFeedOldLibraryForkTest is TestEnvConfigurator {
    address internal constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    /// @dev The NAVCalculator implementation live on every chain before ADR 0029 (PR #338), linked to the old library.
    address internal constant LIVE_IMPL = 0xA7243DCDF7e4D6f8FA20A9F022186C0d0778C2b6;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _assertLiveEngine() internal view {
        assertEq(
            address(uint160(uint256(vm.load(NAV, IMPL_SLOT)))),
            LIVE_IMPL,
            "precondition: the proxy runs the pre-ADR-0029 implementation"
        );
    }

    /// @dev Ethereum: fresh base → priced and fresh; base past its heartbeat → the OLD library gives price 0, so the new
    ///      feed returns (0, true) — today's behaviour, never a stale price reported fresh.
    function test_mainnet_newFeed_underLiveLibrary() public {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 26_240_000);
        _assertLiveEngine();
        address wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        wstETH_CustomPriceFeed feed = new wstETH_CustomPriceFeed(wstEth, NAV, weth);

        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(weth);
        assertFalse(pd.stale, "precondition: ETH/USD fresh at the fork block");
        uint256 expected = IwstETHRate(wstEth).stEthPerToken() * uint256(pd.price) / 1e18;
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, expected, "fresh base: priced exactly as under the new library");
        assertFalse(stale);

        vm.warp(block.timestamp + 2 days);
        assertEq(INAVCalculator(NAV).getPriceData(weth).price, 0, "precondition: the OLD library zeroes a stale base");
        (price, stale) = feed.getLatestPrice();
        assertEq(price, 0, "stale base under the old library: (0, true), as today");
        assertTrue(stale);
    }

    /// @dev Base (an L2 with a sequencer feed): during a sequencer outage a FRESH base must still price the new feed
    ///      and must NOT flag it stale (sequencer-down alone is surfaced by `nav.sequencerDown`, not per asset); a
    ///      STALE base during the outage must give (0, true). The second case is the one where an OLD feed under the
    ///      NEW library would report fresh (test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol); here, in the order the
    ///      rollout actually uses, it cannot.
    function test_base_newFeed_underLiveLibrary_sequencerDown() public {
        createSelectForkWithCadence(getAlchemyUrl("base-mainnet"), 52_940_000);
        _assertLiveEngine();
        address wstEth = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
        address rateFeed = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;
        address weth = 0x4200000000000000000000000000000000000006;
        wstETH_L2_CustomPriceFeed feed = new wstETH_L2_CustomPriceFeed(wstEth, rateFeed, 86_400, NAV, weth);

        (uint256 freshPrice, bool freshStale) = feed.getLatestPrice();
        assertGt(freshPrice, 0, "control: priced");
        assertFalse(freshStale, "control: fresh");

        // Sequencer down (answer 1), just started: inside the grace period.
        address uptime = ISequencerFeedView(NAV).chainlinkL2SequencerUptimeFeed();
        assertTrue(uptime != address(0), "precondition: Base's NAV has a sequencer uptime feed");
        vm.mockCall(
            uptime,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp, block.timestamp, uint80(1))
        );
        assertTrue(INAVCalculator(NAV).getPriceData(weth).sequencerDown, "precondition: sequencer reads down");
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, freshPrice, "fresh base during an outage: same price");
        assertFalse(stale, "fresh base during an outage: not flagged stale per asset");

        // Base past its heartbeat while the sequencer is still down.
        vm.warp(block.timestamp + 2 days);
        vm.mockCall(
            uptime,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp, block.timestamp, uint80(1))
        );
        assertEq(INAVCalculator(NAV).getPriceData(weth).price, 0, "precondition: the OLD library zeroes a stale base");
        (price, stale) = feed.getLatestPrice();
        assertEq(price, 0, "stale base during an outage under the old library: (0, true)");
        assertTrue(stale, "never a stale base reported fresh");
    }
}
