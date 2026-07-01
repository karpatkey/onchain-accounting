// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {MockStakingNFT, MockStakingViewer} from
    "test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol";
import {NexusMutualStakingPoolsAssistedBalanceAdapter} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {NexusMutualStakingPoolsWrapper} from "src/balances/wrappers/NexusMutualStakingPoolsWrapper.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal Nexus StakingPool mock: `depositTo` mints the StakingNFT to `destination` (recording args) and
///         returns the tokenId; `withdraw` returns preset amounts (recording the id). Mirrors the two functions the
///         wrapper forwards.
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

/// @title NexusMutualStakingPoolsWrapper unit tests
contract NexusMutualStakingPoolsWrapperTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    NexusMutualStakingPoolsWrapper public wrapper;
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    MockNexusPool public pool;
    Mock_ERC20 public nxm;

    address depositor = makeAddr("depositor");
    address other = makeAddr("other");

    bytes32 constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");
    bytes32 constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        pool = new MockNexusPool(nft);

        // adapter: admin = this, wrapper granted after wrapper deploy (it needs the adapter address).
        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(0)
        );
        wrapper = new NexusMutualStakingPoolsWrapper(address(adapter), address(nxm), address(this));
        adapter.grantRole(SUBMITTER_ROLE, address(wrapper));
        wrapper.grantRole(DEPOSITOR_ROLE, depositor);

        // NXM is pulled from the DEPOSITOR: fund the depositor and approve the wrapper to spend it.
        deal(address(nxm), depositor, 1e24);
        vm.prank(depositor);
        nxm.approve(address(wrapper), type(uint256).max);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsWrapper(address(0), address(nxm), address(this));
    }

    function test_constructor_revertsOnZeroNxm() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsWrapper(address(adapter), address(0), address(this));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsWrapper(address(adapter), address(nxm), address(0));
    }

    function test_constructor_revertsWhenAdapterNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "adapter"));
        new NexusMutualStakingPoolsWrapper(makeAddr("eoa"), address(nxm), address(this));
    }

    function test_immutables() public view {
        assertEq(wrapper.ADAPTER(), address(adapter));
        assertEq(wrapper.NXM(), address(nxm));
        assertTrue(wrapper.hasRole(wrapper.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ---- depositTo ----

    function test_depositTo_forwardsAndTracks() public {
        pool.setNextTokenId(7);
        uint256 depositorBefore = nxm.balanceOf(depositor);
        vm.prank(depositor);
        uint256 id = wrapper.depositTo(address(pool), 100, 3, 0);

        assertEq(id, 7);
        assertEq(pool.lastAmount(), 100);
        assertEq(pool.lastTranche(), 3);
        assertEq(pool.lastRequestId(), 0);
        assertEq(pool.lastDestination(), depositor); // wrapper hardcodes destination = caller
        // NXM was pulled from the depositor into the wrapper (the mock pool does not pull further).
        assertEq(nxm.balanceOf(depositor), depositorBefore - 100);
        assertEq(nxm.balanceOf(address(wrapper)), 100);
        // The id is now tracked for the caller.
        uint256[] memory tracked = adapter.tokenIdsOf(depositor);
        assertEq(tracked.length, 1);
        assertEq(tracked[0], 7);
    }

    function test_depositTo_onlyDepositor() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, DEPOSITOR_ROLE)
        );
        wrapper.depositTo(address(pool), 100, 3, 0);
    }

    /// @notice A top-up (requestTokenId != 0) returns the same id; tracking is idempotent.
    function test_depositTo_topUp_idempotent() public {
        pool.setNextTokenId(7);
        vm.startPrank(depositor);
        wrapper.depositTo(address(pool), 100, 3, 0); // mints id 7
        uint256 id2 = wrapper.depositTo(address(pool), 50, 3, 7); // top-up id 7
        vm.stopPrank();
        assertEq(id2, 7);
        assertEq(pool.lastRequestId(), 7);
        assertEq(adapter.tokenIdsOf(depositor).length, 1);
    }

    // ---- withdraw ----

    function test_withdraw_forwardsAndUntracks() public {
        pool.setNextTokenId(7);
        vm.prank(depositor);
        wrapper.depositTo(address(pool), 100, 3, 0);
        assertEq(adapter.tokenIdsOf(depositor).length, 1);

        pool.setWithdrawReturns(80, 5);
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 3;
        vm.prank(depositor);
        (uint256 s, uint256 r) = wrapper.withdraw(address(pool), 7, true, true, tranches);

        assertEq(s, 80);
        assertEq(r, 5);
        assertEq(pool.lastWithdrawId(), 7);
        assertEq(adapter.tokenIdsOf(depositor).length, 0); // untracked
    }

    function test_withdraw_onlyDepositor() public {
        uint256[] memory tranches = new uint256[](0);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, DEPOSITOR_ROLE)
        );
        wrapper.withdraw(address(pool), 7, true, true, tranches);
    }

    function test_withdraw_untrackIsIdempotentForUncachedId() public {
        // Withdrawing an id the caller never tracked simply forwards and no-ops the remove (no revert).
        pool.setWithdrawReturns(1, 0);
        uint256[] memory tranches = new uint256[](0);
        vm.prank(depositor);
        (uint256 s,) = wrapper.withdraw(address(pool), 999, true, false, tranches);
        assertEq(s, 1);
        assertEq(adapter.tokenIdsOf(depositor).length, 0);
    }
}
