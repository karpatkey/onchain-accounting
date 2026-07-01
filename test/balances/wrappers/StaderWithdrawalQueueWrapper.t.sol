// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";

import {StaderWithdrawalQueueWrapper} from "src/balances/wrappers/StaderWithdrawalQueueWrapper.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Combined mock of Stader's UserWithdrawalManager: the `requestWithdraw`/`claim` surface the wrapper forwards
///         to, plus the `userWithdrawRequests` getter the adapter reads for its ownership/valuation checks.
contract MockStaderUserWithdrawalManager {
    IERC20 public immutable ethx;
    uint256 public nextId = 1;

    struct Req {
        address owner;
        uint256 ethXAmount;
        uint256 ethExpected;
        uint256 ethFinalized;
        uint256 requestBlock;
    }

    mapping(uint256 => Req) public userWithdrawRequests;

    error CallerNotAuthorizedToRedeem();

    constructor(IERC20 _ethx) {
        ethx = _ethx;
    }

    function requestWithdraw(uint256 _ethXAmount, address _owner) external returns (uint256 requestId) {
        // Pulls ETHx from the caller (the wrapper), exactly like the real manager.
        ethx.transferFrom(msg.sender, address(this), _ethXAmount);
        requestId = nextId++;
        // 1:1 finalized valuation keeps the claim payout deterministic for the test.
        userWithdrawRequests[requestId] = Req(_owner, _ethXAmount, _ethXAmount, _ethXAmount, block.number);
    }

    function claim(uint256 _requestId) external {
        Req memory r = userWithdrawRequests[_requestId];
        if (msg.sender != r.owner) revert CallerNotAuthorizedToRedeem();
        delete userWithdrawRequests[_requestId];
        (bool ok,) = payable(r.owner).call{value: r.ethFinalized}("");
        require(ok, "eth send failed");
    }

    receive() external payable {}
}

/// @notice Minimal Safe stand-in that can drive the wrapper the two ways it is meant to be used: a normal CALL to
///         `requestWithdraw`, and a DELEGATECALL to `claim` (so Stader sees the Safe as `msg.sender == owner`).
contract MockSafe {
    function approveEthx(IERC20 ethx, address spender, uint256 amount) external {
        ethx.approve(spender, amount);
    }

    function callRequestWithdraw(address wrapper, uint256 amount) external returns (uint256) {
        return StaderWithdrawalQueueWrapper(wrapper).requestWithdraw(amount, address(this));
    }

    function delegateClaim(address wrapper, uint256 requestId) external {
        (bool ok, bytes memory data) = wrapper.delegatecall(abi.encodeWithSignature("claim(uint256)", requestId));
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    receive() external payable {}
}

/// @title StaderWithdrawalQueueWrapper unit tests
contract StaderWithdrawalQueueWrapperTest is Test {
    Mock_ERC20 internal ethx;
    BalancesHarness internal balances;
    MockStaderUserWithdrawalManager internal manager;
    StaderWithdrawalQueueBalanceAdapter internal adapter;
    StaderWithdrawalQueueWrapper internal wrapper;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    Mock_ERC20 internal weth;

    uint256 internal constant AMOUNT = 5e18;

    function setUp() public {
        ethx = new Mock_ERC20("ETHx", 18);
        weth = new Mock_ERC20("WETH", 18);
        balances = new BalancesHarness();
        balances.addSupportedAssetForTest(address(weth));
        manager = new MockStaderUserWithdrawalManager(IERC20(address(ethx)));

        // Deploy the adapter (submitter unset), the wrapper (needs the adapter address), then grant the wrapper
        // SUBMITTER_ROLE — the real deploy order.
        adapter = new StaderWithdrawalQueueBalanceAdapter(
            address(manager), address(weth), address(balances), address(this), address(0)
        );
        wrapper = new StaderWithdrawalQueueWrapper(address(adapter), address(manager), address(ethx));
        adapter.grantRole(adapter.SUBMITTER_ROLE(), address(wrapper));

        vm.deal(address(manager), 100 ether);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroArg() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueWrapper(address(0), address(manager), address(ethx));
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueWrapper(address(adapter), address(0), address(ethx));
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueWrapper(address(adapter), address(manager), address(0));
    }

    // ---- requestWithdraw (normal CALL, permissionless) ----

    function test_requestWithdraw_revertsWhenOwnerNotCaller() public {
        ethx.mint(alice, AMOUNT);
        vm.startPrank(alice);
        ethx.approve(address(wrapper), AMOUNT);
        vm.expectRevert(InvalidArguments.selector);
        wrapper.requestWithdraw(AMOUNT, admin); // _owner != msg.sender
        vm.stopPrank();
    }

    function test_requestWithdraw_pullsEthxAndTracksId() public {
        ethx.mint(alice, AMOUNT);

        vm.startPrank(alice);
        ethx.approve(address(wrapper), AMOUNT);
        uint256 requestId = wrapper.requestWithdraw(AMOUNT, alice);
        vm.stopPrank();

        // ETHx moved depositor -> wrapper -> manager; wrapper custodies nothing.
        assertEq(ethx.balanceOf(alice), 0, "depositor ETHx pulled");
        assertEq(ethx.balanceOf(address(wrapper)), 0, "wrapper custodies no ETHx");
        assertEq(ethx.balanceOf(address(manager)), AMOUNT, "manager received ETHx");

        // The request is owned by the depositor and tracked in the adapter cache.
        (address owner,,,,) = manager.userWithdrawRequests(requestId);
        assertEq(owner, alice, "request owned by depositor");
        uint256[] memory ids = adapter.requestIdsOf(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], requestId);

        // Adapter values it (1:1 finalized in the mock).
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, AMOUNT);
    }

    // ---- claim ----

    function test_claim_directCallByNonOwnerReverts() public {
        // alice requests (owner = alice), then a direct CALL to wrapper.claim forwards with msg.sender = wrapper,
        // which is not the owner -> the manager rejects it. Demonstrates the fail-safe for the wrong invocation mode.
        ethx.mint(alice, AMOUNT);
        vm.startPrank(alice);
        ethx.approve(address(wrapper), AMOUNT);
        uint256 requestId = wrapper.requestWithdraw(AMOUNT, alice);
        vm.stopPrank();

        vm.expectRevert(MockStaderUserWithdrawalManager.CallerNotAuthorizedToRedeem.selector);
        wrapper.claim(requestId);
    }

    function test_claim_delegatecalledBySafe_claimsAndPrunes() public {
        MockSafe safe = new MockSafe();
        ethx.mint(address(safe), AMOUNT);

        // Safe requests through the wrapper (normal CALL): owner = Safe, cache tracks the id.
        safe.approveEthx(IERC20(address(ethx)), address(wrapper), AMOUNT);
        uint256 requestId = safe.callRequestWithdraw(address(wrapper), AMOUNT);
        assertEq(adapter.requestIdsOf(address(safe)).length, 1, "id cached for the Safe");

        // Safe DELEGATECALLs claim: the manager sees msg.sender == Safe == owner, ETH flows to the Safe, and the now
        // provably-stale id is pruned from the adapter cache.
        uint256 balBefore = address(safe).balance;
        safe.delegateClaim(address(wrapper), requestId);

        assertEq(address(safe).balance, balBefore + AMOUNT, "ETH claimed to the Safe");
        assertEq(adapter.requestIdsOf(address(safe)).length, 0, "cache pruned after claim");
        (address owner,,,,) = manager.userWithdrawRequests(requestId);
        assertEq(owner, address(0), "request deleted on claim");
    }
}
