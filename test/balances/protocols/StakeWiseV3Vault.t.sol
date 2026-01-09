// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test, console2} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {StakeWiseV3VaultBalanceOracle, IStakeWiseVault} from "src/balances/protocols/StakeWiseV3Vault.sol";
import "src/errors.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract StakewiseVaultTest is TestEnvConfigurator {
    address public GNO = address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb);
    address public osGNO = address(0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0);
    address public vault = address(0x4b4406Ed8659D03423490D8b62a1639206dA0A7a);
    IBalanceOracleCustom.PositionMetadata positionMetadata = IBalanceOracleCustom.PositionMetadata({
        protocol: "Stakewise v3", position: "Some vault", positionType: "Staked"
    });

    StakeWiseV3VaultBalanceOracle public oracle;
    IEthGenesisVault public vaultContract;

    address constant TEST_USER = 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f;
    address constant TEST_USER2 = 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669;

    //
    // Setup
    //
    function setUp() public {
        uint256 fork = vm.createFork(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
    }

    //
    // Tests
    //
    function test_constructor_reverts_on_zero_address() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3VaultBalanceOracle(address(0), address(0), positionMetadata);
    }

    function test_balanceOf_reverts_on_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        vm.expectRevert(InvalidArguments.selector);
        oracle.balanceOf(invalidToken, 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f);
    }

    function test_underlyingAssetsSupported() public {
        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], GNO);
    }

    function test_gnosis_osGNO_TEST_USER1() public {
        vm.rollFork(38_449_644);

        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        vaultContract = IEthGenesisVault(vault);
        int256 balance = oracle.balanceOf(GNO, 0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f);
        assertEq(balance, 5_843_147_630_175_728_415_438);
    }

    function test_gnosis_osGNO_TEST_USER2() public {
        vm.rollFork(35_261_999);

        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        vaultContract = IEthGenesisVault(vault);
        int256 balance = oracle.balanceOf(GNO, 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669);
        assertEq(balance, 1_294_742_347_492_745_268_851);
    }

    function test_gnosis_staked() public {
        vm.rollFork(35_261_999);

        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        vaultContract = IEthGenesisVault(vault);

        int256 balance = oracle.balanceOf(GNO, TEST_USER2);

        uint256 balanceBefore = IERC20(GNO).balanceOf(TEST_USER2);

        vm.startPrank(TEST_USER2);
        uint256 shares = vaultContract.getShares(TEST_USER2);

        uint256 positionTicket = vaultContract.enterExitQueue(shares, TEST_USER2);

        uint256 exitQueueTimestamp = block.timestamp;
        vm.warp(block.timestamp + 365 days);

        vaultContract.claimExitedAssets(positionTicket, exitQueueTimestamp, 0);

        vm.stopPrank();

        balance = oracle.balanceOf(GNO, 0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669);

        uint256 balanceAfter = IERC20(GNO).balanceOf(TEST_USER2);

        assertEq(balance, 0);
        assertEq(balanceAfter - balanceBefore, 1_294_742_347_492_745_268_851);
    }

    function test_gnosis_osGNO_stake_and_osToken() public {
        vm.rollFork(35_261_999);

        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        vaultContract = IEthGenesisVault(vault);

        int256 initialBalance = oracle.balanceOf(GNO, TEST_USER);
        uint256 gnoBalanceBefore = IERC20(GNO).balanceOf(TEST_USER);
        uint256 osTokenShares = vaultContract.osTokenPositions(TEST_USER);
        uint256 osTokenGnoValue = vaultContract.convertToAssets(osTokenShares);

        vm.startPrank(TEST_USER);

        // osTokens are effectively a loan against the staked GNO
        // Need to burn osTokens first to maintain LTV ratio
        if (osTokenShares > 0) {
            // Deal exact amount of osGNO tokens to test user so he can burn its whole position
            deal(osGNO, TEST_USER, osTokenShares);
            vaultContract.burnOsToken(uint128(osTokenShares));
        }

        int256 afterBurnBalance = oracle.balanceOf(GNO, TEST_USER);

        // Now that we don't have any osTokens, we can  unstake and exit
        uint256 positionTicket = vaultContract.enterExitQueue(vaultContract.getShares(TEST_USER), TEST_USER);
        uint256 exitQueueTimestamp = block.timestamp;

        // skip some amount of time for exit to be processed
        vm.warp(block.timestamp + 14 days);

        vaultContract.claimExitedAssets(positionTicket, exitQueueTimestamp, 0);

        vm.stopPrank();

        // unStaked gno value - gno value of burned OSToken position
        uint256 gnoBalanceAfter = IERC20(GNO).balanceOf(TEST_USER);

        int256 currentBalance = oracle.balanceOf(GNO, TEST_USER);

        assertEq(initialBalance, afterBurnBalance - int256(osTokenGnoValue));
        assertEq(initialBalance, int256(gnoBalanceAfter - osTokenGnoValue - gnoBalanceBefore));
        assertEq(currentBalance, 0);
    }

    function test_gnosis_osGNO_holds_osToken_butDidNotLendTheTokens() public {
        vm.rollFork(38_916_922);
        oracle = new StakeWiseV3VaultBalanceOracle(GNO, vault, positionMetadata);
        int256 balance = oracle.balanceOf(GNO, 0x564E604edA8c878021126C06084a4dA4E1A960Cb);

        uint256 balanceOsGNO = IERC20(osGNO).balanceOf(0x564E604edA8c878021126C06084a4dA4E1A960Cb);

        assertEq(balance, 0);
        assertEq(balanceOsGNO, 392_839_159_609_003_939_803);
    }
}

interface IEthGenesisVault {
    function burnOsToken(uint128 osTokenShares) external returns (uint256 assets);
    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external;
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket);
    function osTokenPositions(address user) external view returns (uint128 shares);
    function getShares(address account) external view returns (uint256);
}
