// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {StakeWiseV3VaultBalanceOracle, IStakeWiseVault} from "src/balances/protocols/StakeWiseV3Vault.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IEthGenesisVault {
    function burnOsToken(uint128 osTokenShares) external returns (uint256 assets);
    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external;
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket);
    function osTokenPositions(address user) external view returns (uint128 shares);
    function getShares(address account) external view returns (uint256);
}

/// @title StakeWiseV3VaultBalanceOracleForkTest
/// @notice Fork tests for StakeWiseV3VaultBalanceOracle using real Gnosis chain contracts
/// @dev Tests adapter behavior with real StakeWise V3 vault contracts and positions
contract StakeWiseV3VaultBalanceOracleForkTest is BalanceAdapterForkTestBase {
    // Gnosis chain addresses
    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public constant OS_GNO = 0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0;
    address public constant STAKE_WISE_VAULT = 0x4b4406Ed8659D03423490D8b62a1639206dA0A7a;
    
    // Oracle instance
    StakeWiseV3VaultBalanceOracle public oracle;
    IEthGenesisVault public vaultContract;
    
    // Real user addresses with positions in StakeWise V3
    address public constant TEST_USER = 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f;
    address public constant TEST_USER2 = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;
    
    // Fork blocks
    uint256 public constant FORK_BLOCK_1 = 38_449_644;
    uint256 public constant FORK_BLOCK_2 = 35_261_999;
    uint256 public constant FORK_BLOCK_3 = 38_916_922;
    
    function setUp() public override {
        // Note: Fork setup is done per-test since different tests use different blocks
        super.setUp();
    }
    
    // ============================================
    // Real Position Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_gnosis_osGNO_TEST_USER1() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        vaultContract = IEthGenesisVault(STAKE_WISE_VAULT);
        
        int256 balance = oracle.getOracleBalanceForAsset(TEST_USER, GNO);
        assertGt(balance, 0, "User should have GNO position");
    }
    
    function test_getOracleBalanceForAsset_gnosis_osGNO_TEST_USER2() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_2);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        vaultContract = IEthGenesisVault(STAKE_WISE_VAULT);
        
        int256 balance = oracle.getOracleBalanceForAsset(TEST_USER2, GNO);
        assertGt(balance, 0, "User should have GNO position");
    }
    
    function test_getOracleBalanceForAsset_gnosis_staked() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_2);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        vaultContract = IEthGenesisVault(STAKE_WISE_VAULT);
        
        int256 balance = oracle.getOracleBalanceForAsset(TEST_USER2, GNO);
        
        uint256 balanceBefore = IERC20(GNO).balanceOf(TEST_USER2);
        
        vm.startPrank(TEST_USER2);
        uint256 shares = vaultContract.getShares(TEST_USER2);
        assertGt(shares, 0, "User should have shares");
        
        // Enter exit queue - this should reduce the user's balance in the oracle
        uint256 positionTicket = vaultContract.enterExitQueue(shares, TEST_USER2);
        assertGt(positionTicket, 0, "Position ticket should be valid");
        
        vm.stopPrank();
        
        // After entering exit queue, the balance should be 0 (shares are in exit queue)
        // Note: We can't test claimExitedAssets in a fork because it requires actual
        // validator exits from the beacon chain, which can't be simulated
        int256 newBalance = oracle.getOracleBalanceForAsset(TEST_USER2, GNO);
        assertEq(newBalance, 0, "Balance should be 0 after entering exit queue");
    }
    
    function test_getOracleBalanceForAsset_gnosis_osGNO_stake_and_osToken() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_2);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        vaultContract = IEthGenesisVault(STAKE_WISE_VAULT);
        
        int256 initialBalance = oracle.getOracleBalanceForAsset(TEST_USER, GNO);
        
        uint256 gnoBalanceBefore = IERC20(GNO).balanceOf(TEST_USER);
        uint256 osTokenShares = vaultContract.osTokenPositions(TEST_USER);
        uint256 osTokenGnoValue = vaultContract.convertToAssets(osTokenShares);
        
        vm.startPrank(TEST_USER);
        
        // osTokens are effectively a loan against the staked GNO
        // Need to burn osTokens first to maintain LTV ratio
        if (osTokenShares > 0) {
            // Deal exact amount of osGNO tokens to test user so he can burn its whole position
            deal(OS_GNO, TEST_USER, osTokenShares);
            vaultContract.burnOsToken(uint128(osTokenShares));
        }
        
        int256 afterBurnBalance = oracle.getOracleBalanceForAsset(TEST_USER, GNO);
        
        // After burning osTokens, balance should increase by the osToken value
        assertEq(initialBalance, afterBurnBalance - int256(osTokenGnoValue));
        
        // Now that we don't have any osTokens, we can enter exit queue
        uint256 positionTicket = vaultContract.enterExitQueue(vaultContract.getShares(TEST_USER), TEST_USER);
        assertGt(positionTicket, 0, "Position ticket should be valid");
        
        vm.stopPrank();
        
        // After entering exit queue, balance should be 0
        // Note: We can't test claimExitedAssets in a fork because it requires actual
        // validator exits from the beacon chain, which can't be simulated
        int256 currentBalance = oracle.getOracleBalanceForAsset(TEST_USER, GNO);
        assertEq(currentBalance, 0, "Balance should be 0 after entering exit queue");
    }
    
    function test_getOracleBalanceForAsset_gnosis_osGNO_holds_osToken_butDidNotLendTheTokens() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_3);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        
        address user = 0x564E604edA8c878021126C06084a4dA4E1A960Cb;
        int256 balance = oracle.getOracleBalanceForAsset(user, GNO);
        
        uint256 balanceOsGNO = IERC20(OS_GNO).balanceOf(user);
        
        assertEq(balance, 0);
        assertEq(balanceOsGNO, 392_839_159_609_003_939_803);
    }
    
    // ============================================
    // Position Aggregation Tests
    // ============================================
    
    function test_getOracleBalance_aggregatesPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        
        (address[] memory assets, int256[] memory balances) = 
            oracle.getOracleBalance(TEST_USER);
        
        // Should have at least GNO position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, balances.length, "Arrays should match length");
    }
    
    function test_getOraclePositions_returnsCorrectPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("gnosis-mainnet"), FORK_BLOCK_1);
        
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3VaultBalanceOracle(
            GNO,
            STAKE_WISE_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
        
        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(TEST_USER, address(0));
        
        assertGe(positions.length, 1, "Should have at least one position");
        
        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
