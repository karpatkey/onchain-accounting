// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {CometExtInterface, CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

interface CometRewardsAux {
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

contract CompoundV3CometTest is TestEnvConfigurator {
    int64 BASE_INDEX_SCALE = 1e15;

    address compoundRewards = address(0x1B0e765F6224C21223AeA2af16c1C46E38885a40);
    address rewardToken = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 usdcv3 = IERC20(0xc3d688B66703497DAA19211EEdff47f25384cdc3);
    address wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address wstETH = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    CometExtInterface comet;
    uint256 fork;
    uint256 forkBlock;

    mapping(address => int256) balances;

    CompoundV3Comet oracle;
    MockBalances mockBalances;

    function setUp() public {
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), 20_570_307);
        mockBalances = new MockBalances();

        oracle = new CompoundV3Comet(
            compoundRewards, address(usdcv3), rewardToken, "Compound v3", "USDC Comet", address(mockBalances)
        );

        comet = CometExtInterface(address(usdcv3));
    }

    function test_initialization() public view {
        assertEq(oracle.BASE_TOKEN(), address(usdc));
        assertEq(address(oracle.REWARD_TOKEN()), address(rewardToken));
        assertEq(oracle.COMET(), address(usdcv3));

        uint8 numAssets = comet.numAssets();
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            assertTrue(oracle.isCollateral(asset));
        }
    }

    function test_mainnet_balanceOf_lend() public {
        address user = address(0x2b2E894f08F1BF8C93a82297c347EbdC8717d99a);

        int256 balanceUsdc = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUsdc, 4_897_852_126_376);

        int256 balanceComp = oracle.balanceOf(address(rewardToken), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(43_291_868_000_000_000_000));

        //  update the rewards check if it is the same as the balance
        (, uint256 owed) = CometRewardsAux(compoundRewards).getRewardOwed(address(usdcv3), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(owed));
    }

    function test_mainnet_balanceOf_borrow() public {
        address user = address(0xe84A061897afc2e7fF5FB7e3686717C528617487);

        int256 balanceUsdc = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUsdc, -36_049_048_499_829);

        int256 balanceComp = oracle.balanceOf(address(rewardToken), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(657_197_641_000_000_000_000));

        int256 balance = oracle.balanceOf(address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599), user);

        assertEq(balance, 133_935_692_227);

        // update the rewards on the rewards contract to the latest value check if it is the same as the balance
        (, uint256 owed) = CometRewardsAux(compoundRewards).getRewardOwed(address(usdcv3), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(owed));
    }

    function test_mainnet_balanceOf_singleCollaterals() public view {
        address user = address(0xe84A061897afc2e7fF5FB7e3686717C528617487);

        int256 balance = oracle.balanceOf(wbtc, user);

        assertEq(balance, 133_935_692_227);
    }

    function test_mainnet_balanceOf_multiCollaterals() public {
        address user = address(0xc94A3Ff0bac12eeB9ff0CC4e08511E1FFaD6ba94);

        balances[address(rewardToken)] = 377_809_744_199_659_095_377;
        balances[wbtc] = 21_663_016_415;
        balances[wstETH] = 841_162_958_691_745_465_963;
        balances[weth] = 20_000_000_000_000_000_000;

        uint8 numAssets = comet.numAssets();
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            assertEq(oracle.balanceOf(asset, user), balances[asset]);
        }

        assertEq(oracle.balanceOf(address(usdc), user), -8_134_829_135_175);
    }

    function test_mainnet_balanceOf_compAsRewardAndCollateral() public {
        address user = address(0xc94A3Ff0bac12eeB9ff0CC4e08511E1FFaD6ba94);

        uint256 collateral = comet.collateralBalanceOf(user, address(rewardToken));

        int256 balance = oracle.balanceOf(address(rewardToken), user);

        assertEq(balance, 377_809_744_199_659_095_377);

        // Update the rewards, check that the latest value equal to total collateral + unclaimed rewards
        (, uint256 owed) = CometRewardsAux(compoundRewards).getRewardOwed(address(usdcv3), user);
        uint256 totalRewardToken = collateral + owed;

        assertEq(balance, int256(totalRewardToken));
    }

    function test_mainnet_balanceOf_comp() public {
        address user = address(0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B);

        int256 balanceUsdc = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUsdc, 0);

        int256 balanceComp = oracle.balanceOf(address(rewardToken), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(334_673_000_000_000_000));

        // update the rewards check if it is the same as the balance
        (, uint256 owed) = CometRewardsAux(compoundRewards).getRewardOwed(address(usdcv3), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(owed));
    }

    function test_mainnet_balanceOf_only_comp_in_given_comet() public {
        address user = address(0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B);

        deal(address(rewardToken), user, 1 ether);

        int256 balanceUsdc = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUsdc, 0);

        int256 balanceComp = oracle.balanceOf(address(rewardToken), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(334_673_000_000_000_000));

        // update the rewards check if it is the same as the balance
        (, uint256 owed) = CometRewardsAux(compoundRewards).getRewardOwed(address(usdcv3), user);
        // casting to 'int256' is safe because reward amounts are always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(balanceComp, int256(owed));
    }

    function test_balanceOf_unsupportedToken() public {
        address unsupportedToken = address(1);

        vm.expectRevert(InvalidArguments.selector);
        oracle.balanceOf(unsupportedToken, address(this));
    }

    function test_positionOf_userWithoutPosition() public view {
        address user = address(1);
        int256 balanceUsdc = oracle.balanceOf(address(usdc), user);
        assertEq(balanceUsdc, 0);
    }

    function test_getUnderlying_edgeCases_MaxPrincipal() public {
        address user = address(1);

        int104 maxPositivePrincipal = type(int104).max;
        vm.mockCall(
            address(usdcv3),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 0, 0, 0, 0)
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
            abi.encode(maxNegativePrincipal, 0, 0, 0, 0)
        );

        int256 underlying = oracle.balanceOf(address(usdc), user);
        assert(underlying < 0);
    }
}
