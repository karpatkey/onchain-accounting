// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {ChainlinkPriceFeeds} from "test/ChainlinkPriceFeeds.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "src/balances/protocols/CompoundV3CometsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

contract ArbitrumForkNAVCalculator is NAVCalculatorForkHarness {
    /// @notice Test account for Arbitrum fork (has positions / holdings to exercise NAV)
    address public constant ARBITRUM_SAFE = 0x6286b9f080D27f860F6b4bb0226F8EF06CC9F2Fc;

    // Native and wrapped ETH
    address public native = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);

    // Token addresses (Arbitrum One)
    address public usdc = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address public usdt = address(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    address public wbtc = address(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    address public arb = address(0x912CE59144191C1204E64559FE8253a0e49E6548);
    address public compound = address(0x354A6dA3fcde098F8389cad84b0182725c6C91dE);

    // Aave V3 (Arbitrum)
    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);

    // Compound V3 (Arbitrum)
    address public cUsdCv3 = address(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    address public compoundRewardContract = address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae);

    CompoundV3CometsMetaBalanceAdapter public compoundV3UsdcComet;

    /// @dev Pinned to a known-good block. See NAVCalculator.Mainnet.fork.t.sol for rationale.
    uint256 public constant FORK_BLOCK = 457_665_000;

    function setUp() public {
        togglePositionsLogging();
        safe = ARBITRUM_SAFE;
        fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function test_arbitrumFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();
        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertTrue(reading.value >= 0, "ARBITRUM_SAFE should have non-negative NAV");
    }

    function test_arbitrumFork_getAllPositions() public view {
        logAccountPositions(safe, address(0));
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertTrue(navTotal.value >= 0);

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupRegisterAssets() internal override {
        nav.registerAsset(usdc, ChainlinkPriceFeeds.usdcUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(usdt, ChainlinkPriceFeeds.usdtUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(wbtc, ChainlinkPriceFeeds.wbtcUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(arb, ChainlinkPriceFeeds.arbUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
        nav.addPriceFeed(native, ChainlinkPriceFeeds.ethUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(weth, ChainlinkPriceFeeds.ethUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(compound, ChainlinkPriceFeeds.compUsdArbitrum(), IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceAdapter() internal override {
        AaveV3InstancesMetaBalanceAdapter aaveMeta = new AaveV3InstancesMetaBalanceAdapter("Aave V3", address(nav));
        aaveAdapter = aaveMeta;
        nav.addBalanceAdapter(address(aaveAdapter));
        bytes32[] memory aaveInstances = new bytes32[](1);
        aaveInstances[0] = bytes32(uint256(uint160(aaveV3DataProvider)));
        nav.setMetaInstances(address(aaveMeta), aaveInstances);

        compoundV3UsdcComet =
            new CompoundV3CometsMetaBalanceAdapter(compoundRewardContract, compound, "Compound V3", address(nav));
        nav.addBalanceAdapter(address(compoundV3UsdcComet));
    }
}
