// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ArbitrumForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IERC20 public cUsdCv3 = IERC20(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    IERC20 public compound = IERC20(0x354A6dA3fcde098F8389cad84b0182725c6C91dE);

    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public aaveV3rewardsDistributor = address(0x929EC64c34a17401F460460D4B9390518E5B473e);

    address public compoundRewardContract = address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae);

    function setUp() public {
        _checkSkipForkTests();
        fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        setupNavCalculator();
    }

    function test_arbitrumFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();
        assertTrue(reading.value > 0);
        int256 aaveUsdcBalance = aaveOracle.getOracleBalanceForAsset(safe, address(usdc));
        assertTrue(aaveUsdcBalance > 0);
        (uint256 price,,) = nav.latestPrice(address(usdc));
        assertTrue(price > 0);
    }

    function test_arbitrumFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertTrue(navTotal.value > 0);

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupRegisterAssets() internal override {
        nav.registerAsset(
            address(usdc), address(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3), IPrices.PriceType.Chainlink, heartbeat
        );
        nav.registerAsset(
            address(compound),
            address(0xe7C53FFd03Eb6ceF7d208bC4C13446c76d1E5884),
            IPrices.PriceType.Chainlink,
            heartbeat
        );
        nav.registerAsset(
            address(eth), address(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612), IPrices.PriceType.Chainlink, heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        compoundV3Comet = new CompoundV3Comet(
            compoundRewardContract, address(cUsdCv3), address(compound), "Compound v3", "USDC Comet", address(nav)
        );

        nav.addBalanceOracle(address(aaveOracle));
        nav.addBalanceOracle(address(compoundV3Comet));
    }
}
