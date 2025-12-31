// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {
    CometExtInterface, CompoundV3CometWithMultiplier
} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import "src/errors.sol";

interface CometRewardsAux {
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

contract CompoundV3CometWithMultiplierTest is Test {
    int64 BASE_INDEX_SCALE = 1e15;

    address compoundRewards = address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae);
    address rewardToken = 0x354A6dA3fcde098F8389cad84b0182725c6C91dE;
    IERC20 usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 usdcv3 = IERC20(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    IERC20 usdtv3 = IERC20(0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07);
    address weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address wstETH = address(0x5979D7b546E38E414F7E9822514be443A4800529);
    address wbtc = address(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    CometExtInterface comet;
    uint256 fork;
    uint256 forkBlock;

    mapping(address => int256) balances;

    CompoundV3CometWithMultiplier oracle;
    IBalanceOracleCustom.PositionMetadata compoundMetadata = IBalanceOracleCustom.PositionMetadata({
        protocol: "Compound v3",
        position: "USDC Comet",
        positionType: "Supplied/Borrowed"
    });

    function setUp() public {
        fork = vm.createFork(vm.envString("ARBITRUM_URL"));
        vm.selectFork(fork);

        oracle = new CompoundV3CometWithMultiplier(compoundRewards, address(usdcv3), rewardToken, compoundMetadata);

        comet = CometExtInterface(address(usdcv3));

        vm.rollFork(256_551_128);
    }

    function test_initialization() public view {
        assertEq(oracle.baseToken(), address(usdc));
        assertEq(address(oracle.rewardToken()), address(rewardToken));
        assertEq(oracle.comet(), address(usdcv3));

        uint8 numAssets = comet.numAssets();
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            assertTrue(oracle.isCollateral(asset));
        }
    }

    function test_mainnet_balanceOf_lend() public view {
        address user = address(0x30b4B07f3B2dA829Af6Fc459b58906a16a5f979e);

        int256 balanceUSDC = oracle.balanceOf(address(weth), user);
        assertEq(balanceUSDC, 19_750_000_000_000_000_000);
    }

    function test_mainnet_balanceOf_borrow() public view {
        address user = address(0x30b4B07f3B2dA829Af6Fc459b58906a16a5f979e);

        int256 balanceUSDC = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUSDC, -16_653_787_188);
    }

    function test_mainnet_balanceOf_rewardToken() public {
        address user = address(0x30b4B07f3B2dA829Af6Fc459b58906a16a5f979e);

        int256 balanceCOMP = oracle.balanceOf(address(rewardToken), user);
        assertEq(uint256(balanceCOMP), 217_509_000_000_000_000);

        //  update the rewards check if it is the same as the balance
        (, uint256 owed) = CometRewardsAux(compoundRewards).getRewardOwed(address(usdcv3), user);
        assertEq(uint256(balanceCOMP), owed);
    }

    function test_mainnet_balanceOf_multiCollaterals() public {
        oracle = new CompoundV3CometWithMultiplier(compoundRewards, address(usdtv3), rewardToken, compoundMetadata);
        comet = CometExtInterface(address(usdtv3));

        address user = address(0xFE99cC4664A939f826DBeb545C1AAd4c89ee737a);

        balances[wbtc] = 3_700_000_000;
        balances[wstETH] = 1_448_502_535_701_411_162_041;

        uint8 numAssets = comet.numAssets();
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            assertEq(oracle.balanceOf(asset, user), balances[asset]);
        }
    }

    function test_balanceOf_unsupportedToken() public {
        address unsupportedToken = address(1);

        vm.expectRevert(InvalidArguments.selector);
        oracle.balanceOf(unsupportedToken, address(this));
    }

    function test_positionOf_userWithoutPosition() public view {
        address user = address(1);
        int256 balanceUSDC = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUSDC, 0);
    }

    function test_getUnderlying_edgeCases_MaxPrincipal() public {
        address user = address(1);

        int104 maxPositivePrincipal = type(int104).max;
        vm.mockCall(
            address(usdcv3),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 0, 0, 0, 0, 1)
        );

        int256 underlying = oracle.balanceOf(address(usdc), user);
        assert(underlying > 0);
    }

    function test_getUnderlying_edgeCases_MinimalPrincipal() public {
        address user = address(1);

        int104 maxNegativePrincipal = type(int104).min;
        vm.mockCall(
            address(usdcv3),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxNegativePrincipal, 0, 0, 0, 0, 1)
        );

        int256 underlying = oracle.balanceOf(address(usdc), user);
        assert(underlying < 0);
    }

    function test_getUnderlying_edgeCases_OneMultiplier() public {
        address user = address(1);

        int104 maxPositivePrincipal = 1;
        vm.mockCall(
            address(usdcv3),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 1, 1, 1, 1, 1)
        );

        int256 underlying = oracle.balanceOf(address(rewardToken), user);
        assertEq(underlying, 1_000_000_000_000);
    }

    function test_getUnderlying_edgeCases_DoubleMultiplier() public {
        address user = address(1);

        int104 maxNegativePrincipal = 1;
        vm.mockCall(
            address(usdcv3),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxNegativePrincipal, 1, 2, 1, 1, 1)
        );

        int256 underlying = oracle.balanceOf(address(rewardToken), user);
        assertEq(underlying, 2_000_000_000_000);
    }
}
