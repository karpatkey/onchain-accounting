// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CometExtInterface, CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title CompoundV3CometBalanceOracleForkTest
/// @notice Fork tests for CompoundV3CometBalanceOracle using real mainnet contracts
/// @dev Tests adapter behavior with real Compound V3 protocol contracts and positions
contract CompoundV3CometBalanceOracleForkTest is BalanceAdapterForkTestBase {
    // Compound V3 contract addresses (mainnet)
    address public constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address public constant REWARD_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address public constant USDCV3_COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    // Token addresses
    IERC20 public constant USDC = IERC20(MAINNET_USDC);
    address public constant WBTC = MAINNET_WBTC;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = MAINNET_WETH;

    // Oracle instance
    CompoundV3Comet public oracle;
    CometExtInterface public comet;

    // Real user addresses with positions in Compound V3 at fork block
    address public constant LEND_USER = 0x2b2E894f08F1BF8C93a82297c347EbdC8717d99a;
    address public constant BORROW_USER = 0xe84A061897afc2e7fF5FB7e3686717C528617487;
    address public constant MULTI_COLLATERAL_USER = 0xc94A3Ff0bac12eeB9ff0CC4e08511E1FFaD6ba94;
    address public constant COMP_ONLY_USER = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;

    // Fork block
    uint256 public constant FORK_BLOCK = 20_570_307;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle =
            new CompoundV3Comet(COMPOUND_REWARDS, USDCV3_COMET, REWARD_TOKEN, "Compound v3 USDC", address(balances));
        comet = CometExtInterface(USDCV3_COMET);
    }

    function _getSupportedAssets() internal returns (address[] memory) {
        // Temp Balances (with code) required by adapter constructor; only underlyingAssetsSupported() is used
        BalancesHarnessForFork tempBalances = new BalancesHarnessForFork();
        CompoundV3Comet tempOracle = new CompoundV3Comet(
            COMPOUND_REWARDS, USDCV3_COMET, REWARD_TOKEN, "Compound v3 USDC", address(tempBalances)
        );
        address[] memory raw = tempOracle.underlyingAssetsSupported();
        // Deduplicate (adapter can return same asset e.g. COMP as collateral and reward)
        uint256 n = raw.length;
        uint256 uniqueCount = 0;
        for (uint256 i = 0; i < n; i++) {
            bool seen = false;
            for (uint256 j = 0; j < i; j++) {
                if (raw[j] == raw[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) uniqueCount++;
        }
        address[] memory assets = new address[](uniqueCount);
        uint256 k = 0;
        for (uint256 i = 0; i < n; i++) {
            bool seen = false;
            for (uint256 j = 0; j < i; j++) {
                if (raw[j] == raw[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) assets[k++] = raw[i];
        }
        return assets;
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(oracle.BASE_TOKEN(), address(USDC));
        assertEq(address(oracle.REWARD_TOKEN()), REWARD_TOKEN);
        assertEq(oracle.COMET(), USDCV3_COMET);

        uint8 numAssets = comet.numAssets();
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            assertTrue(oracle.isCollateral(asset));
        }
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_lend() public view {
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(LEND_USER, address(USDC));
        // User should have a positive lending position
        assertGt(amountUsdc, 0, "User should have a positive USDC lending position");
        assertFalse(isDebtUsdc);

        (uint256 amountComp,) = oracle.getOracleBalanceForAsset(LEND_USER, REWARD_TOKEN);
        // User should have rewards
        assertGt(amountComp, 0, "User should have COMP rewards");
    }

    function test_getOracleBalanceForAsset_borrow() public view {
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(BORROW_USER, address(USDC));
        // User should have a debt position
        assertTrue(isDebtUsdc, "User should have a USDC borrowing position (negative balance)");
        assertGt(amountUsdc, 0, "User should have USDC debt");

        (uint256 amountComp,) = oracle.getOracleBalanceForAsset(BORROW_USER, REWARD_TOKEN);
        // User should have rewards
        assertGt(amountComp, 0, "User should have COMP rewards");

        (uint256 amountWbtc, bool isDebtWbtc) = oracle.getOracleBalanceForAsset(BORROW_USER, WBTC);
        // User should have WBTC collateral
        assertGt(amountWbtc, 0, "User should have WBTC collateral");
        assertFalse(isDebtWbtc);
    }

    function test_getOracleBalanceForAsset_singleCollaterals() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(BORROW_USER, WBTC);

        // User should have WBTC collateral
        assertGt(amount, 0, "User should have WBTC collateral position");
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_multiCollaterals() public view {
        uint8 numAssets = comet.numAssets();
        bool hasCollateral = false;
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(MULTI_COLLATERAL_USER, asset);
            if (amount != 0) {
                hasCollateral = true;
                // If it's the reward token, it should be positive (rewards + collateral)
                if (asset == REWARD_TOKEN) {
                    assertGt(amount, 0, "Reward token balance should be positive");
                } else {
                    // Other collaterals should be positive
                    assertGt(amount, 0, "Collateral balance should be positive");
                }
                assertFalse(isDebt);
            }
        }

        assertTrue(hasCollateral, "User should have at least one collateral position");

        // User should have a borrowing position (debt USDC position)
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(MULTI_COLLATERAL_USER, address(USDC));
        assertTrue(isDebtUsdc, "User should have a USDC borrowing position (negative balance)");
        assertGt(amountUsdc, 0, "User should have USDC debt");
    }

    function test_getOracleBalanceForAsset_compAsRewardAndCollateral() public view {
        uint256 collateral = comet.collateralBalanceOf(MULTI_COLLATERAL_USER, REWARD_TOKEN);

        (uint256 amount,) = oracle.getOracleBalanceForAsset(MULTI_COLLATERAL_USER, REWARD_TOKEN);

        // User should have COMP position (either as collateral or rewards)
        assertGt(amount, 0, "User should have COMP position");

        // Verify that the balance is at least the collateral amount
        assertGe(amount, collateral, "Oracle balance should be at least the collateral amount");
    }

    function test_getOracleBalanceForAsset_comp() public view {
        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(COMP_ONLY_USER, address(USDC));
        // User should have no USDC position (neither lending nor borrowing)
        assertEq(amountUsdc, 0, "User should have no USDC position");

        (uint256 amountComp,) = oracle.getOracleBalanceForAsset(COMP_ONLY_USER, REWARD_TOKEN);
        // User should have COMP rewards
        assertGt(amountComp, 0, "User should have COMP rewards");
    }

    function test_getOracleBalanceForAsset_only_comp_in_given_comet() public {
        deal(REWARD_TOKEN, COMP_ONLY_USER, 1 ether);

        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(COMP_ONLY_USER, address(USDC));
        // User should have no USDC position (neither lending nor borrowing)
        assertEq(amountUsdc, 0, "User should have no USDC position");

        (uint256 amountComp,) = oracle.getOracleBalanceForAsset(COMP_ONLY_USER, REWARD_TOKEN);
        // User should have COMP rewards (note: deal() gives user tokens, but oracle only reports protocol positions)
        // The balance should still reflect the unclaimed rewards from the protocol
        assertGt(amountComp, 0, "User should have COMP rewards from protocol");
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalance_aggregatesPositions() public view {
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(LEND_USER);

        // Should have at least USDC and COMP positions
        assertGe(assets.length, 2, "Should have multiple positions");
        assertEq(assets.length, amounts.length, "Arrays should match length");
    }

    function test_getOraclePositions_returnsCorrectPositions() public {
        // Use same fork and oracle as setUp so state is consistent
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle =
            new CompoundV3Comet(COMPOUND_REWARDS, USDCV3_COMET, REWARD_TOKEN, "Compound v3 USDC", address(balances));

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(LEND_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
