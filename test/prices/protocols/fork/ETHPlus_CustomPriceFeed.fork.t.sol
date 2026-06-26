// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {
    ETHPlus_CustomPriceFeed,
    IBasketHandler,
    CollateralStatus
} from "src/prices/protocols/ETHPlus_CustomPriceFeed.sol";

/// Note on multi-feed redundancy for ETH+:
/// The only available 8-decimal USD price source for ETH+ is the custom basket oracle
/// (ETHPlus_CustomPriceFeed). The Chainlink ETH+/USD feed (0x66Ab900341C98de949EC31d11b3C4180743844F1)
/// has 18 decimals and cannot be registered alongside an 8-decimal feed (decimal-consistency guard).
/// No Redstone or API3 ETH+/USD feed with 8 decimals exists on Ethereum Mainnet as of 2026-05.
/// A multi-feed redundancy test will be added when an 8-decimal compatible feed is available.
contract ETHPlus_CustomPriceFeedForkTest is TestEnvConfigurator {
    ETHPlus_CustomPriceFeed oracle;

    address constant ETHPLUS = 0xE72B141DF173b999AE7c1aDcbF60Cc9833Ce56a8;
    uint256 constant FORK_BLOCK = 24_277_401;
    uint256 constant HEARTBEAT = 86_400;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new ETHPlus_CustomPriceFeed(ETHPLUS, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // (35930254610744758768926 / 33588540032392468729179) * 2980651180612428414751 / 1e10 = 318845522079
        assertEq(price, 318_845_522_079, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPrice_stale_when_iffy() public {
        address basketHandlerAddr = _basketHandlerAddress();
        vm.mockCall(
            basketHandlerAddr, abi.encodeWithSelector(IBasketHandler.status.selector), abi.encode(CollateralStatus.IFFY)
        );
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0);
        assertEq(stale, true);
    }

    function test_getLatestPrice_stale_when_heartbeat_exceeded() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Price should be 0 when heartbeat exceeded");
        assertEq(stale, true, "Should be stale when heartbeat exceeded");
    }

    function test_latestRoundData() public view {
        (uint256 priceFromGet,) = oracle.getLatestPrice();
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();

        assertGt(updatedAt, 0, "updatedAt must be non-zero");
        assertLe(updatedAt, block.timestamp, "updatedAt must not be in the future");
        assertEq(answer, int256(priceFromGet), "answer must match getLatestPrice");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should be 8 for USD");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ETHPLUS, "Underlying asset should match ETH+ token");
    }

    function test_reserveProtocolHeartbeat() public view {
        assertEq(oracle.RESERVE_PROTOCOL_HEARTBEAT(), HEARTBEAT);
    }

    function _basketHandlerAddress() internal view returns (address) {
        (bool ok, bytes memory data) = ETHPLUS.staticcall(abi.encodeWithSignature("main()"));
        require(ok, "main() call failed");
        address mainAddr = abi.decode(data, (address));
        (ok, data) = mainAddr.staticcall(abi.encodeWithSignature("basketHandler()"));
        require(ok, "basketHandler() call failed");
        return abi.decode(data, (address));
    }
}
