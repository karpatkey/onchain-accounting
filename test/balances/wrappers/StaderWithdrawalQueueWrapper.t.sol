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
        // Pulls ETHx from the caller (the Safe, under delegatecall), exactly like the real manager.
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

/// @notice Minimal Safe stand-in that DELEGATECALLs the wrapper the way it is meant to be used, so Stader/the adapter
///         see the Safe as `msg.sender`.
contract MockSafe {
    function delegateRequestWithdraw(address wrapper, uint256 amount) external returns (uint256) {
        return _delegateRequestWithdraw(wrapper, amount, address(this));
    }

    function delegateRequestWithdrawWithOwner(address wrapper, uint256 amount, address owner)
        external
        returns (uint256)
    {
        return _delegateRequestWithdraw(wrapper, amount, owner);
    }

    function _delegateRequestWithdraw(address wrapper, uint256 amount, address owner) internal returns (uint256) {
        (bool ok, bytes memory data) =
            wrapper.delegatecall(abi.encodeWithSignature("requestWithdraw(uint256,address)", amount, owner));
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
        return abi.decode(data, (uint256));
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

/// @title StaderWithdrawalQueueWrapper unit tests (delegatecall-only)
contract StaderWithdrawalQueueWrapperTest is Test {
    Mock_ERC20 internal ethx;
    Mock_ERC20 internal weth;
    BalancesHarness internal balances;
    MockStaderUserWithdrawalManager internal manager;
    StaderWithdrawalQueueBalanceAdapter internal adapter;
    StaderWithdrawalQueueWrapper internal wrapper;

    address internal alice = makeAddr("alice");

    uint256 internal constant AMOUNT = 5e18;

    function setUp() public {
        ethx = new Mock_ERC20("ETHx", 18);
        weth = new Mock_ERC20("WETH", 18);
        balances = new BalancesHarness();
        balances.addSupportedAssetForTest(address(weth));
        manager = new MockStaderUserWithdrawalManager(IERC20(address(ethx)));

        // The adapter is self-fed (no roles); the wrapper only needs the adapter/manager/ethx addresses.
        adapter = new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), address(balances));
        wrapper = new StaderWithdrawalQueueWrapper(address(adapter), address(manager), address(ethx));

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

    // ---- requestWithdraw (DELEGATECALL) ----

    function test_requestWithdraw_delegatecalled_pullsEthxAndTracksId() public {
        MockSafe safe = new MockSafe();
        ethx.mint(address(safe), AMOUNT);

        uint256 requestId = safe.delegateRequestWithdraw(address(wrapper), AMOUNT);

        // ETHx moved Safe -> manager; the wrapper never holds funds and the Safe granted no allowance to the wrapper.
        assertEq(ethx.balanceOf(address(safe)), 0, "Safe ETHx pulled by the manager");
        assertEq(ethx.balanceOf(address(manager)), AMOUNT, "manager received ETHx");

        // The request is owned by the Safe and tracked in the Safe's adapter cache.
        (address owner,,,,) = manager.userWithdrawRequests(requestId);
        assertEq(owner, address(safe), "request owned by the Safe");
        uint256[] memory ids = adapter.requestIdsOf(address(safe));
        assertEq(ids.length, 1);
        assertEq(ids[0], requestId);

        // Adapter values it (1:1 finalized in the mock).
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(safe), address(weth));
        assertEq(amount, AMOUNT);
    }

    function test_requestWithdraw_revertsWhenOwnerNotSelf() public {
        MockSafe safe = new MockSafe();
        ethx.mint(address(safe), AMOUNT);
        vm.expectRevert(InvalidArguments.selector);
        safe.delegateRequestWithdrawWithOwner(address(wrapper), AMOUNT, alice); // _owner != address(this)
    }

    function test_requestWithdraw_normalCallFailsSafe() public {
        // A normal CALL runs with address(this) == wrapper, so _owner must be the wrapper; anything else reverts
        // InvalidArguments. (Passing the wrapper itself would then revert pulling ETHx from the fund-less wrapper.)
        vm.expectRevert(InvalidArguments.selector);
        wrapper.requestWithdraw(AMOUNT, alice);
    }

    // ---- claim ----

    function test_claim_directCallByNonOwnerReverts() public {
        // A Safe requests (owner = Safe), then a direct CALL to wrapper.claim forwards with msg.sender = wrapper, which
        // is not the owner -> the manager rejects it. Demonstrates the fail-safe for the wrong invocation mode.
        MockSafe safe = new MockSafe();
        ethx.mint(address(safe), AMOUNT);
        uint256 requestId = safe.delegateRequestWithdraw(address(wrapper), AMOUNT);

        vm.expectRevert(MockStaderUserWithdrawalManager.CallerNotAuthorizedToRedeem.selector);
        wrapper.claim(requestId);
    }

    function test_claim_delegatecalledBySafe_claimsAndPrunes() public {
        MockSafe safe = new MockSafe();
        ethx.mint(address(safe), AMOUNT);
        uint256 requestId = safe.delegateRequestWithdraw(address(wrapper), AMOUNT);
        assertEq(adapter.requestIdsOf(address(safe)).length, 1, "id cached for the Safe");

        // Safe DELEGATECALLs claim: the manager sees msg.sender == Safe == owner, ETH flows to the Safe, and the now
        // provably-stale id is removed from the Safe's adapter cache.
        uint256 balBefore = address(safe).balance;
        safe.delegateClaim(address(wrapper), requestId);

        assertEq(address(safe).balance, balBefore + AMOUNT, "ETH claimed to the Safe");
        assertEq(adapter.requestIdsOf(address(safe)).length, 0, "cache cleaned after claim");
        (address owner,,,,) = manager.userWithdrawRequests(requestId);
        assertEq(owner, address(0), "request deleted on claim");
    }
}
