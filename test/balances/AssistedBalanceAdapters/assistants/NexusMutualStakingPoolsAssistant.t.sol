// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    MockStakingNFT,
    MockStakingViewer
} from "test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol";
import {AssistantDelegateCaller} from "test/balances/AssistedBalanceAdapters/assistants/AssistantDelegateCaller.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal Nexus StakingPool mock: `depositTo` mints the StakingNFT to `destination` (recording args) and
///         returns the tokenId; `withdraw` returns preset amounts (recording the id).
contract MockNexusPool {
    MockStakingNFT public immutable nft;

    uint256 public nextTokenId = 1;
    uint256 public lastAmount;
    uint256 public lastTranche;
    uint256 public lastRequestId;
    address public lastDestination;
    uint256 public wStake;
    uint256 public wRewards;
    uint256 public lastWithdrawId;

    constructor(MockStakingNFT nft_) {
        nft = nft_;
    }

    function setNextTokenId(uint256 id) external {
        nextTokenId = id;
    }

    function setWithdrawReturns(uint256 s, uint256 r) external {
        wStake = s;
        wRewards = r;
    }

    function depositTo(uint256 amount, uint256 trancheId, uint256 requestTokenId, address destination)
        external
        returns (uint256 tokenId)
    {
        lastAmount = amount;
        lastTranche = trancheId;
        lastRequestId = requestTokenId;
        lastDestination = destination;
        tokenId = requestTokenId == 0 ? nextTokenId : requestTokenId;
        nft.setToken(tokenId, 1, destination); // mint/assign to destination
    }

    function withdraw(uint256 tokenId, bool, bool, uint256[] memory)
        external
        returns (uint256 withdrawnStake, uint256 withdrawnRewards)
    {
        lastWithdrawId = tokenId;
        return (wStake, wRewards);
    }
}

/// @notice A deployed no-op contract to stand in for Nexus's TokenController (only needs code for requireContract).
contract MockTokenController {}

/// @notice A remove() revert the assistant must NOT swallow (neither CoordinateStillLive nor CoordinateNotCached).
error MockUnexpectedRemoveError();

/// @notice Stand-in adapter whose remove() reverts with an unexpected error, to exercise the assistant's bubble path.
contract MockRevertingNexusAdapter {
    function submit(uint256) external {}

    function remove(uint256) external pure {
        revert MockUnexpectedRemoveError();
    }
}

/// @title NexusMutualStakingPoolsAssistant unit tests (delegatecall-only module)
contract NexusMutualStakingPoolsAssistantTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    NexusMutualStakingPoolsAssistant public wrapper;
    AssistantDelegateCaller public account; // the delegatecalling staking account (holds NXM; feeds the adapter as itself)
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    MockNexusPool public pool;
    MockTokenController public tokenController;
    Mock_ERC20 public nxm;

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        pool = new MockNexusPool(nft);
        tokenController = new MockTokenController();

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances)
        );
        wrapper = new NexusMutualStakingPoolsAssistant(address(adapter), address(nxm), address(tokenController));

        // The delegatecalling account holds the NXM and feeds the permissionless adapter as itself (address(this) in
        // the module); no role grant needed.
        account = new AssistantDelegateCaller();
        deal(address(nxm), address(account), 1e24);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistant(address(0), address(nxm), address(tokenController));
    }

    function test_constructor_revertsOnZeroNxm() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistant(address(adapter), address(0), address(tokenController));
    }

    function test_constructor_revertsOnZeroTokenController() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistant(address(adapter), address(nxm), address(0));
    }

    function test_constructor_revertsWhenTokenControllerNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "TokenController"));
        new NexusMutualStakingPoolsAssistant(address(adapter), address(nxm), makeAddr("eoa"));
    }

    function test_immutables() public view {
        assertEq(wrapper.ADAPTER(), address(adapter));
        assertEq(wrapper.NXM(), address(nxm));
        assertEq(wrapper.TOKEN_CONTROLLER(), address(tokenController));
    }

    // ---- Delegatecall gating ----

    function test_depositTo_revertsOnDirectCall() public {
        vm.expectRevert(NotDelegateCall.selector);
        wrapper.depositTo(address(pool), 100, 3, 0);
    }

    function test_withdraw_revertsOnDirectCall() public {
        uint256[] memory tranches = new uint256[](0);
        vm.expectRevert(NotDelegateCall.selector);
        wrapper.withdraw(address(pool), 7, true, true, tranches);
    }

    // ---- depositTo (via delegatecall) ----

    function test_depositTo_viaDelegatecall_tracksForAccount() public {
        pool.setNextTokenId(7);
        viewer.setToken(7, 1, 100, 0, 0); // value the minted position at 100 NXM active stake

        uint256 id = account.deposit(address(wrapper), address(pool), 100, 3, 0);

        assertEq(id, 7);
        assertEq(pool.lastAmount(), 100);
        assertEq(pool.lastTranche(), 3);
        assertEq(pool.lastDestination(), address(account)); // destination = address(this) = the account
        // The module approved the TokenController from the account's context (no transferFrom — delegatecall).
        assertEq(nxm.allowance(address(account), address(tokenController)), 100);
        // Tracked + valued for the account.
        uint256[] memory tracked = adapter.tokenIdsOf(address(account));
        assertEq(tracked.length, 1);
        assertEq(tracked[0], 7);
        (uint256 bal,) = adapter.getAdapterBalanceForAsset(address(account), address(nxm));
        assertEq(bal, 100);
    }

    /// @notice A top-up (requestTokenId != 0) returns the same id; tracking is idempotent.
    function test_depositTo_topUp_idempotent() public {
        pool.setNextTokenId(7);
        account.deposit(address(wrapper), address(pool), 100, 3, 0); // mints id 7
        uint256 id2 = account.deposit(address(wrapper), address(pool), 50, 3, 7); // top-up id 7
        assertEq(id2, 7);
        assertEq(pool.lastRequestId(), 7);
        assertEq(adapter.tokenIdsOf(address(account)).length, 1);
    }

    // ---- withdraw (via delegatecall) ----

    /// @notice A FULL withdraw empties the position (no stake/rewards left), so the module untracks the id.
    function test_withdraw_full_untracks() public {
        pool.setNextTokenId(7);
        viewer.setToken(7, 1, 100, 0, 0);
        account.deposit(address(wrapper), address(pool), 100, 3, 0);
        assertEq(adapter.tokenIdsOf(address(account)).length, 1);

        pool.setWithdrawReturns(80, 5);
        viewer.setToken(7, 1, 0, 0, 0); // fully withdrawn: the position now values to 0 → removable
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 3;
        (uint256 s, uint256 r) = account.withdraw(address(wrapper), address(pool), 7, true, true, tranches);

        assertEq(s, 80);
        assertEq(r, 5);
        assertEq(pool.lastWithdrawId(), 7);
        assertEq(adapter.tokenIdsOf(address(account)).length, 0); // untracked (fully emptied)
    }

    /// @notice A PARTIAL / rewards-only withdraw leaves live stake; the module must KEEP tracking the id (the adapter
    ///         reverts CoordinateStillLive, which the module swallows) — proving the position is not silently dropped.
    function test_withdraw_partial_keepsTracking() public {
        pool.setNextTokenId(7);
        viewer.setToken(7, 1, 100, 0, 0);
        account.deposit(address(wrapper), address(pool), 100, 3, 0);
        assertEq(adapter.tokenIdsOf(address(account)).length, 1);

        pool.setWithdrawReturns(0, 5); // rewards-only withdraw; 100 active stake remains (viewer unchanged)
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 3;
        account.withdraw(address(wrapper), address(pool), 7, false, true, tranches);

        assertEq(pool.lastWithdrawId(), 7);
        assertEq(adapter.tokenIdsOf(address(account)).length, 1); // still tracked (residual stake preserved)
        (uint256 bal,) = adapter.getAdapterBalanceForAsset(address(account), address(nxm));
        assertEq(bal, 100);
    }

    function test_withdraw_uncachedId_swallowsAndWithdraws() public {
        // The account owns id 999 (Nexus does not burn the NFT on withdraw) but it was never cached (e.g. minted
        // outside the assistant, or cleared via clearAccount). The trailing remove reverts CoordinateNotCached, which
        // the module swallows — the withdraw itself must still succeed (nothing to untrack).
        nft.setToken(999, 1, address(account));
        pool.setWithdrawReturns(7, 0);
        uint256[] memory tranches = new uint256[](0);
        (uint256 s,) = account.withdraw(address(wrapper), address(pool), 999, true, false, tranches);
        assertEq(s, 7, "withdraw executed despite the id not being tracked");
        assertEq(pool.lastWithdrawId(), 999);
        assertEq(adapter.tokenIdsOf(address(account)).length, 0, "still nothing tracked");
    }

    /// @notice An unexpected remove() revert (neither CoordinateStillLive nor CoordinateNotCached) bubbles up and
    ///         reverts the whole withdraw — the assistant only swallows the two expected cache errors.
    function test_withdraw_bubblesUnexpectedRemoveError() public {
        MockRevertingNexusAdapter mockAdapter = new MockRevertingNexusAdapter();
        NexusMutualStakingPoolsAssistant w =
            new NexusMutualStakingPoolsAssistant(address(mockAdapter), address(nxm), address(tokenController));
        pool.setWithdrawReturns(1, 0);
        uint256[] memory tranches = new uint256[](0);
        vm.expectRevert(MockUnexpectedRemoveError.selector);
        account.withdraw(address(w), address(pool), 5, true, false, tranches);
    }
}
