// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BaseForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IERC20 public cUsdCv3 = IERC20(0xb125E6687d4313864e53df431d5425969c15Eb2F);
    IERC20 public compound = IERC20(0x9e1028F5F1D5eDE59748FFceE5532509976840E0);

    address public aaveV3DataProvider = address(0xd82a47fdebB5bf5329b09441C3DaB4b5df2153Ad);
    address public aaveV3rewardsDistributor = address(0xf9cc4F0D883F1a1eb2c253bdb46c254Ca51E1F44);

    address public compoundRewardContract = address(0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1);
    address public morphoBlue = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    bytes32 public marketIdWsethUsdc = 0xdba352d93a64b17c71104cbddc6aef85cd432322a1446b5b65163cbbc615cd0c;

    function setUp() public {
        _checkSkipForkTests();
        fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        setupNavCalculator();
    }

    function test_baseFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        int256 morphoBalance = morphoBlueOracle.getOracleBalanceForAsset(safe, address(usdc));
        assertTrue(morphoBalance > 0);
        int256 aaveBalance = aaveOracle.getOracleBalanceForAsset(safe, address(usdc));
        assertTrue(aaveBalance > 0);
        int256 compoundBalance = compoundV3Comet.getOracleBalanceForAsset(safe, address(compound));
        assertTrue(compoundBalance > 0);

        assertTrue(reading.value > 0);
    }

    function test_baseFork_getAllPositions() public view {
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
            address(usdc), address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B), IPrices.PriceType.Chainlink, heartbeat
        );
        nav.registerAsset(
            address(compound),
            address(0x9DDa783DE64A9d1A60c49ca761EbE528C35BA428),
            IPrices.PriceType.Chainlink,
            heartbeat
        );
        nav.registerAsset(
            address(eth), address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70), IPrices.PriceType.Chainlink, heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        compoundV3Comet = new CompoundV3Comet(
            compoundRewardContract, address(cUsdCv3), address(compound), "Compound v3", "USDC Comet", address(nav)
        );

        morphoBlueOracle =
            new MorphoMarketBalanceOracle(morphoBlue, marketIdWsethUsdc, "Morpho", "Some Market", address(nav));

        nav.addBalanceOracle(address(aaveOracle));
        nav.addBalanceOracle(address(compoundV3Comet));
        nav.addBalanceOracle(address(morphoBlueOracle));
    }
}
