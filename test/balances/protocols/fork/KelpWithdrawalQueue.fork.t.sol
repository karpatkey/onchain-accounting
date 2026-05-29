// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {KelpWithdrawalQueueBalanceOracle} from "src/balances/protocols/KelpWithdrawalQueue.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title KelpWithdrawalQueueBalanceOracleForkTest
/// @notice Fork tests against Kelp DAO's rsETH exit queue (LRTWithdrawalManager) on mainnet.
/// @dev Reproduces the exact incident from Slack thread C06TV792AMV: account 0x99b9F5… unstaked
///      150 rsETH on 2026-05-14 (tx 0xa39b5a…, block 25094939) into the queue, asking for stETH.
///      While the request sat open, wallet/receipt-token oracles lost track of the value; it
///      reappeared once claimed. At FORK_BLOCK (one block after the unstake) the account has one
///      open stETH request for 160.441554282426606450 stETH; by POST_CLAIM_BLOCK it is claimed and
///      the position has vanished — both states are asserted below.
contract KelpWithdrawalQueueBalanceOracleForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAWAL_MANAGER = 0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16;
    address public constant MAINNET_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    uint256 public constant FORK_BLOCK = 25_094_940; // request open
    uint256 public constant POST_CLAIM_BLOCK = 25_150_000; // request claimed

    address public constant TEST_USER = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b;
    uint256 public constant TEST_USER_EXPECTED_STETH = 160_441_554_282_426_606_450;

    string internal constant POSITION_DETAIL_FULL =
        "{\"protocol\":\"Kelp\",\"product\":\"Withdrawal Queue\",\"name\":\"rsETH\",\"type\":\"Staking\"}";

    KelpWithdrawalQueueBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();

        address[] memory assets = new address[](1);
        assets[0] = MAINNET_STETH;
        balances = _deployBalancesForOracle(assets);

        oracle = new KelpWithdrawalQueueBalanceOracle(
            WITHDRAWAL_MANAGER,
            "Kelp",
            "{\"protocol\":\"Kelp\",\"product\":\"Withdrawal Queue\",\"name\":\"rsETH\"",
            "0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16",
            address(balances)
        );
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- Real open position ----

    function test_getOracleBalanceForAsset_realHolder() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, MAINNET_STETH);
        assertEq(amount, TEST_USER_EXPECTED_STETH, "Should match expectedAssetAmount for the open request");
        assertFalse(isDebt);
    }

    function test_getOraclePositions_realHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, MAINNET_STETH);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].amount, TEST_USER_EXPECTED_STETH);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Kelp");
        assertEq(positions[0].positionDetail, POSITION_DETAIL_FULL);
    }

    function test_getOracleBalances_realHolder() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(TEST_USER);
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_STETH);
        assertEq(amounts[0], TEST_USER_EXPECTED_STETH);
        assertFalse(isDebt[0]);
    }

    // ---- Recovery: position vanishes once the request is claimed ----

    function test_positionClearedAfterClaim() public {
        // Keep the test-deployed adapter + Balances harness alive across the fork roll.
        vm.makePersistent(address(oracle));
        vm.makePersistent(address(balances));
        vm.rollFork(POST_CLAIM_BLOCK);

        (uint256 amount,) = oracle.getOracleBalanceForAsset(TEST_USER, MAINNET_STETH);
        assertEq(amount, 0, "Claimed request must report zero owed");

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));
        assertEq(positions.length, 0, "No open requests after claim");
    }

    // ---- Empty / negative cases ----

    function test_getOracleBalanceForAsset_zeroAddress() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), MAINNET_STETH);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unknownHolder() public view {
        address eoa = address(uint160(uint256(keccak256("noQueueHolder"))));
        (uint256 amount,) = oracle.getOracleBalanceForAsset(eoa, MAINNET_STETH);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(TEST_USER, MAINNET_USDC);
        assertEq(amount, 0);
    }

    function test_getOraclePositions_assetFilterMismatch() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, MAINNET_USDC);
        assertEq(positions.length, 0);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        // Kelp's LRTConfig lists stETH, ETHx and native ETH at this block.
        assertEq(assets.length, 3);
        assertEq(assets[0], MAINNET_STETH);
    }

    function test_immutableAddresses() public view {
        assertEq(address(oracle.WITHDRAWAL_MANAGER()), WITHDRAWAL_MANAGER);
    }
}
