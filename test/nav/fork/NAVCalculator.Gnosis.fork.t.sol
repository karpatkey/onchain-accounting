// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";
import {CrossRatePriceAdapter} from "src/prices/protocols/CrossRate_Price.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

contract GnosisForkNAVCalculatorTest is NAVCalculatorForkHarness {
    /// @notice Gnosis treasury wallet on Gnosis Chain (same as base harness safe)
    address public constant GNOSIS_TREASURY = 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f;

    address public savingsXDaiContract = address(0xaf204776c7245bF4147c2612BF6e5972Ee483701);
    address public xdai = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public wxdai = address(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);
    address public usdPrimeFund = address(0xCE74fa7A7dEe1d7640540bd752Bee784BE831b4F);

    // Chainlink price feeds (Gnosis Chain)
    address public daiToUsdChainlink = address(0x678df3415fc31947dA4324eC63212874be5a82f8); // xDAI/DAI
    address public gnoUsdChainlink = address(0x22441d81416430A54336aB28765abd31a792Ad37); // GNO/USD (0.5%, 86400s, 8dp)
    address public ghoUsdChainlink = address(0x855193775eF2ABb12CF95DE3086229a14Ab8E0E3); // GHO/USD (0.5%, 86400s, 8dp)
    address public ethUsdChainlink = address(0xa767f745331D267c7751297D982b050c93985627); // ETH/USD (0.5%, 86400s, 8dp)
    address public stEthUsdChainlink = address(0x229e486Ee0D35b7A9f668d10a1e6029eEE6B77E0); // STETH/USD (0.5%, 86400s, 8dp)
    address public btcUsdChainlink = address(0x00288135bE38B83249F380e9b6b9a04c90EC39eE); // WBTC/USD (0.5%, 86400s, 8dp)
    address public eurUsdChainlink = address(0xab70BCB260073d036d1660201e9d5405F5829b7a); // EUR/USD (0.1%, 86400s, 8dp)
    address public balUsdChainlink = address(0x1b723C855F7D2c2785F99486973271355e782d77); // BAL/USD (0.5%, 86400s, 8dp)
    address public usdcUsdChainlink = address(0x26C31ac71010aF62E6B486D1132E266D6298857D); // USDC/USD Circle (0.5%, 86400s, 8dp)
    address public usdtUsdChainlink = address(0x68811D7DF835B1c33e6EEae8E7C141eF48d48cc7); // USDT/USD Tether (0.5%, 86400s, 8dp)
    address public wstEthEthChainlink = address(0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA); // wstETH-ETH rate (0.5%, 86400s, 18dp)

    CrossRatePriceAdapter public wstEthPriceFeed;

    // Gnosis Chain token addresses
    address public gno = address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb);
    address public weth = address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1);
    address public wsteth = address(0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6); // bridged wstETH
    address public reth = address(0x62bc7c5d5ae154b0b64784332B8B0F4309926990); // bridged rETH
    address public wbtc = address(0xD7cd100056B477C08B419a28E976D8Ade354251a);
    address public safeToken = address(0xD4e420bb47071Ee2e8d256dCaBf675805A28002a); // SAFE
    address public aura = address(0x1509706A6c66ca5494570e15DFE7B6B5c0df2e88);
    address public cow = address(0x177127622c4A00F3d409B75571e12cB3c8973d3c); // COW (CoW Protocol)
    address public bal = address(0x7eF541E2a22058048904fE5744f9c7E4C57AF717);
    address public usdc = address(0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83); // Circle USDC (native on Gnosis)
    address public usdt = address(0x4ECaBa5870353805a9F068101A40E0f32ed605C6); // Tether USDT

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        setupNavCalculator();
    }

    function test_gnosisFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertTrue(reading.value > 0);
    }

    /// @notice Log all positions found for the Gnosis treasury (0x458c...F5e6f)
    function test_gnosisFork_treasuryPositions() public view {
        address account = GNOSIS_TREASURY;
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(account, address(0));

        assertTrue(navTotal.value > 0, "Treasury should have positive NAV");
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum, "NAV should equal sum of position values");
    }

    function test_gnosisFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(usdPrimeFund, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(usdPrimeFund, address(0));

        assertTrue(navTotal.value > 0);

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupRegisterAssets() internal override {
        savingsXdaiPrice = new sXDAI_PriceOracle(savingsXDaiContract, daiToUsdChainlink, heartbeat);
        // wstETH/USD = (ETH/USD) * (wstETH/ETH) / 10^18
        wstEthPriceFeed = new CrossRatePriceAdapter(
            wsteth,
            ethUsdChainlink, // X/USD = ETH/USD
            wstEthEthChainlink, // Y/X = wstETH/ETH
            heartbeat,
            heartbeat
        );

        // Only register assets that have a matching price feed (custom or Chainlink from above).
        // xDAI / native — pre-registered in initialize; set price feed only
        nav.setPriceFeed(address(xdai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(wxdai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        // sXDAI — custom (uses daiToUsdChainlink)
        nav.registerAsset(address(savingsXDaiContract), address(savingsXdaiPrice), IPrices.PriceType.Custom, heartbeat);

        // GNO/USD, ETH/USD, WBTC/USD, BAL/USD
        nav.registerAsset(gno, gnoUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(weth, ethUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        // wstETH — custom (ethUsdChainlink + wstEthEthChainlink)
        nav.registerAsset(wsteth, address(wstEthPriceFeed), IPrices.PriceType.Custom, heartbeat);
        nav.registerAsset(wbtc, btcUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(bal, balUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);

        // Stablecoins — USDC/USD, USDT/USD
        nav.registerAsset(usdc, usdcUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(usdt, usdtUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        // reth, safeToken, aura, cow: no matching feed in list — not registered
    }

    function setupBalanceOracle() internal override {
        // wxdai - ERC20DefaultOracle already registered globally
    }
}
