// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {ChainlinkPriceFeeds} from "test/ChainlinkPriceFeeds.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Minimal interface for Optimism CometRewards.getRewardOwed (state-modifying: accrues account).
interface ICometRewardsGetOwed {
    struct RewardOwed {
        address token;
        uint256 owed;
    }

    function getRewardOwed(address comet, address account) external returns (RewardOwed memory);
}

contract OptimismForkNAVCalculator is NAVCalculatorForkHarness {
    /// @notice Address with Compound V3 (cUSDCv3) positions on Optimism. USDy vault
    address public constant OPTIMISM_SAFE = 0x1eC50880101022C11530A069690F5446d1464592;

    // Native and wrapped ETH
    address public native = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE); // Native ETH (NATIVE)
    address public weth = address(0x4200000000000000000000000000000000000006); // Optimism WETH

    // Token addresses (Optimism Mainnet)
    address public usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85); // USDC (Circle)
    address public usdt = address(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58); // USDT (Tether)
    address public compound = address(0x7e7d4467112689329f7E06571eD0E8CbAd4910eE); // COMP

    // Aave V3 (Optimism)
    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);

    // Compound V3 (Optimism)
    address public cUsdCv3 = address(0x2e44e174f7D53F0212823acC11C01A11d58c5bCB);
    address public cUsdtCv3 = address(0x995E394b8B2437aC8Ce61Ee0bC610D617962B214);
    address public compoundRewardContract = address(0x443EA0340cb75a160F31A440722dec7b5bc3C2E9);

    CompoundV3Comet public compoundV3UsdtComet;

    /// @dev Pinned to a known-good block. See NAVCalculator.Mainnet.fork.t.sol for rationale.
    uint256 public constant FORK_BLOCK = 150_944_800;

    function setUp() public {
        safe = OPTIMISM_SAFE;
        fork = createForkWithCadence(getAlchemyUrl("opt-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function test_optimismFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();
        assertTrue(reading.value > 0, "OPTIMISM_SAFE should have positive NAV");
    }

    function test_optimismFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertTrue(navTotal.value > 0);

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
        console2.log("navTotal.value", navTotal.value);
        console2.log(safe, "safe");
        for (uint256 i = 0; i < positions.length; i++) {
            INAVCalculator.Position memory p = positions[i];
            console2.log("  index", i);
            console2.log("       value", p.value);
            console2.log("       underlyingAsset.symbol", p.underlyingAsset.symbol);
            console2.log("       balanceOracle", p.balanceOracle);
            console2.log("       amount", p.amount);
            console2.log("       isDebt", p.isDebt);
            console2.log("       quoteAsset.asset", p.quoteAsset.asset);
            console2.log("       price", p.price);
            console2.log("       stale", p.stale);
            console2.log("       protocol", p.protocol);
            console2.log("       positionDetail", p.positionDetail);
        }
    }

    function setupRegisterAssets() internal override {
        nav.setPriceFeed(native, ChainlinkPriceFeeds.ethUsdOptimism(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(usdc, ChainlinkPriceFeeds.usdcUsdOptimism(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(usdt, ChainlinkPriceFeeds.usdtUsdOptimism(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(weth, ChainlinkPriceFeeds.ethUsdOptimism(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(compound, ChainlinkPriceFeeds.compUsdOptimism(), IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceOracle() internal override {
        aaveOracle = new AaveV3InstanceBalanceOracle(aaveV3DataProvider, "Aave v3", "{\"protocol\":\"Aave V3\",\"product\":\"Lending\"", "0x0000000000000000000000000000000000000001", address(nav));
        nav.addBalanceOracle(address(aaveOracle));

        compoundV3Comet =
            this.createCompoundOracle(compoundRewardContract, cUsdCv3, compound, "Compound v3 USDC", address(nav));
        nav.addBalanceOracle(address(compoundV3Comet));

        compoundV3UsdtComet =
            this.createCompoundOracle(compoundRewardContract, cUsdtCv3, compound, "Compound v3 USDT", address(nav));
        nav.addBalanceOracle(address(compoundV3UsdtComet));
    }
}
