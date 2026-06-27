// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {KelpWithdrawalQueueBalanceAdapter} from "src/balances/BalanceAdapters/KelpWithdrawalQueueBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title KelpWithdrawalQueueBalanceAdapterForkTest
/// @notice Fork tests against Kelp DAO's rsETH exit queue (LRTWithdrawalManager) on mainnet.
/// @dev Reproduces the exact incident from Slack thread C06TV792AMV: account 0x99b9F5… unstaked
///      150 rsETH on 2026-05-14 (tx 0xa39b5a…, block 25094939) into the queue, asking for stETH.
///      While the request sat open, wallet/receipt-token oracles lost track of the value; it
///      reappeared once claimed. At FORK_BLOCK (one block after the unstake) the account has one
///      open stETH request for 160.441554282426606450 stETH; by POST_CLAIM_BLOCK it is claimed and
///      the position has vanished — both states are asserted below.
contract KelpWithdrawalQueueBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant WITHDRAWAL_MANAGER = 0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16;
    address public constant MAINNET_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    uint256 public constant FORK_BLOCK = 25_094_940; // request open
    uint256 public constant POST_CLAIM_BLOCK = 25_150_000; // request claimed

    address public constant TEST_USER = 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b;
    uint256 public constant TEST_USER_EXPECTED_STETH = 160_441_554_282_426_606_450;

    string internal constant POSITION_DETAIL_FULL =
        "{\"protocol\":\"Kelp\",\"product\":\"Staking\",\"name\":\"rsETH Withdrawal Queue\",\"type\":\"Staking\"}";

    KelpWithdrawalQueueBalanceAdapter public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();

        address[] memory assets = new address[](1);
        assets[0] = MAINNET_STETH;
        balances = _deployBalancesForAdapter(assets);

        oracle = new KelpWithdrawalQueueBalanceAdapter(WITHDRAWAL_MANAGER, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- Real open position ----

    function test_getAdapterBalanceForAsset_realHolder() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(TEST_USER, MAINNET_STETH);
        assertEq(amount, TEST_USER_EXPECTED_STETH, "Should match expectedAssetAmount for the open request");
        assertFalse(isDebt);
    }

    function test_getAdapterPositions_realHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(TEST_USER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_STETH);
        assertEq(positions[0].balanceAdapter, address(oracle));
        assertEq(positions[0].amount, TEST_USER_EXPECTED_STETH);
        assertFalse(positions[0].isDebt);
    }

    function test_getAdapterBalances_realHolder() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getAdapterBalances(TEST_USER);
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

        (uint256 amount,) = oracle.getAdapterBalanceForAsset(TEST_USER, MAINNET_STETH);
        assertEq(amount, 0, "Claimed request must report zero owed");

        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(TEST_USER, address(0));
        assertEq(positions.length, 0, "No open requests after claim");
    }

    // ---- Empty / negative cases ----

    function test_getAdapterBalanceForAsset_zeroAddress() public view {
        (uint256 amount,) = oracle.getAdapterBalanceForAsset(address(0), MAINNET_STETH);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unknownHolder() public view {
        address eoa = address(uint160(uint256(keccak256("noQueueHolder"))));
        (uint256 amount,) = oracle.getAdapterBalanceForAsset(eoa, MAINNET_STETH);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getAdapterBalanceForAsset(TEST_USER, MAINNET_USDC);
        assertEq(amount, 0);
    }

    function test_getAdapterPositions_assetFilterMismatch() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(TEST_USER, MAINNET_USDC);
        assertEq(positions.length, 0);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceAdapter).interfaceId));
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

/// @title KelpWithdrawalQueueBalanceAdapterForkTest_Fresh
/// @notice Fresh multi-asset, multi-request pin at the verification block (augments the original suite above;
///         does not replace it).
/// @dev Captured 2026-06-16 at block 25_331_379 — see `script/development/test/kelp/README.md`. The single
///      holder `0x13833b44…` exercises every gap the original (stETH-only, single-request) suite left:
///      - **stETH leg** — TWO open requests (nonces 7177 + 7203) summed: 322.038966142406605154 +
///        332.890371974143452160 = 654.929338116550057314 stETH (real on-chain multi-request summing).
///      - **native-ETH leg** — ONE open request (nonce 5937) = 0.010734990037748145 ETH (the native-ETH
///        payout branch; ETH is registered via the sentinel like Lido).
///      So `getAdapterPositions` emits TWO legs from one oracle — the multi-asset path, previously mock-only.
///      Kelp also supports ETHx, but this holder has no ETHx request and ETHx is not registered on the dev
///      NAV (custom feed) — the unit test covers the registered-vs-unregistered drop. Requests can be claimed
///      by the owner at any time after this block; the pin keeps them reproducible.
contract KelpWithdrawalQueueBalanceAdapterForkTest_Fresh is BalanceAdapterTestBase {
    address public constant WITHDRAWAL_MANAGER = 0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16;
    address public constant MAINNET_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    /// @dev ERC-7528 native-ETH sentinel — Kelp can pay out native ETH; the adapter denominates it here.
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 public constant FORK_BLOCK = 25_331_379;

    address public constant HOLDER = 0x13833b44341288dF27cc85e3eFDA8CD3830a4d35;
    /// @dev stETH leg = sum of two open requests (nonces 7177 + 7203).
    uint256 public constant STETH_REQ_7177 = 322_038_966_142_406_605_154;
    uint256 public constant STETH_REQ_7203 = 332_890_371_974_143_452_160;
    uint256 public constant STETH_EXPECTED = STETH_REQ_7177 + STETH_REQ_7203;
    /// @dev native-ETH leg = one open request (nonce 5937).
    uint256 public constant NETH_EXPECTED = 10_734_990_037_748_145;

    KelpWithdrawalQueueBalanceAdapter public oracle;

    function setUp() public override {
        // super.setUp() already invokes _setupFork() (overridden below) via virtual dispatch — no second call.
        super.setUp();

        // Register stETH + native ETH directly: the default fork harness probes decimals()/symbol() on each
        // asset, which foundry rejects for the codeless native sentinel. registerAssetForTest is pure storage.
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(MAINNET_STETH, 18, "stETH");
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        // ETHx deliberately NOT registered — mirrors the dev NAV (custom feed) and proves the drop path.

        oracle = new KelpWithdrawalQueueBalanceAdapter(WITHDRAWAL_MANAGER, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- Per-asset balances ----

    function test_stETH_sumsTwoRequests() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(HOLDER, MAINNET_STETH);
        assertEq(amount, STETH_EXPECTED, "stETH leg = sum of the two open requests");
        assertFalse(isDebt);
    }

    function test_nativeETH_singleRequest() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, NETH_EXPECTED, "native-ETH leg = single open request");
        assertFalse(isDebt);
    }

    // ---- Multi-asset getAdapterPositions: TWO legs from one oracle ----

    function test_getAdapterPositions_twoLegs() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(HOLDER, address(0));
        assertEq(positions.length, 2, "stETH + native-ETH legs (ETHx skipped: no request / unregistered)");

        // Emitted in getSupportedAssetList order: stETH (index 0), then native ETH (index 2; ETHx at 1 skipped).
        assertEq(positions[0].balanceAsset.asset, MAINNET_STETH);
        assertEq(positions[0].amount, STETH_EXPECTED);
        assertEq(positions[1].balanceAsset.asset, NATIVE_ETH);
        assertEq(positions[1].amount, NETH_EXPECTED);

        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAdapter, address(oracle));
            assertFalse(positions[i].isDebt);
            assertEq(positions[i].protocolId, ProtocolIds.KELP_WITHDRAWAL);
            assertEq(positions[i].positionId.length, 0, "account-global positionId is empty");
            assertEq(uint256(positions[i].positionKind), uint256(PositionKind.Supplied));
        }
    }

    function test_getAdapterPositions_filterToNativeETH() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(HOLDER, NATIVE_ETH);
        assertEq(positions.length, 1, "asset filter narrows to the native-ETH leg only");
        assertEq(positions[0].balanceAsset.asset, NATIVE_ETH);
        assertEq(positions[0].amount, NETH_EXPECTED);
    }

    function test_getAdapterBalances_bothAssets() public view {
        (address[] memory assets, uint256[] memory amounts,) = oracle.getAdapterBalances(HOLDER);
        assertEq(assets.length, 2);
        assertEq(assets[0], MAINNET_STETH);
        assertEq(amounts[0], STETH_EXPECTED);
        assertEq(assets[1], NATIVE_ETH);
        assertEq(amounts[1], NETH_EXPECTED);
    }
}
