// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CometExtInterface, CompoundV3CometWithMultiplier} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface CometRewardsAux {
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

/// @title CompoundV3CometWithMultiplierBalanceOracleForkTest
/// @notice Fork tests for CompoundV3CometWithMultiplierBalanceOracle using real Arbitrum contracts
/// @dev Tests adapter behavior with real Compound V3 protocol contracts and positions
contract CompoundV3CometWithMultiplierBalanceOracleForkTest is BalanceAdapterForkTestBase {
    // Compound V3 contract addresses (Arbitrum)
    address public constant COMPOUND_REWARDS = 0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae;
    address public constant REWARD_TOKEN = 0x354A6dA3fcde098F8389cad84b0182725c6C91dE;
    IERC20 public constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 public constant USDCV3 = IERC20(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    IERC20 public constant USDTV3 = IERC20(0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07);
    
    // Token addresses (Arbitrum)
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    
    // Oracle instance
    CompoundV3CometWithMultiplier public oracle;
    CometExtInterface public comet;
    
    // Real user addresses with positions in Compound V3 (Arbitrum)
    address public constant LEND_BORROW_USER = 0x30b4B07f3B2dA829Af6Fc459b58906a16a5f979e;
    address public constant MULTI_COLLATERAL_USER = 0xFE99cC4664A939f826DBeb545C1AAd4c89ee737a;
    
    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }
    
    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        // Using latest block - all contracts should exist
    }
    
    function _setupOracle() internal {
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle = new CompoundV3CometWithMultiplier(
            COMPOUND_REWARDS,
            address(USDCV3),
            REWARD_TOKEN,
            "Compound v3",
            "USDC Comet",
            address(balances)
        );
        comet = CometExtInterface(address(USDCV3));
    }
    
    function _getSupportedAssets() internal returns (address[] memory) {
        // Create temporary oracle to get supported assets
        // Use a minimal mock balances for this purpose
        address mockBalances = address(0x1111111111111111111111111111111111111111);
        CompoundV3CometWithMultiplier tempOracle = new CompoundV3CometWithMultiplier(
            COMPOUND_REWARDS, address(USDCV3), REWARD_TOKEN, "Compound v3", "USDC Comet", mockBalances
        );
        address[] memory assets = tempOracle.underlyingAssetsSupported();
        // Also add reward token
        address[] memory allAssets = new address[](assets.length + 1);
        for (uint256 i = 0; i < assets.length; i++) {
            allAssets[i] = assets[i];
        }
        allAssets[assets.length] = REWARD_TOKEN;
        return allAssets;
    }
    
    // ============================================
    // Initialization Tests
    // ============================================
    
    function test_initialization() public view {
        assertEq(oracle.BASE_TOKEN(), address(USDC));
        assertEq(address(oracle.REWARD_TOKEN()), REWARD_TOKEN);
        assertEq(oracle.COMET(), address(USDCV3));
        
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
        int256 balanceWeth = oracle.getOracleBalanceForAsset(LEND_BORROW_USER, WETH);
        assertGt(balanceWeth, 0, "User should have WETH collateral position");
    }
    
    function test_getOracleBalanceForAsset_borrow() public view {
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(LEND_BORROW_USER, address(USDC));
        assertLt(balanceUsdc, 0, "User should have USDC borrow position (negative balance)");
    }
    
    function test_getOracleBalanceForAsset_rewardToken() public view {
        int256 balanceReward = oracle.getOracleBalanceForAsset(LEND_BORROW_USER, REWARD_TOKEN);
        assertGt(balanceReward, 0, "User should have reward token position");
    }
    
    function test_getOracleBalanceForAsset_multiCollaterals() public {
        // Deploy balances for USDT comet
        address mockBalances = address(0x1111111111111111111111111111111111111111);
        CompoundV3CometWithMultiplier tempOracle = new CompoundV3CometWithMultiplier(
            COMPOUND_REWARDS, address(USDTV3), REWARD_TOKEN, "Compound v3", "USDC Comet", mockBalances
        );
        address[] memory assets = tempOracle.underlyingAssetsSupported();
        address[] memory allAssets = new address[](assets.length + 1);
        for (uint256 i = 0; i < assets.length; i++) {
            allAssets[i] = assets[i];
        }
        allAssets[assets.length] = REWARD_TOKEN;
        balances = _deployBalancesForOracle(allAssets);
        
        oracle = new CompoundV3CometWithMultiplier(
            COMPOUND_REWARDS, address(USDTV3), REWARD_TOKEN, "Compound v3", "USDC Comet", address(balances)
        );
        comet = CometExtInterface(address(USDTV3));
        
        uint8 numAssets = comet.numAssets();
        bool hasPosition = false;
        for (uint8 i = 0; i < numAssets; i++) {
            (, address asset,,,,,,) = comet.getAssetInfo(i);
            int256 balance = oracle.getOracleBalanceForAsset(MULTI_COLLATERAL_USER, asset);
            if (balance != 0) {
                hasPosition = true;
                assertGt(balance, 0, "User should have positive collateral position");
            }
        }
        assertTrue(hasPosition, "User should have at least one collateral position");
    }
    
    // ============================================
    // Position Aggregation Tests
    // ============================================
    
    function test_getOracleBalance_aggregatesPositions() public view {
        (address[] memory assets, int256[] memory balances) = 
            oracle.getOracleBalance(LEND_BORROW_USER);
        
        // Should have at least one position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, balances.length, "Arrays should match length");
    }
    
    function test_getOraclePositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(LEND_BORROW_USER, address(0));
        
        assertGe(positions.length, 1, "Should have at least one position");
        
        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
