// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3CometWithMultiplier} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract OptimismForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    IERC20 public compound = IERC20(0x7e7d4467112689329f7E06571eD0E8CbAd4910eE);

    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public aaveV3rewardsDistributor = address(0x929EC64c34a17401F460460D4B9390518E5B473e);

    IERC20 public cUsdCv3 = IERC20(0x2e44e174f7D53F0212823acC11C01A11d58c5bCB);
    address public compoundRewardContract = address(0x443EA0340cb75a160F31A440722dec7b5bc3C2E9);

    address public usdcToUsdChainlink = address(0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3);
    address public compoundToUsdChainlink = address(0xe1011160d78a80E2eEBD60C228EEf7af4Dfcd4d7);

    function setUp() public {
        _checkSkipForkTests();
        fork = createForkWithCadence(getAlchemyUrl("opt-mainnet"));
        vm.selectFork(fork);
        setupNavCalculator();
    }

    function test_optimismFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();
        assertTrue(reading.value > 0);

        int256 aaveUsdcBalance = aaveOracle.getOracleBalanceForAsset(safe, address(usdc));
        assertTrue(aaveUsdcBalance > 0);
        if (address(compoundV3CometWithMultiplier) != address(0)) {
            int256 compoundBalance = compoundV3CometWithMultiplier.getOracleBalanceForAsset(safe, address(compound));
            assertEq(compoundBalance, 0);
            int256 usdcBalance = compoundV3CometWithMultiplier.getOracleBalanceForAsset(safe, address(usdc));
            assertEq(usdcBalance, 0);
        }
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
    }

    function setupRegisterAssets() internal override {
        nav.registerAsset(address(usdc), usdcToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(compound), compoundToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(
            address(eth), address(0x13e3Ee699d1909E8897221329E6FC2b0B7C1c4D0), IPrices.PriceType.Chainlink, heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        try this.createCompoundOracle(
            compoundRewardContract, address(cUsdCv3), address(compound), address(nav)
        ) returns (CompoundV3CometWithMultiplier oracle) {
            compoundV3CometWithMultiplier = oracle;
            nav.addBalanceOracle(address(aaveOracle));
            nav.addBalanceOracle(address(compoundV3CometWithMultiplier));
        } catch {
            nav.addBalanceOracle(address(aaveOracle));
        }
    }
}
