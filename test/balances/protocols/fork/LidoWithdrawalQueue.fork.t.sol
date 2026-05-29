// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {LidoWithdrawalQueueBalanceOracle} from "src/balances/protocols/LidoWithdrawalQueue.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title LidoWithdrawalQueueBalanceOracleForkTest
/// @notice Fork tests against Lido's WithdrawalQueueERC721 on mainnet.
/// @dev TEST_USER has one open (un-claimed, un-finalized) request id 125680 at FORK_BLOCK, with
///      `amountOfStETH = 2.67` (verified on-chain). The adapter denominates this in native ETH — the
///      asset Lido pays on claim — so it's reported as 2.67 ETH.
contract LidoWithdrawalQueueBalanceOracleForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    /// @dev ERC-7528 native-ETH sentinel — what Lido pays on claim and how the adapter denominates.
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 public constant FORK_BLOCK = 25_203_500;

    address public constant TEST_USER = 0x7170b89DD46aE7e59cD9357415763E7110E0bafD;
    uint256 public constant TEST_USER_EXPECTED_ETH = 2_670_000_000_000_000_000;

    string internal constant POSITION_DETAIL_FULL =
        "{\"protocol\":\"Lido\",\"product\":\"Staking\",\"name\":\"stETH Withdrawal Queue\",\"type\":\"Staking\"}";

    LidoWithdrawalQueueBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();

        // Register native ETH directly: the default fork harness probes decimals()/symbol() on each
        // asset, which foundry rejects for the codeless native sentinel ("contract does not exist").
        // registerAssetForTest is pure storage, so it sidesteps that with known metadata.
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");

        oracle = new LidoWithdrawalQueueBalanceOracle(
            WITHDRAWAL_QUEUE,
            NATIVE_ETH,
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

    // ---- Real FINALIZED position: exercises the getClaimableEther path against the live contract ----

    /// @dev At block 25_200_000, holder 0xF74B44… has exactly one request (id 125680→125186) that is
    ///      finalized AND un-claimed, with `amountOfStETH == getClaimableEther == 4.871…` ETH. This is
    ///      the only durable way to cover the finalized branch (findCheckpointHints + getClaimableEther)
    ///      against the real WithdrawalQueue — the holder used above is still pending.
    function test_getOracleBalanceForAsset_finalizedHolder_usesClaimableEther() public {
        address finalizedHolder = 0xF74B44b06Eda33803f04839E66737Cc49b8ad72d;
        uint256 expectedClaimableEth = 4_871_995_176_133_048_140;

        // Roll to a block where the request is finalized-but-unclaimed (keep the test-deployed
        // adapter + Balances harness alive across the roll).
        vm.makePersistent(address(oracle));
        vm.makePersistent(address(balances));
        vm.rollFork(25_200_000);

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(finalizedHolder, NATIVE_ETH);
        assertEq(amount, expectedClaimableEth, "Finalized request must be valued via getClaimableEther");
        assertFalse(isDebt);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(finalizedHolder, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, NATIVE_ETH);
        assertEq(positions[0].amount, expectedClaimableEth);
    }

    // ---- Real open position ----

    function test_getOracleBalanceForAsset_realHolder() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, NATIVE_ETH);
        assertEq(amount, TEST_USER_EXPECTED_ETH, "Should match amountOfStETH for the open request");
        assertFalse(isDebt);
    }

    function test_getOraclePositions_realHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, NATIVE_ETH);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].amount, TEST_USER_EXPECTED_ETH);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Lido");
        assertEq(positions[0].positionDetail, POSITION_DETAIL_FULL);
    }

    function test_getOracleBalances_realHolder() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(TEST_USER);
        assertEq(assets.length, 1);
        assertEq(assets[0], NATIVE_ETH);
        assertEq(amounts[0], TEST_USER_EXPECTED_ETH);
        assertFalse(isDebt[0]);
    }

    // ---- Empty / negative cases ----

    function test_getOracleBalanceForAsset_zeroAddress() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), NATIVE_ETH);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unknownHolder() public view {
        address eoa = address(uint160(uint256(keccak256("noQueueHolder"))));
        (uint256 amount,) = oracle.getOracleBalanceForAsset(eoa, NATIVE_ETH);
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
        assertEq(assets[0], NATIVE_ETH);
    }

    function test_immutableAddresses() public view {
        assertEq(address(oracle.WITHDRAWAL_QUEUE()), WITHDRAWAL_QUEUE);
        assertEq(oracle.UNDERLYING_TOKEN(), NATIVE_ETH);
    }
}
