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

    // Deposit-capable holders (hold vault shares at BLOCK): ENS DAO Safe (~9,713) and 0x3428… (~4,668).
    address public constant SHAREHOLDER = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
    address public constant SHAREHOLDER2 = 0x34284C27A2304132aF751b0dEc5bBa2CF98eD039;

    // Redeem-capable holders: checkpointed, past-delay, unclaimed exit positions at BLOCK (~59 ETH and ~17.87 ETH).
    address public constant CLAIMER = 0x044755C6866a83C150c140F61CFD6dD80559CD98;
    uint256 public constant CLAIM_TICKET = 0x3369f8c7db81fb8b13d7;
    uint256 public constant CLAIM_ENTRY_TS = 1_782_636_371;
    uint256 public constant CLAIM_INDEX = 1468;

    address public constant CLAIMER2 = 0x7fc304492ee5CD07bAF900BfD86aFe66A731d82f;
    uint256 public constant CLAIM2_TICKET = 0x3368929130022f47ef13;
    uint256 public constant CLAIM2_ENTRY_TS = 1_782_530_135;
    uint256 public constant CLAIM2_INDEX = 1467;

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

    /// @dev Real shares-holder enters the queue through the wrapper; asserts the adapter reports nothing BEFORE and
    ///      tracks + values the new position AFTER.
    function _assertEnter(address holder, uint256 sharesToExit) internal {
        // Before: the adapter reports nothing for this holder.
        (uint256 owedBefore,) = adapter.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        assertEq(owedBefore, 0, "zero owed before enter");
        assertEq(adapter.positionsOf(holder).length, 0, "no tracked position before enter");
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0, "no legs before enter");

        DelegateExecutor exec = _executorAt(holder);
        bytes memory ret =
            exec.exec(address(wrapper), abi.encodeCall(wrapper.enterExitQueue, (GENESIS_VAULT, sharesToExit)));
        uint256 ticket = abi.decode(ret, (uint256));

        // After: the adapter tracks the Safe's brand-new position and values it live (fully-pending → convertToAssets).
        StakeWiseV3ExitQueueAssistedBalanceAdapter.ExitPosition[] memory cached = adapter.positionsOf(holder);
        assertEq(cached.length, 1, "one tracked position after enter");
        assertEq(cached[0].vault, GENESIS_VAULT);
        assertEq(cached[0].positionTicket, ticket);
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 1, "one leg after enter");
        (uint256 owedAfter,) = adapter.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        assertGt(owedAfter, 0, "freshly-entered position is valued > 0");
        // Variation == the deposited amount: a just-entered position is fully pending, so the adapter reports exactly
        // the asset value of the shares moved into the queue (owedBefore is 0, so the delta equals owedAfter).
        assertEq(
            owedAfter - owedBefore,
            IStakeWiseExitVault(GENESIS_VAULT).convertToAssets(sharesToExit),
            "adapter's reported increase == deposited shares' asset value"
        );
    }

    /// @dev Real checkpointed position claimed through the wrapper; asserts the adapter's report at each step: nothing
    ///      before submit, the owed exit assets once tracked, and nothing again after the claim untracks it.
    function _assertClaim(address holder, uint256 ticket, uint256 ts, uint256 idx) internal {
        (uint256 left,, uint256 exitedAssets) =
            IStakeWiseExitVault(GENESIS_VAULT).calculateExitedAssets(holder, ticket, ts, idx);
        assertEq(left, 0, "fully exited");
        assertGt(exitedAssets, 0, "unclaimed, owed > 0");

        // Before submit: the adapter reports nothing for this holder.
        (uint256 owedBefore,) = adapter.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        assertEq(owedBefore, 0, "zero owed before submit");
        assertEq(adapter.positionsOf(holder).length, 0, "not tracked before submit");

        // Track the ticket (as the claimer) so the wrapper's post-claim remove succeeds.
        vm.prank(holder);
        adapter.submit(GENESIS_VAULT, ticket, ts);

        // After submit / before claim: the adapter reports the owed exit assets.
        assertEq(adapter.positionsOf(holder).length, 1, "tracked after submit");
        (uint256 owedTracked,) = adapter.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        assertEq(owedTracked, exitedAssets, "adapter reports the owed exit assets once tracked");
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 1, "one leg once tracked");

        uint256 balBefore = holder.balance;
        DelegateExecutor exec = _executorAt(holder);
        exec.exec(address(wrapper), abi.encodeCall(wrapper.claimExitedAssets, (GENESIS_VAULT, ticket, ts, idx)));

        // After: claimed ETH paid to the holder; the wrapper deregistered the ticket and the adapter reports nothing.
        assertEq(holder.balance - balBefore, exitedAssets, "holder received exactly the claimed amount");
        assertEq(adapter.positionsOf(holder).length, 0, "ticket deregistered after claim");
        (uint256 owedAfter,) = adapter.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        assertEq(owedAfter, 0, "zero owed after claim");
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0, "no legs after claim");
        // Variation == the claimed amount: the adapter's reported balance drops by exactly what was claimed.
        assertEq(owedTracked - owedAfter, exitedAssets, "adapter's reported decrease == claimed amount");
    }

    // ---- Deposit: real shares-holders enter the queue through the wrapper ----

    function test_fork_enterExitQueue_ensSafe() public {
        _assertEnter(SHAREHOLDER, 1 ether);
    }

    function test_fork_enterExitQueue_secondHolder() public {
        _assertEnter(SHAREHOLDER2, 2 ether);
    }

    // ---- Redeem: real checkpointed positions claimed through the wrapper ----

    function test_fork_claimExitedAssets_holder0447() public {
        _assertClaim(CLAIMER, CLAIM_TICKET, CLAIM_ENTRY_TS, CLAIM_INDEX);
    }

    function test_fork_claimExitedAssets_holder7fc3() public {
        _assertClaim(CLAIMER2, CLAIM2_TICKET, CLAIM2_ENTRY_TS, CLAIM2_INDEX);
    }
}
