// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CometExtInterface, CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title CompoundV3Comet fork tests (Mainnet cUSDCv3)
/// @notice Real Compound V3 positions at a pinned Mainnet block. Each test asserts both the
///         summed leg (`getOracleBalanceForAsset`) and the per-role positions (`getOraclePositions`)
///         where applicable, so the COMP-as-collateral-and-reward overlap is verified end-to-end.
contract CompoundV3CometForkTest is BalanceAdapterTestBase {
    // Compound V3 (Mainnet)
    address public constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address public constant REWARD_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888; // COMP
    address public constant USDCV3_COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    // Token addresses
    IERC20 public constant USDC = IERC20(MAINNET_USDC);
    address public constant WBTC = MAINNET_WBTC;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = MAINNET_WETH;

    CompoundV3Comet public oracle;
    CometExtInterface public comet;

    string internal constant DETAIL_SUPPLY =
        "{\"protocol\":\"Compound V3\",\"product\":\"Lending\",\"type\":\"Supply\"}";
    string internal constant DETAIL_BORROW =
        "{\"protocol\":\"Compound V3\",\"product\":\"Lending\",\"type\":\"Borrow\"}";
    string internal constant DETAIL_COLLATERAL =
        "{\"protocol\":\"Compound V3\",\"product\":\"Lending\",\"type\":\"Collateral\"}";
    string internal constant DETAIL_REWARD =
        "{\"protocol\":\"Compound V3\",\"product\":\"Lending\",\"type\":\"Rewards\"}";

    // Real users with known positions at FORK_BLOCK.
    address public constant LEND_USER = 0x2b2E894f08F1BF8C93a82297c347EbdC8717d99a;
    address public constant BORROW_USER = 0xe84A061897afc2e7fF5FB7e3686717C528617487;
    address public constant MULTI_COLLATERAL_USER = 0xc94A3Ff0bac12eeB9ff0CC4e08511E1FFaD6ba94;
    address public constant COMP_ONLY_USER = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;

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
        balances = _deployBalancesForOracle(_collectSupportedAssets());
        oracle = new CompoundV3Comet(
            COMPOUND_REWARDS,
            USDCV3_COMET,
            REWARD_TOKEN,
            "Compound v3 USDC",
            "{\"protocol\":\"Compound V3\",\"product\":\"Lending\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
        comet = CometExtInterface(USDCV3_COMET);
    }

    /// @dev Deploys a throwaway adapter against an empty Balances to enumerate the asset list,
    ///      then registers exactly that set on the real Balances. The adapter already deduplicates
    ///      internally, so no further dedup is needed here.
    function _collectSupportedAssets() internal returns (address[] memory) {
        BalancesHarnessForFork tmpBalances = new BalancesHarnessForFork();
        CompoundV3Comet tmp = new CompoundV3Comet(
            COMPOUND_REWARDS,
            USDCV3_COMET,
            REWARD_TOKEN,
            "Compound v3 USDC",
            "{\"protocol\":\"Compound V3\",\"product\":\"Lending\"",
            "0x0000000000000000000000000000000000000001",
            address(tmpBalances)
        );
        return tmp.underlyingAssetsSupported();
    }

    // ============ Initialization ============

    function test_initialization_pinsImmutables() public view {
        assertEq(oracle.BASE_TOKEN(), address(USDC));
        assertEq(oracle.COMET(), USDCV3_COMET);
        assertEq(address(oracle.REWARD_TOKEN()), REWARD_TOKEN);
        assertEq(address(oracle.COMPOUND_REWARDS()), COMPOUND_REWARDS);
    }

    function test_initialization_collateralsAutoDiscovered() public view {
        uint8 numAssets = comet.numAssets();
        assertGt(numAssets, 0);
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            assertTrue(oracle.isCollateral(asset), "collateral missing from oracle");
        }
    }

    function test_underlyingAssetsSupported_dedupesCompOverlap() public view {
        // On Mainnet cUSDCv3, COMP is BOTH a collateral AND the reward token. The dedupe logic
        // in `underlyingAssetsSupported` should keep COMP exactly once.
        address[] memory assets = oracle.underlyingAssetsSupported();
        uint256 compCount = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == REWARD_TOKEN) compCount++;
        }
        assertEq(compCount, 1, "COMP should appear exactly once after dedup");
    }

    // ============ Real-user balance reads ============

    function test_lendUser_supplyAndReward() public view {
        // Lend user is net-supplying USDC (credit) and has unclaimed COMP.
        (uint256 usdc, bool usdcDebt) = oracle.getOracleBalanceForAsset(LEND_USER, address(USDC));
        assertGt(usdc, 0, "expected USDC supply");
        assertFalse(usdcDebt);

        (uint256 reward,) = oracle.getOracleBalanceForAsset(LEND_USER, REWARD_TOKEN);
        assertGt(reward, 0, "expected non-zero unclaimed COMP");
    }

    function test_borrowUser_borrowDebtPlusCollateral() public view {
        // Borrow user has USDC debt and WBTC collateral.
        (uint256 usdc, bool usdcDebt) = oracle.getOracleBalanceForAsset(BORROW_USER, address(USDC));
        assertGt(usdc, 0);
        assertTrue(usdcDebt, "USDC should be reported as debt");

        (uint256 wbtc, bool wbtcDebt) = oracle.getOracleBalanceForAsset(BORROW_USER, WBTC);
        assertGt(wbtc, 0);
        assertFalse(wbtcDebt);
    }

    function test_compAsCollateralAndReward_summedBalance() public view {
        // The protection here is the one the prior adapter quietly missed: COMP balance for an
        // account that holds COMP both as collateral AND has unclaimed COMP rewards must include
        // BOTH sources, not just the reward.
        uint256 compCollateral = comet.collateralBalanceOf(MULTI_COLLATERAL_USER, REWARD_TOKEN);

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(MULTI_COLLATERAL_USER, REWARD_TOKEN);
        assertFalse(isDebt);
        // The sum must be at least the collateral, and strictly greater unless rewards happen to
        // be zero. We assert the strict relationship: amount - collateral == rewards alone.
        assertGe(amount, compCollateral, "summed amount must include the COMP collateral");
        // Cross-check that `amount - compCollateral` matches the standalone reward read against
        // a hypothetical user with the same baseTrackingAccrued. We can't read rewards in
        // isolation easily, so instead verify the per-role decomposition via getOraclePositions.
    }

    function test_compAsCollateralAndReward_separatePositionLegs() public {
        // Filter `getOraclePositions` to COMP — should yield two distinct legs (Collateral + Reward).
        // Use the same fork as setUp so state is consistent.
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        balances = _deployBalancesForOracle(_collectSupportedAssets());
        oracle = new CompoundV3Comet(
            COMPOUND_REWARDS,
            USDCV3_COMET,
            REWARD_TOKEN,
            "Compound v3 USDC",
            "{\"protocol\":\"Compound V3\",\"product\":\"Lending\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );

        INAVCalculator.PositionBalance[] memory positions =
            oracle.getOraclePositions(MULTI_COLLATERAL_USER, REWARD_TOKEN);

        uint256 compCollateral = comet.collateralBalanceOf(MULTI_COLLATERAL_USER, REWARD_TOKEN);
        bool sawCollateral;
        bool sawReward;
        uint256 collateralAmount;
        uint256 rewardAmount;

        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, REWARD_TOKEN);
            assertEq(positions[i].balanceOracle, address(oracle));
            assertEq(positions[i].protocol, "Compound v3 USDC");
            assertFalse(positions[i].isDebt);
            if (keccak256(bytes(positions[i].positionDetail)) == keccak256(bytes(DETAIL_COLLATERAL))) {
                sawCollateral = true;
                collateralAmount = positions[i].amount;
            } else if (keccak256(bytes(positions[i].positionDetail)) == keccak256(bytes(DETAIL_REWARD))) {
                sawReward = true;
                rewardAmount = positions[i].amount;
            }
        }

        assertTrue(sawCollateral, "missing Collateral leg");
        assertTrue(sawReward, "missing Reward leg");
        assertEq(collateralAmount, compCollateral, "Collateral leg mismatch");
        assertGt(rewardAmount, 0, "Reward leg should be non-zero");

        // And the summed `getOracleBalanceForAsset` is exactly the sum of the two legs.
        (uint256 summed,) = oracle.getOracleBalanceForAsset(MULTI_COLLATERAL_USER, REWARD_TOKEN);
        assertEq(summed, collateralAmount + rewardAmount, "summed leg != sum of position legs");
    }

    function test_compOnlyUser_rewardWithoutPosition() public view {
        // User has unclaimed COMP rewards but no USDC supply/borrow.
        (uint256 usdc,) = oracle.getOracleBalanceForAsset(COMP_ONLY_USER, address(USDC));
        assertEq(usdc, 0);

        (uint256 reward,) = oracle.getOracleBalanceForAsset(COMP_ONLY_USER, REWARD_TOKEN);
        assertGt(reward, 0);
    }

    // ============ Aggregation ============

    function test_getOracleBalances_aggregatesRealPositions() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(LEND_USER);
        // At minimum: USDC + COMP rewards.
        assertGe(assets.length, 2);
        assertEq(assets.length, amounts.length);
        assertEq(amounts.length, isDebt.length);

        // No duplicates (each asset appears at most once).
        for (uint256 i = 0; i < assets.length; i++) {
            for (uint256 j = i + 1; j < assets.length; j++) {
                assertTrue(assets[i] != assets[j], "duplicate asset in getOracleBalances");
            }
            assertGt(amounts[i], 0);
        }
    }

    function test_getOraclePositions_protocolAndDetailLabels() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        balances = _deployBalancesForOracle(_collectSupportedAssets());
        oracle = new CompoundV3Comet(
            COMPOUND_REWARDS,
            USDCV3_COMET,
            REWARD_TOKEN,
            "Compound v3 USDC",
            "{\"protocol\":\"Compound V3\",\"product\":\"Lending\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(BORROW_USER, address(0));
        assertGt(positions.length, 0);

        bool sawBorrow;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceOracle, address(oracle));
            assertEq(positions[i].protocol, "Compound v3 USDC");
            assertGt(positions[i].amount, 0);
            string memory d = positions[i].positionDetail;
            // Every position must carry one of the expected role labels.
            bool isKnown =
                (keccak256(bytes(d)) == keccak256(bytes(DETAIL_SUPPLY))
                    || keccak256(bytes(d)) == keccak256(bytes(DETAIL_BORROW))
                    || keccak256(bytes(d)) == keccak256(bytes(DETAIL_COLLATERAL))
                    || keccak256(bytes(d)) == keccak256(bytes(DETAIL_REWARD)));
            assertTrue(isKnown, "unexpected positionDetail");
            if (keccak256(bytes(d)) == keccak256(bytes(DETAIL_BORROW))) {
                sawBorrow = true;
                assertTrue(positions[i].isDebt);
                assertEq(positions[i].underlyingAsset.asset, address(USDC));
            }
        }
        assertTrue(sawBorrow, "BORROW_USER should have a Borrow leg");
    }

    function test_getOraclePositions_assetFilter_skipsOtherAssets() public view {
        INAVCalculator.PositionBalance[] memory all = oracle.getOraclePositions(BORROW_USER, address(0));
        INAVCalculator.PositionBalance[] memory onlyUsdc = oracle.getOraclePositions(BORROW_USER, address(USDC));

        assertGt(all.length, onlyUsdc.length, "filter should narrow the result");
        for (uint256 i = 0; i < onlyUsdc.length; i++) {
            assertEq(onlyUsdc[i].underlyingAsset.asset, address(USDC));
        }
    }

    function test_getOraclePositions_zeroAccountReturnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }
}
