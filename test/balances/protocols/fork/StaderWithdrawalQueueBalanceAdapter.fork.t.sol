// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {StaderWithdrawalQueueBalanceAdapter} from "src/balances/protocols/StaderWithdrawalQueueBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StaderWithdrawalQueueBalanceAdapterForkTest
/// @notice Fork tests against Stader's UserWithdrawalManager on mainnet.
/// @dev TEST_USER below is a real account with one open (pre-finalization) request id 8056 at FORK_BLOCK,
///      with `ethExpected = 37.440331321957283515` ETH and `ethFinalized = 0` (so the adapter reports ethExpected).
contract StaderWithdrawalQueueBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant USER_WITHDRAWAL_MANAGER = 0x9F0491B32DBce587c50c4C43AB303b06478193A7;

    uint256 public constant FORK_BLOCK = 25_015_000;

    address public constant TEST_USER = 0x5066bc626C292d02ACFef8d002905877148Cb37A;
    uint256 public constant TEST_USER_EXPECTED_ETH = 37_440_331_321_957_283_515;

    StaderWithdrawalQueueBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(MAINNET_WETH);
        adapter = new StaderWithdrawalQueueBalanceAdapter(USER_WITHDRAWAL_MANAGER, MAINNET_WETH, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- Real position ----

    function test_getAdapterBalanceForAsset_realHolder() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(TEST_USER, MAINNET_WETH);
        assertEq(amount, TEST_USER_EXPECTED_ETH, "Should match ethExpected for the open request");
        assertFalse(isDebt);
    }

    function test_getAdapterPositions_realHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(TEST_USER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_WETH);
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, TEST_USER_EXPECTED_ETH);
        assertFalse(positions[0].isDebt);
    }

    function test_getAdapterBalances_realHolder() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            adapter.getAdapterBalances(TEST_USER);
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_WETH);
        assertEq(amounts[0], TEST_USER_EXPECTED_ETH);
        assertFalse(isDebt[0]);
    }

    // ---- Empty / negative cases ----

    function test_getAdapterBalanceForAsset_zeroAddress() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), MAINNET_WETH);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unknownHolder() public view {
        address eoa = address(uint160(uint256(keccak256("noQueueHolder"))));
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(eoa, MAINNET_WETH);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(TEST_USER, MAINNET_USDC);
        assertEq(amount, 0);
    }

    function test_getAdapterPositions_assetFilterMismatch() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(TEST_USER, MAINNET_USDC);
        assertEq(positions.length, 0);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], MAINNET_WETH);
    }

    function test_immutableAddresses() public view {
        assertEq(address(adapter.USER_WITHDRAWAL_MANAGER()), USER_WITHDRAWAL_MANAGER);
        assertEq(adapter.UNDERLYING_TOKEN(), MAINNET_WETH);
    }
}

/// @title StaderWithdrawalQueueBalanceAdapterForkTest_Fresh
/// @notice Fresh dual-holder pin at the verification block (augments the original suite above; does not replace it).
/// @dev Captured 2026-06-16 at block 25_330_819 — see `script/development/test/stader/README.md`.
///      Queue state at the block: nextRequestId 8219, nextRequestIdToFinalize 8215 (so ids ≤ 8214 are finalized,
///      8215–8218 are still pending). One holder per math branch:
///      - PENDING `0x4D0B2dB7…` — one un-finalized request 8218 (`ethFinalized == 0`) → valued via `ethExpected`
///        = 179.475428570970280827 ETH.
///      - FINALIZED `0x404186e6…` — one finalized-unclaimed request 8214 where `ethFinalized` (…347) is **9 wei
///        below** `ethExpected` (…356), so the adapter reporting …347 proves it prefers `ethFinalized` over the
///        rate-converted estimate. The finalized request can be claimed by its owner at any time after this block —
///        the pin keeps it reproducible. Multi-request summing and the claimed-skip path are covered with mocks in
///        the unit test (a single holder spanning both branches doesn't exist on-chain at this block).
contract StaderWithdrawalQueueBalanceAdapterForkTest_Fresh is BalanceAdapterTestBase {
    address public constant USER_WITHDRAWAL_MANAGER = 0x9F0491B32DBce587c50c4C43AB303b06478193A7;

    uint256 public constant FORK_BLOCK = 25_330_819;

    /// @dev One PENDING request (8218): ethFinalized == 0 → adapter uses ethExpected.
    address public constant PENDING_HOLDER = 0x4D0B2dB7d38009884c3f2a15c1c212f4F4a356c9;
    uint256 public constant PENDING_EXPECTED_ETH = 179_475_428_570_970_280_827;

    /// @dev One FINALIZED-unclaimed request (8214): ethFinalized (…347) < ethExpected (…356) → adapter uses
    ///      ethFinalized, proving the finalized branch wins over the request-time estimate.
    address public constant FINALIZED_HOLDER = 0x404186e63CA9e1D0648a5AEc0b77cD398814C47D;
    uint256 public constant FINALIZED_EXPECTED_ETH = 10_804_926_562_492_357_347;
    uint256 public constant FINALIZED_ETH_EXPECTED_FIELD = 10_804_926_562_492_357_356;

    /// @dev Two open requests (8196 + 8197), both finalized → exercises real on-chain multi-request summing
    ///      (previously only covered with mocks). 8196 = 109058136469367 wei, 8197 = 218116272938735 wei.
    address public constant MULTI_HOLDER = 0xeB0CBBA408436997AfD29c50d6A9ffcCf9a2493f;
    uint256 public constant MULTI_REQ_8196_ETH = 109_058_136_469_367;
    uint256 public constant MULTI_REQ_8197_ETH = 218_116_272_938_735;
    uint256 public constant MULTI_EXPECTED_ETH = MULTI_REQ_8196_ETH + MULTI_REQ_8197_ETH;

    StaderWithdrawalQueueBalanceAdapter public oracle;

    function setUp() public override {
        // super.setUp() already invokes _setupFork() (overridden below) via virtual dispatch — no second call.
        super.setUp();
        balances = _deployBalancesForAdapter(MAINNET_WETH);
        oracle = new StaderWithdrawalQueueBalanceAdapter(USER_WITHDRAWAL_MANAGER, MAINNET_WETH, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- PENDING: ethFinalized == 0 → ethExpected branch ----

    function test_pending_usesEthExpected_balance() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(PENDING_HOLDER, MAINNET_WETH);
        assertEq(amount, PENDING_EXPECTED_ETH, "Un-finalized request must be valued via ethExpected");
        assertFalse(isDebt);
    }

    function test_pending_usesEthExpected_position() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(PENDING_HOLDER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_WETH);
        assertEq(positions[0].balanceAdapter, address(oracle));
        assertEq(positions[0].amount, PENDING_EXPECTED_ETH);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocolId, ProtocolIds.STADER_WITHDRAWAL);
        assertEq(positions[0].positionId.length, 0, "account-global positionId is empty");
        assertEq(uint256(positions[0].positionKind), uint256(PositionKind.Supplied));
    }

    // ---- FINALIZED: ethFinalized > 0 → preferred over ethExpected ----

    function test_finalized_prefersEthFinalized_balance() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(FINALIZED_HOLDER, MAINNET_WETH);
        assertEq(amount, FINALIZED_EXPECTED_ETH, "Finalized request must be valued via ethFinalized");
        assertTrue(amount < FINALIZED_ETH_EXPECTED_FIELD, "ethFinalized is strictly below ethExpected here");
        assertFalse(isDebt);
    }

    function test_finalized_prefersEthFinalized_position() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(FINALIZED_HOLDER, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_WETH);
        assertEq(positions[0].amount, FINALIZED_EXPECTED_ETH);
        assertEq(positions[0].protocolId, ProtocolIds.STADER_WITHDRAWAL);
        assertEq(uint256(positions[0].positionKind), uint256(PositionKind.Supplied));
    }

    // ---- MULTI: two open requests summed into one aggregated leg (real on-chain summing) ----

    function test_multi_sumsAcrossRequests_balance() public view {
        (uint256 amount, bool isDebt) = oracle.getAdapterBalanceForAsset(MULTI_HOLDER, MAINNET_WETH);
        assertEq(amount, MULTI_EXPECTED_ETH, "Sum of both open requests (8196 + 8197)");
        assertFalse(isDebt);
    }

    function test_multi_sumsAcrossRequests_position() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getAdapterPositions(MULTI_HOLDER, address(0));
        // Still ONE aggregated leg, not one-per-request — the adapter sums; the per-request split is display-only.
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, MAINNET_WETH);
        assertEq(positions[0].amount, MULTI_EXPECTED_ETH);
        assertEq(positions[0].protocolId, ProtocolIds.STADER_WITHDRAWAL);
        assertEq(positions[0].positionId.length, 0, "account-global positionId is empty");
        assertEq(uint256(positions[0].positionKind), uint256(PositionKind.Supplied));
    }
}
