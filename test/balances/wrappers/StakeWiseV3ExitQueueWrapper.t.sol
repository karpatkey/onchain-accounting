// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {StakeWiseV3ExitQueueWrapper} from "src/balances/wrappers/StakeWiseV3ExitQueueWrapper.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {NotAuthorized, InvalidArguments} from "src/errors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Minimal Safe stand-in that delegatecalls a target — mirrors how a Gnosis Safe executes a delegatecall
///         action. Under the delegatecall, `address(this)` is this Safe, which is exactly the context the wrapper
///         relies on (it forces `receiver = address(this)` and tracks the position for `address(this)`).
contract MockSafe {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @notice Records submit/remove calls, standing in for the balance adapter to isolate the wrapper's behavior.
contract MockTracker {
    address public lastAccount;
    address public lastVault;
    uint256 public lastTicket;
    uint256 public lastTimestamp;
    uint256 public submits;
    uint256 public removes;

    function submit(address account, address vault, uint256 positionTicket, uint256 timestamp) external {
        lastAccount = account;
        lastVault = vault;
        lastTicket = positionTicket;
        lastTimestamp = timestamp;
        submits++;
    }

    function remove(address account, address vault, uint256 positionTicket, uint256 timestamp) external {
        lastAccount = account;
        lastVault = vault;
        lastTicket = positionTicket;
        lastTimestamp = timestamp;
        removes++;
    }
}

/// @notice Full mock StakeWise V3 vault: exit-queue mutators (enter/claim) + the read triad the adapter values from.
///         `enterExitQueue` mints a fresh ticket and records a claimable request for `(receiver, ticket, ts)`.
contract MockEnterExitVault {
    struct Req {
        uint256 leftShares;
        uint256 exitedAssets;
        bool set;
    }

    mapping(bytes32 => Req) private _req;
    mapping(uint256 => int256) private _idx;

    uint256 public nextTicket = 1000;
    address public lastEnterReceiver;
    uint256 public lastEnterShares;
    uint256 public lastClaimTicket;

    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket) {
        positionTicket = nextTicket++;
        lastEnterReceiver = receiver;
        lastEnterShares = shares;
        _idx[positionTicket] = int256(1); // checkpointed
        _req[keccak256(abi.encode(receiver, positionTicket, block.timestamp))] = Req(0, shares, true); // 1:1 claimable
    }

    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256) external {
        lastClaimTicket = positionTicket;
        delete _req[keccak256(abi.encode(msg.sender, positionTicket, timestamp))];
    }

    function getExitQueueIndex(uint256 ticket) external view returns (int256) {
        return _idx[ticket];
    }

    function calculateExitedAssets(address receiver, uint256 ticket, uint256 ts, uint256)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets)
    {
        Req memory r = _req[keccak256(abi.encode(receiver, ticket, ts))];
        if (!r.set) return (0, 0, 0);
        return (r.leftShares, 0, r.exitedAssets);
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

contract MockVaultsRegistry {
    mapping(address => bool) public vaults;

    function setVault(address v, bool ok) external {
        vaults[v] = ok;
    }
}

/// @title StakeWiseV3ExitQueueWrapper unit tests
contract StakeWiseV3ExitQueueWrapperTest is BalanceAdapterTestBase {
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 constant DELAY = 1 days;

    MockSafe safe;
    MockEnterExitVault vault;
    MockVaultsRegistry registry;

    function setUp() public override {
        super.setUp();
        safe = new MockSafe();
        vault = new MockEnterExitVault();
        registry = new MockVaultsRegistry();
        registry.setVault(address(vault), true);
    }

    // ---- Isolated (mock tracker): receiver forcing, gating, adapter calls ----

    function _wrapperWithMockTracker() internal returns (StakeWiseV3ExitQueueWrapper w, MockTracker t) {
        t = new MockTracker();
        w = new StakeWiseV3ExitQueueWrapper(address(t), address(this));
        w.grantRole(w.DEPOSITOR_ROLE(), address(safe));
    }

    function test_enterExitQueue_forcesReceiverAndSubmits() public {
        (StakeWiseV3ExitQueueWrapper w, MockTracker t) = _wrapperWithMockTracker();

        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));

        assertEq(vault.lastEnterReceiver(), address(safe), "receiver forced to the Safe");
        assertEq(vault.lastEnterShares(), 5 ether);
        assertEq(t.submits(), 1);
        assertEq(t.lastAccount(), address(safe), "tracked under the Safe (the delegatecall context)");
        assertEq(t.lastVault(), address(vault));
        assertEq(t.lastTicket(), ticket);
        assertEq(t.lastTimestamp(), block.timestamp);
    }

    function test_enterExitQueue_revertsWithoutDepositorRole() public {
        MockTracker t = new MockTracker();
        StakeWiseV3ExitQueueWrapper w = new StakeWiseV3ExitQueueWrapper(address(t), address(this));
        // safe was NOT granted DEPOSITOR_ROLE on the wrapper.
        vm.expectRevert(NotAuthorized.selector);
        safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
    }

    function test_claimExitedAssets_claimsAndRemoves() public {
        (StakeWiseV3ExitQueueWrapper w, MockTracker t) = _wrapperWithMockTracker();
        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));
        uint256 ts = block.timestamp;

        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), ticket, ts, 1)));
        assertEq(vault.lastClaimTicket(), ticket);
        assertEq(t.removes(), 1);
        assertEq(t.lastAccount(), address(safe));
        assertEq(t.lastTicket(), ticket);
    }

    function test_claimExitedAssets_revertsWithoutDepositorRole() public {
        MockTracker t = new MockTracker();
        StakeWiseV3ExitQueueWrapper w = new StakeWiseV3ExitQueueWrapper(address(t), address(this));
        vm.expectRevert(NotAuthorized.selector);
        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), 1000, block.timestamp, 1)));
    }

    // ---- Standalone submit/remove gating (the guard that lives on the wrapper, not the adapter) ----

    function test_submit_standalone_revertsWithoutDepositorRole() public {
        (StakeWiseV3ExitQueueWrapper w,) = _wrapperWithMockTracker();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, keccak256("DEPOSITOR_ROLE")
            )
        );
        w.submit(stranger, address(vault), 1000, block.timestamp);
    }

    function test_submit_standalone_revertsWhenAccountNotSender() public {
        (StakeWiseV3ExitQueueWrapper w,) = _wrapperWithMockTracker();
        // safe holds DEPOSITOR_ROLE but tries to track a position for someone else → self-scope guard trips.
        vm.prank(address(safe));
        vm.expectRevert(NotAuthorized.selector);
        w.submit(makeAddr("other"), address(vault), 1000, block.timestamp);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueWrapper(address(0), address(this));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        MockTracker t = new MockTracker();
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueWrapper(address(t), address(0));
    }

    // ---- End-to-end with the real adapter + full mock vault ----

    function test_endToEnd_enterTracksBalance_thenClaimClears() public {
        StakeWiseV3ExitQueueAssistedBalanceAdapter adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), DELAY, address(this)
        );
        balances.addSupportedAssetForTest(NATIVE);
        StakeWiseV3ExitQueueWrapper w = new StakeWiseV3ExitQueueWrapper(address(adapter), address(this));
        // The Safe is an approved depositor on the WRAPPER only; the adapter's WRAPPER_ROLE is held by the wrapper
        // singleton (never by depositors). The wrapper feeds the adapter via a self-call, so adapter.submit's
        // msg.sender is the wrapper.
        w.grantRole(w.DEPOSITOR_ROLE(), address(safe));
        adapter.grantRole(adapter.WRAPPER_ROLE(), address(w));

        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 7 ether)));
        uint256 ticket = abi.decode(ret, (uint256));
        uint256 ts = block.timestamp;

        // The adapter now tracks the Safe's ticket and values it live (1:1 → 7 ETH owed).
        assertEq(adapter.positionsOf(address(safe)).length, 1);
        (uint256 owed,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE);
        assertEq(owed, 7 ether);

        // Claim through the wrapper: the vault clears the request and the adapter stops tracking the ticket.
        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), ticket, ts, 1)));
        assertEq(adapter.positionsOf(address(safe)).length, 0);
        (uint256 owedAfter,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE);
        assertEq(owedAfter, 0);
    }
}
