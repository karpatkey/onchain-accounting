// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {StakeWiseV3ExitQueueWrapper} from "src/balances/wrappers/StakeWiseV3ExitQueueWrapper.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter,
    IStakeWiseExitVault
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";

/// @notice Minimal delegatecall executor. We `vm.etch` its runtime code onto a real StakeWise shares-holder so the
///         holder can delegatecall the wrapper exactly as a Gnosis Safe would (the vault keys shares by address, in
///         the vault's own storage, so they survive the etch). `receive()` lets it accept claimed ETH.
contract DelegateExecutor {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {}
}

/// @title StakeWiseV3ExitQueueWrapperForkTest
/// @notice Fork test of the wrapper's enter/claim paths against StakeWise's real Genesis vault on mainnet, using real
///         accounts with real funds. The wrapper is delegatecall-only, so each test etches a {DelegateExecutor} onto a
///         real holder and drives the wrapper through it — mirroring a Safe delegatecall (`address(this)` = the holder,
///         so the vault sees `msg.sender` = the holder and burns/pays its funds).
/// @dev Candidates (block 25,440,928):
///        - Deposit: ENS DAO Safe `0x4F20…FE64` holds ~9,713 Genesis-vault shares → can enterExitQueue.
///        - Redeem:  `0x0447…cd98` has a checkpointed, past-delay, unclaimed exit position (~59 ETH) → can claim.
contract StakeWiseV3ExitQueueWrapperForkTest is BalanceAdapterTestBase {
    address public constant VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    address public constant GENESIS_VAULT = 0xAC0F906E433d58FA868F936E8A43230473652885;
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant BLOCK = 25_440_928;

    // Deposit-capable holder (has vault shares at BLOCK).
    address public constant SHAREHOLDER = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;

    // Redeem-capable holder: checkpointed, past-delay, unclaimed exit position at BLOCK.
    address public constant CLAIMER = 0x044755C6866a83C150c140F61CFD6dD80559CD98;
    uint256 public constant CLAIM_TICKET = 0x3369f8c7db81fb8b13d7;
    uint256 public constant CLAIM_ENTRY_TS = 1_782_636_371;
    uint256 public constant CLAIM_INDEX = 1468;

    StakeWiseV3ExitQueueAssistedBalanceAdapter public adapter;
    StakeWiseV3ExitQueueWrapper public wrapper;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days
        );
        wrapper = new StakeWiseV3ExitQueueWrapper(address(adapter));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(BLOCK);
    }

    /// @dev Etch a delegatecall executor onto `holder` (preserving its vault shares, which live in vault storage).
    function _executorAt(address holder) internal returns (DelegateExecutor) {
        vm.etch(holder, address(new DelegateExecutor()).code);
        return DelegateExecutor(payable(holder));
    }

    // ---- Deposit: real shares-holder enters the queue through the wrapper ----

    function test_fork_enterExitQueue_tracksNewPosition() public {
        uint256 sharesToExit = 1 ether;
        assertGe(
            IStakeWiseExitVault(GENESIS_VAULT).convertToAssets(sharesToExit), 0, "sanity: vault convertToAssets works"
        );

        DelegateExecutor exec = _executorAt(SHAREHOLDER);
        bytes memory ret =
            exec.exec(address(wrapper), abi.encodeCall(wrapper.enterExitQueue, (GENESIS_VAULT, sharesToExit)));
        uint256 ticket = abi.decode(ret, (uint256));

        // The adapter now tracks the Safe's brand-new position and values it live (fully-pending → via convertToAssets).
        StakeWiseV3ExitQueueAssistedBalanceAdapter.ExitPosition[] memory cached = adapter.positionsOf(SHAREHOLDER);
        assertEq(cached.length, 1, "one tracked position");
        assertEq(cached[0].vault, GENESIS_VAULT);
        assertEq(cached[0].positionTicket, ticket);
        (uint256 owed,) = adapter.getAdapterBalanceForAsset(SHAREHOLDER, NATIVE_ETH);
        assertGt(owed, 0, "freshly-entered position is valued > 0");
        assertApproxEqRel(owed, IStakeWiseExitVault(GENESIS_VAULT).convertToAssets(sharesToExit), 0.01e18);
    }

    // ---- Redeem: real checkpointed position claimed through the wrapper ----

    function test_fork_claimExitedAssets_paysHolderAndUntracks() public {
        // Sanity: the position is checkpointed and unclaimed at BLOCK.
        (uint256 left,, uint256 exitedAssets) =
            IStakeWiseExitVault(GENESIS_VAULT).calculateExitedAssets(CLAIMER, CLAIM_TICKET, CLAIM_ENTRY_TS, CLAIM_INDEX);
        assertEq(left, 0, "fully exited");
        assertGt(exitedAssets, 0, "unclaimed, owed > 0");

        // Track the ticket (as the claimer) so the wrapper's post-claim remove succeeds.
        vm.prank(CLAIMER);
        adapter.submit(GENESIS_VAULT, CLAIM_TICKET, CLAIM_ENTRY_TS);
        assertEq(adapter.positionsOf(CLAIMER).length, 1);

        uint256 balBefore = CLAIMER.balance;
        DelegateExecutor exec = _executorAt(CLAIMER);
        exec.exec(
            address(wrapper),
            abi.encodeCall(wrapper.claimExitedAssets, (GENESIS_VAULT, CLAIM_TICKET, CLAIM_ENTRY_TS, CLAIM_INDEX))
        );

        // Claimed ETH was paid to the holder, and the wrapper deregistered the ticket.
        assertEq(CLAIMER.balance - balBefore, exitedAssets, "holder received the exited assets");
        assertEq(adapter.positionsOf(CLAIMER).length, 0, "ticket deregistered after claim");
    }
}
