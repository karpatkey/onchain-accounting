// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CometExtInterface, CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

interface CometRewardsAux {
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

contract CompoundV3CometTest is TestEnvConfigurator, TestSetupHelpers {
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

    mapping(address => int256) expectedBalances;

    CompoundV3Comet oracle;
    MockBalances mockBalances;
    BalancesHarnessForFork public balancesContract;

    // Global user addresses with positions in Compound V3
    address public lendUser;
    address public borrowUser;
    address public multiCollateralUser;
    address public compOnlyUser;

    function setUp() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_570_307);
        mockBalances = new MockBalances();

        balancesContract = _deployBalancesForOracle();
        oracle = new CompoundV3Comet(
            compoundRewards, address(usdcv3), rewardToken, "Compound v3", "USDC Comet", address(balancesContract)
        );

        comet = CometExtInterface(address(usdcv3));

        // Register all supported assets in MockBalances (for non-fork tests)
        _registerOracleAssets();

        // Set global user addresses - use addresses that have positions at the fork block
        lendUser = 0x2b2E894f08F1BF8C93a82297c347EbdC8717d99a;
        borrowUser = 0xe84A061897afc2e7fF5FB7e3686717C528617487;
        multiCollateralUser = 0xc94A3Ff0bac12eeB9ff0CC4e08511E1FFaD6ba94;
        compOnlyUser = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;
    }

    function _deployBalancesForOracle() internal returns (BalancesHarnessForFork) {
        // Create temporary oracle to get supported assets
        CompoundV3Comet tempOracle = new CompoundV3Comet(
            compoundRewards, address(usdcv3), rewardToken, "Compound v3", "USDC Comet", address(mockBalances)
        );
        address[] memory assets = tempOracle.underlyingAssetsSupported();
        return deployBalancesInFork(assets);
    }

    function _registerOracleAssets() internal {
        address[] memory assets = oracle.underlyingAssetsSupported();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            try IERC20Metadata(asset).decimals() returns (uint8 decimals) {
                mockBalances.setAssetDecimals(asset, decimals);
            } catch {
                // If decimals() fails, use default 18 (common for many tokens)
                mockBalances.setAssetDecimals(asset, 18);
            }
        }
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
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(lendUser, address(usdc));
        // User should have a positive lending position
        assertGt(balanceUsdc, 0, "User should have a positive USDC lending position");

        int256 balanceComp = oracle.getOracleBalanceForAsset(lendUser, address(rewardToken));
        // User should have rewards
        assertGt(balanceComp, 0, "User should have COMP rewards");
    }

    function test_mainnet_balanceOf_borrow() public {
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(borrowUser, address(usdc));
        // User should have a negative borrowing position
        assertLt(balanceUsdc, 0, "User should have a negative USDC borrowing position");

        int256 balanceComp = oracle.getOracleBalanceForAsset(borrowUser, address(rewardToken));
        // User should have rewards
        assertGt(balanceComp, 0, "User should have COMP rewards");

        int256 balanceWbtc = oracle.getOracleBalanceForAsset(borrowUser, wbtc);
        // User should have WBTC collateral
        assertGt(balanceWbtc, 0, "User should have WBTC collateral");
    }

    function test_mainnet_balanceOf_singleCollaterals() public view {
        int256 balance = oracle.getOracleBalanceForAsset(borrowUser, wbtc);

        // User should have WBTC collateral
        assertGt(balance, 0, "User should have WBTC collateral position");
    }

    function test_mainnet_balanceOf_multiCollaterals() public {
        uint8 numAssets = comet.numAssets();
        bool hasCollateral = false;
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            int256 balance = oracle.getOracleBalanceForAsset(multiCollateralUser, asset);
            if (balance != 0) {
                hasCollateral = true;
                // If it's the reward token, it should be positive (rewards + collateral)
                if (asset == address(rewardToken)) {
                    assertGt(balance, 0, "Reward token balance should be positive");
                } else {
                    // Other collaterals should be positive
                    assertGt(balance, 0, "Collateral balance should be positive");
                }
            }
        }

        assertTrue(hasCollateral, "User should have at least one collateral position");

        // User should have a borrowing position (negative USDC balance)
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(multiCollateralUser, address(usdc));
        assertLt(balanceUsdc, 0, "User should have a negative USDC borrowing position");
    }

    function test_mainnet_balanceOf_compAsRewardAndCollateral() public {
        uint256 collateral = comet.collateralBalanceOf(multiCollateralUser, address(rewardToken));

        int256 balance = oracle.getOracleBalanceForAsset(multiCollateralUser, address(rewardToken));

        // User should have COMP position (either as collateral or rewards)
        assertGt(balance, 0, "User should have COMP position");

        // Verify that the balance is at least the collateral amount
        // casting to 'int256' is safe because collateral is always positive
        // forge-lint: disable-next-line(unsafe-typecast)
        assertGe(balance, int256(collateral), "Oracle balance should be at least the collateral amount");
    }

    function test_mainnet_balanceOf_comp() public {
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(compOnlyUser, address(usdc));
        // User should have no USDC position (neither lending nor borrowing)
        assertEq(balanceUsdc, 0, "User should have no USDC position");

        int256 balanceComp = oracle.getOracleBalanceForAsset(compOnlyUser, address(rewardToken));
        // User should have COMP rewards
        assertGt(balanceComp, 0, "User should have COMP rewards");
    }

    function test_mainnet_balanceOf_only_comp_in_given_comet() public {
        deal(address(rewardToken), compOnlyUser, 1 ether);

        int256 balanceUsdc = oracle.getOracleBalanceForAsset(compOnlyUser, address(usdc));
        // User should have no USDC position (neither lending nor borrowing)
        assertEq(balanceUsdc, 0, "User should have no USDC position");

        int256 balanceComp = oracle.getOracleBalanceForAsset(compOnlyUser, address(rewardToken));
        // User should have COMP rewards (note: deal() gives user tokens, but oracle only reports protocol positions)
        // The balance should still reflect the unclaimed rewards from the protocol
        assertGt(balanceComp, 0, "User should have COMP rewards from protocol");
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
            abi.encode(maxPositivePrincipal, 0, 0, 0, 0)
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
            abi.encode(maxNegativePrincipal, 0, 0, 0, 0)
        );

        int256 underlying = oracle.getOracleBalanceForAsset(user, address(usdc));
        assert(underlying < 0);
    }
}
