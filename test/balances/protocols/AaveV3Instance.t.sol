// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/errors.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";

contract AavePoolBalanceOracleTest is TestEnvConfigurator {
    uint256 fork;
    uint256 forkBlock;

    address usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address sdai = address(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    address wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address usdt = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address aaveDataProvider = address(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);
    address public rewardsDistributor = address(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    AaveV3InstanceBalanceOracle oracle;
    IBalanceOracleCustom.PositionMetadata aaveMetadata = IBalanceOracleCustom.PositionMetadata({
        protocol: "Aave v3",
        position: "Core Instance",
        positionType: "Supplied/Borrowed"
    });

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(20_576_908);

        oracle = new AaveV3InstanceBalanceOracle(aaveDataProvider, rewardsDistributor, aaveMetadata);
    }

    function test_balanceOf_reverts_on_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        vm.expectRevert(InvalidArguments.selector);
        oracle.balanceOf(invalidToken, 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f);
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();

        address[33] memory expected;
        expected[0] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        expected[1] = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        expected[2] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        expected[3] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        expected[4] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        expected[5] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        expected[6] = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
        expected[7] = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
        expected[8] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        expected[9] = 0xae78736Cd615f374D3085123A210448E74Fc6393;
        expected[10] = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
        expected[11] = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        expected[12] = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
        expected[13] = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
        expected[14] = 0xba100000625a3754423978a60c9317c58a424e3D;
        expected[15] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        expected[16] = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
        expected[17] = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
        expected[18] = 0x111111111117dC0aa78b770fA6A738034120C302;
        expected[19] = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
        expected[20] = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
        expected[21] = 0xD33526068D116cE69F19A9ee46F0bd304F21A51f;
        expected[22] = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
        expected[23] = 0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6;
        expected[24] = 0xdeFA4e8a7bcBA345F687a2f1456F5Edd9CE97202;
        expected[25] = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
        expected[26] = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
        expected[27] = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
        expected[28] = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
        expected[29] = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
        expected[30] = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
        expected[31] = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;
        expected[32] = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

        assertEq(assets.length, expected.length);

        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(assets[i], expected[i]);
        }
    }

    function test_mainnet_balanceOf_supply_wbtc_lend_usdc() public view {
        address user = address(0xeE7ca610D896C53ffe716B801C05748EfD902954);

        int256 balance = oracle.balanceOf(wbtc, user);
        assertEq(balance, 15_817_337_637);

        balance = oracle.balanceOf(usdc, user);
        assertEq(balance, -6_652_027_126_584);

        balance = oracle.balanceOf(dai, user);
        assertEq(balance, 0);
    }

    function test_mainnet_balanceOf_supply_wbtc_lend_usdc_dai() public view {
        address user = address(0xe84A061897afc2e7fF5FB7e3686717C528617487);

        int256 balance = oracle.balanceOf(wbtc, user);
        assertEq(balance, 100_099_410_296);

        balance = oracle.balanceOf(usdc, user);
        assertEq(balance, -29_652_399_617_829);

        balance = oracle.balanceOf(dai, user);
        assertEq(balance, -1_644_198_157_765_126_542_063_430);
    }

    function test_mainnet_balanceOf_lend_usdc() public view {
        address user = address(0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B);

        int256 balance = oracle.balanceOf(usdc, user);
        assertEq(balance, 75_564_589_075);
    }

    function test_mainnet_balanceOf_lend_usdt() public {
        fork = vm.createFork(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(21_379_222);

        oracle = new AaveV3InstanceBalanceOracle(aaveDataProvider, rewardsDistributor, aaveMetadata);
        address user = address(0x18709E89BD403F470088aBDAcEbE86CC60dda12e);

        int256 balance = oracle.balanceOf(usdt, user);
        assertEq(balance, 569_793_916_136_725);
    }
}
