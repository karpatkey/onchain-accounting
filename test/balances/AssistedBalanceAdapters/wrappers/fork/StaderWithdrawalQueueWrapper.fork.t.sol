// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    StaderWithdrawalQueueWrapper
} from "src/balances/AssistedBalanceAdapters/wrappers/StaderWithdrawalQueueWrapper.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";

/// @notice Safe stand-in that DELEGATECALLs the wrapper (both entrypoints are delegatecall-only), so the live Stader
///         manager and the adapter see this contract as `msg.sender` / the request owner.
contract ForkMockSafe {
    function delegateRequestWithdraw(address wrapper, uint256 amount) external returns (uint256) {
        (bool ok, bytes memory data) =
            wrapper.delegatecall(abi.encodeWithSignature("requestWithdraw(uint256,address)", amount, address(this)));
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
        return abi.decode(data, (uint256));
    }

    receive() external payable {}
}

/// @notice Minimal live-manager surface used by the test to read/claim.
interface IStaderUWM {
    function userWithdrawRequests(uint256 requestId)
        external
        view
        returns (address owner, uint256 ethXAmount, uint256 ethExpected, uint256 ethFinalized, uint256 requestBlock);
    function claim(uint256 requestId) external;
}

/// @title StaderWithdrawalQueueWrapperForkTest
/// @notice End-to-end fork tests against Stader's LIVE `UserWithdrawalManager` with REAL funds — the deposit path
///         through the wrapper (real ETHx), and the redeem path (real finalized request, real `claim`).
/// @dev Pinned at block 25_330_819. Candidates verified on-chain at that block:
///      - Deposit funding source: the Balancer Vault (`0xBA12…F2C8`) holds ~130 ETHx — a real account we prank to fund
///        the test Safe, which then requests a withdrawal through the wrapper against the live manager.
///      - Redeem candidate: EOA `0x4041…C47D` owns request 8214, finalized (`nextRequestIdToFinalize` = 8215) and
///        unclaimed, `ethFinalized` = 10.804926562492357347 ETH; the manager holds ~854 ETH so the claim pays out.
contract StaderWithdrawalQueueWrapperForkTest is BalanceAdapterTestBase {
    address public constant USER_WITHDRAWAL_MANAGER = 0x9F0491B32DBce587c50c4C43AB303b06478193A7;
    address public constant ETHX = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;

    uint256 public constant FORK_BLOCK = 25_330_819;

    /// @dev Balancer Vault — holds ~130 ETHx at FORK_BLOCK; used to fund the depositing Safe with real ETHx.
    address public constant ETHX_WHALE = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @dev EOA owning finalized-unclaimed request 8214 at FORK_BLOCK — the redeem candidate.
    address public constant FINALIZED_HOLDER = 0x404186e63CA9e1D0648a5AEc0b77cD398814C47D;
    uint256 public constant FINALIZED_REQ_ID = 8214;
    uint256 public constant FINALIZED_ETH = 10_804_926_562_492_357_347;

    StaderWithdrawalQueueBalanceAdapter public adapter;
    StaderWithdrawalQueueWrapper public wrapper;
    ForkMockSafe public safe;

    function setUp() public override {
        super.setUp();
        balances = _deployBalancesForAdapter(MAINNET_WETH);
        adapter = new StaderWithdrawalQueueBalanceAdapter(USER_WITHDRAWAL_MANAGER, MAINNET_WETH, address(balances));
        wrapper = new StaderWithdrawalQueueWrapper(address(adapter), USER_WITHDRAWAL_MANAGER, ETHX);
        safe = new ForkMockSafe();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ---- Deposit: real ETHx through the wrapper's (delegatecalled) requestWithdraw ----

    function test_deposit_realFunds_viaWrapperDelegatecall() public {
        uint256 amount = 1e18; // 1 ETHx — previewWithdraw ~1.09 ETH, within the manager's [1e14, 1e22] bounds.

        // Fund the Safe with REAL ETHx pulled from a real holder (the Balancer Vault).
        vm.prank(ETHX_WHALE);
        IERC20(ETHX).transfer(address(safe), amount);
        assertEq(IERC20(ETHX).balanceOf(address(safe)), amount, "Safe funded with real ETHx");

        // The Safe delegatecalls the wrapper, which requests the withdrawal on the LIVE manager and submits the id.
        uint256 requestId = safe.delegateRequestWithdraw(address(wrapper), amount);

        // A real request now exists on the live manager, owned by the Safe; the ETHx was pulled from the Safe.
        (address owner,, uint256 ethExpected, uint256 ethFinalized,) =
            IStaderUWM(USER_WITHDRAWAL_MANAGER).userWithdrawRequests(requestId);
        assertEq(owner, address(safe), "live request owned by the Safe");
        assertGt(ethExpected, 0, "manager recorded a rate-converted ethExpected");
        assertEq(ethFinalized, 0, "a fresh request is pending, not finalized");
        assertEq(IERC20(ETHX).balanceOf(address(safe)), 0, "ETHx pulled by the manager");
        assertEq(IERC20(ETHX).balanceOf(address(wrapper)), 0, "wrapper never custodies ETHx");

        // The adapter tracks the id for the Safe and values it at the manager's ethExpected (pending -> locked).
        uint256[] memory ids = adapter.requestIdsOf(address(safe));
        assertEq(ids.length, 1, "id cached for the Safe");
        assertEq(ids[0], requestId);
        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(address(safe), MAINNET_WETH);
        assertEq(amt, ethExpected, "adapter values the pending request at ethExpected");
        assertFalse(isDebt);
    }

    // ---- Redeem: real finalized request, real claim on the live manager, adapter cleanup ----

    function test_redeem_realFunds_claimAndPrune() public {
        // Seed the adapter cache as the real finalized holder (submit is keyed on msg.sender).
        vm.prank(FINALIZED_HOLDER);
        adapter.submit(FINALIZED_REQ_ID);

        // Finalized -> valued at ethFinalized, unlocked (claimable).
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(FINALIZED_HOLDER, MAINNET_WETH);
        assertEq(amt, FINALIZED_ETH, "finalized request valued at ethFinalized");

        // Real claim on the LIVE manager: ETH flows to the holder, the request is deleted.
        uint256 balBefore = FINALIZED_HOLDER.balance;
        vm.prank(FINALIZED_HOLDER);
        IStaderUWM(USER_WITHDRAWAL_MANAGER).claim(FINALIZED_REQ_ID);
        assertEq(FINALIZED_HOLDER.balance, balBefore + FINALIZED_ETH, "ETH claimed to the holder");
        (address ownerAfter,,,,) = IStaderUWM(USER_WITHDRAWAL_MANAGER).userWithdrawRequests(FINALIZED_REQ_ID);
        assertEq(ownerAfter, address(0), "request deleted on claim");

        // The claimed request now values to 0, and the provably-stale id can be removed from the cache.
        (uint256 amtAfter,) = adapter.getAdapterBalanceForAsset(FINALIZED_HOLDER, MAINNET_WETH);
        assertEq(amtAfter, 0, "claimed request no longer valued");
        vm.prank(FINALIZED_HOLDER);
        adapter.remove(FINALIZED_REQ_ID);
        assertEq(adapter.requestIdsOf(FINALIZED_HOLDER).length, 0, "cache cleaned after claim");
    }
}
