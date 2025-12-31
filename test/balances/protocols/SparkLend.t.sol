// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {SparkLendBalanceOracle} from "src/balances/protocols/SparkLend.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";

import "src/errors.sol";

contract SparkTest is Test {
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
    IBalanceOracleCustom.PositionMetadata sparkPositionMetadata = IBalanceOracleCustom.PositionMetadata({
        protocol: "Spark",
        position: "Spark Pool",
        positionType: "Supplied/Borrowed"
    });

    function setUp() public {
        fork = vm.createFork(vm.envString("MAINNET_URL"));
        vm.selectFork(fork);
    }

    function test_mainnet_balanceOf_supply_dai() public {
        vm.rollFork(20_734_274);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, sparkPositionMetadata);

        address user = address(0xB6875EC94bE06d159A28d627422b7c9388cc8861);

        int256 balance = oracle.balanceOf(dai, user);
        assertEq(balance, 29_424_026_151_613_828_292_722);
    }

    function test_mainnet_balanceOf_supply_wbtc() public {
        vm.rollFork(20_734_274);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, sparkPositionMetadata);
        address user = address(0xB6875EC94bE06d159A28d627422b7c9388cc8861);

        int256 balance = oracle.balanceOf(wbtc, user);
        assertEq(balance, 4_998_340_534);
    }

    function test_mainnet_balanceOf_borrow_weth() public {
        vm.rollFork(20_734_274);

        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, sparkPositionMetadata);
        address user = address(0xB6875EC94bE06d159A28d627422b7c9388cc8861);

        int256 balance = oracle.balanceOf(weth, user);
        assertEq(balance, -452_317_192_814_843_289_654);
    }

    function test_mainnet_balanceOf_supply_gnosis() public {
        vm.rollFork(17_772_457);
        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, sparkPositionMetadata);
        address user = address(0x849D52316331967b6fF1198e5E32A0eB168D039d);
        int256 balance = oracle.balanceOf(gno, user);
        assertEq(balance, 88_000_000_000_000_000_000_000);
    }

    function test_mainnet_balanceOf_debt_dai() public {
        vm.rollFork(17_772_457);
        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, sparkPositionMetadata);
        address user = address(0x849D52316331967b6fF1198e5E32A0eB168D039d);
        int256 balance = oracle.balanceOf(dai, user);
        assertEq(balance, -1_000_035_715_961_244_421_526_907);
    }

    function test_mainnet_balanceOf_reward_steth() public {
        vm.rollFork(19_685_985);
        oracle = new SparkLendBalanceOracle(dataProvider, rewardsDistributor, sparkPositionMetadata);
        address user = address(0x4F2083f5fBede34C2714aFfb3105539775f7FE64);

        int256 balance = oracle.balanceOf(steth, user);
        assertEq(balance, 121_897_498_127_091_334);
    }
}
