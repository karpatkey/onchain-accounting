// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {MockStakingNFT, MockStakingViewer} from
    "test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol";
import {NexusMutualStakingPoolsAssistedBalanceAdapter} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {NexusMutualStakingPoolsWrapper, OnlyDelegateCall} from
    "src/balances/wrappers/NexusMutualStakingPoolsWrapper.sol";
import {WrapperDelegateCaller} from "test/balances/wrappers/WrapperDelegateCaller.sol";
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

/// @title NexusMutualStakingPoolsWrapper unit tests (delegatecall-only module)
contract NexusMutualStakingPoolsWrapperTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    NexusMutualStakingPoolsWrapper public wrapper;
    WrapperDelegateCaller public account; // the delegatecalling staking account (holds NXM + SUBMITTER_ROLE)
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    MockNexusPool public pool;
    MockTokenController public tokenController;
    Mock_ERC20 public nxm;

    bytes32 constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        pool = new MockNexusPool(nft);
        tokenController = new MockTokenController();

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(0)
        );
        wrapper = new NexusMutualStakingPoolsWrapper(address(adapter), address(nxm), address(tokenController));

        // The delegatecalling account is the one that holds SUBMITTER_ROLE and the NXM (address(this) in the module).
        account = new WrapperDelegateCaller();
        adapter.grantRole(SUBMITTER_ROLE, address(account));
        deal(address(nxm), address(account), 1e24);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsWrapper(address(0), address(nxm), address(tokenController));
    }

    function test_constructor_revertsOnZeroNxm() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsWrapper(address(adapter), address(0), address(tokenController));
    }

    function test_constructor_revertsOnZeroTokenController() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsWrapper(address(adapter), address(nxm), address(0));
    }

    function test_constructor_revertsWhenTokenControllerNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "TokenController"));
        new NexusMutualStakingPoolsWrapper(address(adapter), address(nxm), makeAddr("eoa"));
    }

    function test_immutables() public view {
        assertEq(wrapper.ADAPTER(), address(adapter));
        assertEq(wrapper.NXM(), address(nxm));
        assertEq(wrapper.TOKEN_CONTROLLER(), address(tokenController));
    }

    // ---- Delegatecall gating ----

    function test_depositTo_revertsOnDirectCall() public {
        vm.expectRevert(OnlyDelegateCall.selector);
        wrapper.depositTo(address(pool), 100, 3, 0);
    }

    function test_withdraw_revertsOnDirectCall() public {
        uint256[] memory tranches = new uint256[](0);
        vm.expectRevert(OnlyDelegateCall.selector);
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

    function test_withdraw_viaDelegatecall_untracks() public {
        pool.setNextTokenId(7);
        account.deposit(address(wrapper), address(pool), 100, 3, 0);
        assertEq(adapter.tokenIdsOf(address(account)).length, 1);

        pool.setWithdrawReturns(80, 5);
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 3;
        (uint256 s, uint256 r) = account.withdraw(address(wrapper), address(pool), 7, true, true, tranches);

        assertEq(s, 80);
        assertEq(r, 5);
        assertEq(pool.lastWithdrawId(), 7);
        assertEq(adapter.tokenIdsOf(address(account)).length, 0); // untracked
    }

    function test_withdraw_untrackIsIdempotentForOwnedButUncachedId() public {
        // The account owns id 999 (Nexus does not burn the NFT on withdraw) but it was never cached: remove passes the
        // ownership check and is a no-op.
        nft.setToken(999, 1, address(account));
        pool.setWithdrawReturns(1, 0);
        uint256[] memory tranches = new uint256[](0);
        (uint256 s,) = account.withdraw(address(wrapper), address(pool), 999, true, false, tranches);
        assertEq(s, 1);
        assertEq(adapter.tokenIdsOf(address(account)).length, 0);
    }
}
