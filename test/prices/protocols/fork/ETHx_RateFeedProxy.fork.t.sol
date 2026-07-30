// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ETHx_CrossRateCustomPriceFeed} from "src/prices/protocols/ETHx_CrossRateCustomPriceFeed.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {NotChainlinkOracle} from "src/errors.sol";

/// @notice Regression guard for the ETHx `yToXFeed` CONFIG ADDRESS — not for the feed's arithmetic (that belongs to
///         `ETHx_CrossRateCustomPriceFeed`'s own fork test).
///
///         The bug this pins: the configured rate leg was `0xC499ec76…`, the raw **access-controlled aggregator**,
///         rather than the `EACAggregatorProxy` above it. It passed every inspection a config review would run —
///         `description()` is `"ETHx / ETH"`, `decimals()` is 18, and `latestRoundData()` answers a `cast call` — yet
///         **no contract could read it**. Chainlink's `SimpleReadAccessController` grants access only when
///         `_user == tx.origin`, so a direct EOA `eth_call` succeeds while every contract is denied. The constructor's
///         `assertChainlinkOracle` probe was therefore denied and reverted `NotChainlinkOracle()`, so
///         `_deployEthxCrossRate()` (`03_DeployPriceFeeds.s.sol:211` → `:639`, the NAMED deploy function for ETHx —
///         not the generic `_deployCrossRateMonitor`, which ETHx does not use) reverted during `03_DeployPriceFeeds`
///         simulation — and because `vm.writeJson` side effects are NOT rolled back on revert, that run left phantom
///         `customPriceFeeds` addresses in `deployments/1.json` which `04` then collided with.
///
///         **"Right pair" and "readable on-chain" are independent properties.** A passing `cast call` proves nothing
///         here, and `description()` was CORRECT on the bad address — so neither manual inspection nor a
///         description-based pair assertion would have caught it. Only construction from a contract context does,
///         which is exactly what `test_configuredRateFeed_isConstructibleFromContract` exercises: this test contract
///         is a contract, so `msg.sender != tx.origin` and the access controller behaves as it will in production.
///
///         The address is read FROM CONFIG rather than hardcoded, so a future config edit is covered by this test
///         instead of silently bypassing it.
contract ETHx_RateFeedProxyForkTest is TestEnvConfigurator {
    /// @notice The raw access-controlled aggregator that was wrongly configured. Contract-unreadable by design.
    address constant RAW_AGGREGATOR = 0xC499ec76e2F5ac15e127A352Bc40cF24FC472401;

    address constant ASSET = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_491_000;

    /// @notice The `yToXFeed` actually configured for `ETHxCrossRate` on mainnet, read from the deploy config.
    address rateFeed;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        rateFeed = vm.parseAddress(ConfigReader.readPriceFeedParam(vm, 1, "ETHxCrossRate", "yToXFeed"));
    }

    /// @dev Check 1 — the decisive one. Proves the configured address is the proxy sitting above EXACTLY the
    ///      aggregator that was previously configured, rather than a different feed that merely shares a pair name.
    function test_configuredRateFeed_isProxyOverTheExpectedAggregator() public view {
        assertEq(
            AggregatorV3Interface(rateFeed).description(),
            "ETHx / ETH",
            "configured rate feed must be the ETHx/ETH pair"
        );
        assertEq(AggregatorV3Interface(rateFeed).decimals(), 18, "ETHx/ETH is an 18-decimal feed");

        (, bytes memory ret) = rateFeed.staticcall(abi.encodeWithSignature("aggregator()"));
        assertEq(ret.length, 32, "configured rate feed must be an EACAggregatorProxy exposing aggregator()");
        assertEq(
            abi.decode(ret, (address)),
            RAW_AGGREGATOR,
            "proxy must sit above the aggregator that was previously mis-configured"
        );
    }

    /// @dev Check 4 — the property that was actually missing. `new` runs `assertChainlinkOracle` with
    ///      `msg.sender = this contract`, so a feed readable only by an EOA reverts here.
    function test_configuredRateFeed_isConstructibleFromContract() public {
        ETHx_CrossRateCustomPriceFeed oracle =
            new ETHx_CrossRateCustomPriceFeed(ASSET, rateFeed, RATE_HEARTBEAT, NAV, BASE);
        assertEq(address(oracle.RATE_FEED()), rateFeed, "constructed against the configured rate feed");
    }

    /// @dev Pins the bug so it cannot return: constructing against the RAW aggregator must still revert. If this ever
    ///      passes, Chainlink has opened up access and the distinction this test guards has changed.
    function test_rawAggregator_stillRevertsNotChainlinkOracle() public {
        vm.expectRevert(NotChainlinkOracle.selector);
        new ETHx_CrossRateCustomPriceFeed(ASSET, RAW_AGGREGATOR, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev Demonstrates the asymmetry directly, so the reason the bad address passed review is recorded in an
    ///      executable form: the aggregator denies a contract caller while the proxy serves one.
    function test_rawAggregator_deniesContractCallers_butProxyDoesNot() public view {
        (bool rawOk,) = RAW_AGGREGATOR.staticcall(abi.encodeWithSignature("latestRoundData()"));
        assertFalse(rawOk, "raw access-controlled aggregator must deny a contract caller");

        (bool proxyOk,) = rateFeed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        assertTrue(proxyOk, "the proxy must serve a contract caller");
    }
}
