// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";

import {SparkLendBalanceOracle} from "src/balances/protocols/SparkLend.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InvalidArguments} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

contract SparkTest is TestEnvConfigurator, TestSetupHelpers {
    uint256 public fork;
    uint256 public forkBlock;

    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address public wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address public steth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address public gno = address(0x6810e776880C02933D47DB1b9fc05908e5386b96);
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public dataProvider = address(0xFc21d6d146E6086B8359705C8b28512a983db0cb);
    address public rewardsDistributor = address(0x4370D3b6C9588E02ce9D22e684387859c7Ff5b34);

    SparkLendBalanceOracle public oracle;
    MockBalances mockBalances;
    BalancesHarnessForFork public balances;

    // Global user addresses with positions in Spark
    address public supplyDaiWbtcBorrowWethUser;
    address public supplyGnoDebtDaiUser;
    address public rewardStethUser;

    function setUp() public {
        mockBalances = new MockBalances();

        // Set global user addresses - use addresses that have positions
        supplyDaiWbtcBorrowWethUser = 0xB6875EC94bE06d159A28d627422b7c9388cc8861;
        supplyGnoDebtDaiUser = 0x849D52316331967b6fF1198e5E32A0eB168D039d;
        rewardStethUser = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
    }

    function test_mainnet_balanceOf_supply_dai() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_734_274);

        address[] memory assets = new address[](4);
        assets[0] = dai;
        assets[1] = wbtc;
        assets[2] = weth;
        assets[3] = usdc;
        balances = deployBalancesInFork(assets);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, "Spark", address(balances));

        int256 balance = oracle.getOracleBalanceForAsset(supplyDaiWbtcBorrowWethUser, dai);
        assertGt(balance, 0, "User should have DAI supply position");
    }

    function test_mainnet_balanceOf_supply_wbtc() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_734_274);

        address[] memory assets = new address[](4);
        assets[0] = dai;
        assets[1] = wbtc;
        assets[2] = weth;
        assets[3] = usdc;
        balances = deployBalancesInFork(assets);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, "Spark", address(balances));

        int256 balance = oracle.getOracleBalanceForAsset(supplyDaiWbtcBorrowWethUser, wbtc);
        assertGt(balance, 0, "User should have WBTC supply position");
    }

    function test_mainnet_balanceOf_borrow_weth() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_734_274);

        address[] memory assets = new address[](4);
        assets[0] = dai;
        assets[1] = wbtc;
        assets[2] = weth;
        assets[3] = usdc;
        balances = deployBalancesInFork(assets);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, "Spark", address(balances));

        int256 balance = oracle.getOracleBalanceForAsset(supplyDaiWbtcBorrowWethUser, weth);
        assertLt(balance, 0, "User should have WETH borrow position");
    }

    function test_mainnet_balanceOf_supply_gnosis() public {
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), 17_772_457);

        address[] memory assets = new address[](2);
        assets[0] = gno;
        assets[1] = dai;
        balances = deployBalancesInFork(assets);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, "Spark", address(balances));
        int256 balance = oracle.getOracleBalanceForAsset(supplyGnoDebtDaiUser, gno);
        assertGt(balance, 0, "User should have GNO supply position");
    }

    function test_mainnet_balanceOf_debt_dai() public {
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), 17_772_457);

        address[] memory assets = new address[](2);
        assets[0] = gno;
        assets[1] = dai;
        balances = deployBalancesInFork(assets);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, "Spark", address(balances));
        int256 balance = oracle.getOracleBalanceForAsset(supplyGnoDebtDaiUser, dai);
        assertLt(balance, 0, "User should have DAI debt position");
    }

    function test_mainnet_balanceOf_reward_steth() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 19_685_985);

        balances = deployBalancesInFork(steth);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, "Spark", address(balances));

        int256 balance = oracle.getOracleBalanceForAsset(rewardStethUser, steth);
        assertGt(balance, 0, "User should have stETH reward position");
    }
}
