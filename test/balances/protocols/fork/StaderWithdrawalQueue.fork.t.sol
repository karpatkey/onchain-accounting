// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {StaderWithdrawalQueueBalanceOracle} from "src/balances/protocols/StaderWithdrawalQueue.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title StaderWithdrawalQueueBalanceOracleForkTest
/// @notice Fork tests against Stader's UserWithdrawalManager on mainnet.
/// @dev TEST_USER below is a real account with one open (pre-finalization) request id 8056 at FORK_BLOCK,
///      with `ethExpected = 37.440331321957283515` ETH and `ethFinalized = 0` (so the adapter reports ethExpected).
contract StaderWithdrawalQueueBalanceOracleForkTest is BalanceAdapterTestBase {
    address public constant USER_WITHDRAWAL_MANAGER = 0x9F0491B32DBce587c50c4C43AB303b06478193A7;

    uint256 public constant FORK_BLOCK = 25_015_000;

    address public constant TEST_USER = 0x5066bc626C292d02ACFef8d002905877148Cb37A;
    uint256 public constant TEST_USER_EXPECTED_ETH = 37_440_331_321_957_283_515;

    StaderWithdrawalQueueBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForOracle(MAINNET_WETH);
        oracle = new StaderWithdrawalQueueBalanceOracle(USER_WITHDRAWAL_MANAGER, MAINNET_WETH, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- Real position ----

    function test_getOracleBalanceForAsset_realHolder() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, MAINNET_WETH);
        assertEq(amount, TEST_USER_EXPECTED_ETH, "Should match ethExpected for the open request");
        assertFalse(isDebt);
    }

    function test_getOraclePositions_realHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_WETH);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].amount, TEST_USER_EXPECTED_ETH);
        assertFalse(positions[0].isDebt);
    }

    function test_getOracleBalances_realHolder() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(TEST_USER);
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_WETH);
        assertEq(amounts[0], TEST_USER_EXPECTED_ETH);
        assertFalse(isDebt[0]);
    }

    // ---- Empty / negative cases ----

    function test_getOracleBalanceForAsset_zeroAddress() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), MAINNET_WETH);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unknownHolder() public view {
        address eoa = address(uint160(uint256(keccak256("noQueueHolder"))));
        (uint256 amount,) = oracle.getOracleBalanceForAsset(eoa, MAINNET_WETH);
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
        assertEq(assets[0], MAINNET_WETH);
    }

    function test_immutableAddresses() public view {
        assertEq(address(oracle.USER_WITHDRAWAL_MANAGER()), USER_WITHDRAWAL_MANAGER);
        assertEq(oracle.UNDERLYING_TOKEN(), MAINNET_WETH);
    }
}
