// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CometExtInterface,
    CompoundV3CometWithMultiplier
} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import {InvalidArguments} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

interface CometRewardsAux {
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

contract CompoundV3CometWithMultiplierTest is TestEnvConfigurator, TestSetupHelpers {
    int64 baseIndexScale = 1e15;

    address compoundRewards = address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae);
    address rewardToken = 0x354A6dA3fcde098F8389cad84b0182725c6C91dE;
    IERC20 usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 usdcv3 = IERC20(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    IERC20 usdtv3 = IERC20(0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07);
    address weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address wstEth = address(0x5979D7b546E38E414F7E9822514be443A4800529);
    address wbtc = address(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    CometExtInterface comet;
    uint256 fork;
    uint256 forkBlock;

    mapping(address => int256) expectedBalances;

    CompoundV3CometWithMultiplier oracle;
    MockBalances mockBalances;
    BalancesHarnessForFork public balancesContract;

    // Global user addresses with positions in Compound V3 (Arbitrum)
    address public lendBorrowUser;
    address public multiCollateralUser;

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        // Using latest block - all contracts should exist

        mockBalances = new MockBalances();

        balancesContract = _deployBalancesForOracle();
        oracle = new CompoundV3CometWithMultiplier(
            compoundRewards, address(usdcv3), rewardToken, "Compound v3", "USDC Comet", address(balancesContract)
        );

        comet = CometExtInterface(address(usdcv3));

        // Set global user addresses - use addresses that have positions
        lendBorrowUser = 0x30b4B07f3B2dA829Af6Fc459b58906a16a5f979e;
        multiCollateralUser = 0xFE99cC4664A939f826DBeb545C1AAd4c89ee737a;
    }

    function _deployBalancesForOracle() internal returns (BalancesHarnessForFork) {
        // Create temporary oracle to get supported assets
        CompoundV3CometWithMultiplier tempOracle = new CompoundV3CometWithMultiplier(
            compoundRewards, address(usdcv3), rewardToken, "Compound v3", "USDC Comet", address(mockBalances)
        );
        address[] memory assets = tempOracle.underlyingAssetsSupported();
        // Also add reward token
        address[] memory allAssets = new address[](assets.length + 1);
        for (uint256 i = 0; i < assets.length; i++) {
            allAssets[i] = assets[i];
        }
        allAssets[assets.length] = rewardToken;
        return deployBalancesInFork(allAssets);
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

    function test_mainnet_balanceOf_lend() public view {
        int256 balanceWeth = oracle.getOracleBalanceForAsset(lendBorrowUser, address(weth));
        assertGt(balanceWeth, 0, "User should have WETH collateral position");
    }

    function test_mainnet_balanceOf_borrow() public view {
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(lendBorrowUser, address(usdc));
        assertLt(balanceUsdc, 0, "User should have USDC borrow position");
    }

    function test_mainnet_balanceOf_rewardToken() public {
        int256 balanceComp = oracle.getOracleBalanceForAsset(lendBorrowUser, address(rewardToken));
        // User should have rewards
        assertGt(balanceComp, 0, "User should have reward token balance");
    }

    function test_mainnet_balanceOf_multiCollaterals() public {
        // Deploy balances for USDT comet
        CompoundV3CometWithMultiplier tempOracle = new CompoundV3CometWithMultiplier(
            compoundRewards, address(usdtv3), rewardToken, "Compound v3", "USDC Comet", address(mockBalances)
        );
        address[] memory assets = tempOracle.underlyingAssetsSupported();
        address[] memory allAssets = new address[](assets.length + 1);
        for (uint256 i = 0; i < assets.length; i++) {
            allAssets[i] = assets[i];
        }
        allAssets[assets.length] = rewardToken;
        BalancesHarnessForFork usdtBalances = deployBalancesInFork(allAssets);

        oracle = new CompoundV3CometWithMultiplier(
            compoundRewards, address(usdtv3), rewardToken, "Compound v3", "USDC Comet", address(usdtBalances)
        );
        comet = CometExtInterface(address(usdtv3));

        expectedBalances[wbtc] = 3_700_000_000;
        expectedBalances[wstEth] = 1_448_502_535_701_411_162_041;

        uint8 numAssets = comet.numAssets();
        bool hasPosition = false;
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            int256 balance = oracle.getOracleBalanceForAsset(multiCollateralUser, asset);
            if (balance != 0) {
                hasPosition = true;
                assertGt(balance, 0, "User should have positive collateral position");
            }
        }
        assertTrue(hasPosition, "User should have at least one collateral position");
    }

    function test_balanceOf_unsupportedToken() public {
        address unsupportedToken = address(1);

        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(address(this), unsupportedToken);
        assertEq(balance, 0);
    }

    function test_positionOf_userWithoutPosition() public view {
        address user = address(1);
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertEq(balanceUsdc, 0);
    }

    function test_getUnderlying_edgeCases_MaxPrincipal() public {
        address user = address(1);

        int104 maxPositivePrincipal = type(int104).max;
        vm.mockCall(
            address(usdcv3),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 0, 0, 0, 0, 1)
        );

        int256 underlying = oracle.getOracleBalanceForAsset(user, address(usdc));
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

        int256 underlying = oracle.getOracleBalanceForAsset(user, address(usdc));
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

        int256 underlying = oracle.getOracleBalanceForAsset(user, address(rewardToken));
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

        int256 underlying = oracle.getOracleBalanceForAsset(user, address(rewardToken));
        assertEq(underlying, 2_000_000_000_000);
    }
}
