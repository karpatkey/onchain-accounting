// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {wstETH_L2_PriceOracle} from "src/prices/protocols/wstETH_L2_Price.sol";

contract wstETH_L2_PriceOracleForkTest_Arbitrum is TestEnvConfigurator {
    wstETH_L2_PriceOracle oracle;

    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_TO_ETH_CHAINLINK = 0xb523AE262D20A936BC152e6023996e46FDC2A95D;
    address constant ETH_TO_USD_CHAINLINK = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    uint256 constant WSTETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 428_230_165;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_PriceOracle(
            WSTETH, WSTETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, WSTETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1225436546759773000 * 226386986753 / 1e18 = 277422887277
        assertEq(price, 277_422_887_277, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}

contract wstETH_L2_PriceOracleForkTest_Base is TestEnvConfigurator {
    wstETH_L2_PriceOracle oracle;

    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant WSTETH_TO_ETH_CHAINLINK = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;
    address constant ETH_TO_USD_CHAINLINK = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    uint256 constant WSTETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 1200;
    uint256 constant FORK_BLOCK = 41_671_488;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_PriceOracle(
            WSTETH, WSTETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, WSTETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1225416525339186700 * 226501980000 / 1e18 = 277559269314
        assertEq(price, 277_559_269_314, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}

contract wstETH_L2_PriceOracleForkTest_Optimism is TestEnvConfigurator {
    wstETH_L2_PriceOracle oracle;

    address constant WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    // Optimism: Aave-managed wstETH/ETH rate feed — exposes AggregatorV3Interface (latestRoundData/decimals)
    address constant WSTETH_TO_ETH_CHAINLINK = 0xe59EBa0D492cA53C6f46015EEa00517F2707dc77;
    address constant ETH_TO_USD_CHAINLINK = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    uint256 constant WSTETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant ETH_TO_USD_HEARTBEAT = 1200;
    uint256 constant FORK_BLOCK = 147_267_078;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("opt-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_PriceOracle(
            WSTETH, WSTETH_TO_ETH_CHAINLINK, ETH_TO_USD_CHAINLINK, WSTETH_TO_ETH_HEARTBEAT, ETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1226089013749354661 * 229221287902 / 1e18 = 281045702814
        assertEq(price, 281_045_702_814, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}

contract wstETH_L2_PriceOracleForkTest_Gnosis is TestEnvConfigurator {
    wstETH_L2_PriceOracle oracle;

    address constant WSTETH = 0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6;
    // Gnosis: Aave-managed wstETH/ETH rate feed — exposes AggregatorV3Interface (latestRoundData/decimals)
    address constant WSTETH_TO_ETH_CHAINLINK = 0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA;
    address constant WETH_TO_USD_CHAINLINK = 0xa767f745331D267c7751297D982b050c93985627;
    uint256 constant WSTETH_TO_ETH_HEARTBEAT = 86_400;
    uint256 constant WETH_TO_USD_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 44_492_094;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new wstETH_L2_PriceOracle(
            WSTETH, WSTETH_TO_ETH_CHAINLINK, WETH_TO_USD_CHAINLINK, WSTETH_TO_ETH_HEARTBEAT, WETH_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1226010751677615969 * 228789505573 / 1e18 = 280498393703
        assertEq(price, 280_498_393_703, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + WETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertGt(price, 0, "Price should still be returned when stale");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), WSTETH, "Underlying asset should match wstETH token");
    }
}
