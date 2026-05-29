// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {LidoWithdrawalQueueBalanceOracle} from "src/balances/protocols/LidoWithdrawalQueue.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title LidoWithdrawalQueueBalanceOracleForkTest
/// @notice Fork tests against Lido's WithdrawalQueueERC721 on mainnet.
/// @dev TEST_USER has one open (un-claimed, un-finalized) request id 125680 at FORK_BLOCK, with
///      `amountOfStETH = 2.67` stETH (verified on-chain).
contract LidoWithdrawalQueueBalanceOracleForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address public constant MAINNET_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    uint256 public constant FORK_BLOCK = 25_203_500;

    address public constant TEST_USER = 0x7170b89DD46aE7e59cD9357415763E7110E0bafD;
    uint256 public constant TEST_USER_EXPECTED_STETH = 2_670_000_000_000_000_000;

    string internal constant POSITION_DETAIL_FULL =
        "{\"protocol\":\"Lido\",\"product\":\"Staking\",\"name\":\"stETH Withdrawal Queue\",\"type\":\"Staking\"}";

    LidoWithdrawalQueueBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();

        address[] memory assets = new address[](1);
        assets[0] = MAINNET_STETH;
        balances = _deployBalancesForOracle(assets);

        oracle = new LidoWithdrawalQueueBalanceOracle(
            WITHDRAWAL_QUEUE,
            MAINNET_STETH,
            "Lido",
            "{\"protocol\":\"Lido\",\"product\":\"Staking\",\"name\":\"stETH Withdrawal Queue\"",
            "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
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
        assertEq(amount, TEST_USER_EXPECTED_STETH, "Should match amountOfStETH for the open request");
        assertFalse(isDebt);
    }

    function test_getOraclePositions_realHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, MAINNET_STETH);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].amount, TEST_USER_EXPECTED_STETH);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Lido");
        assertEq(positions[0].positionDetail, POSITION_DETAIL_FULL);
    }

    function test_getOracleBalances_realHolder() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(TEST_USER);
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_STETH);
        assertEq(amounts[0], TEST_USER_EXPECTED_STETH);
        assertFalse(isDebt[0]);
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
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_STETH);
    }

    function test_immutableAddresses() public view {
        assertEq(address(oracle.WITHDRAWAL_QUEUE()), WITHDRAWAL_QUEUE);
        assertEq(oracle.UNDERLYING_TOKEN(), MAINNET_STETH);
    }
}
