// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    StakeWiseV3ExitQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    CoordinateNotCached,
    CoordinateStillLive,
    InvalidArguments,
    NotAContract,
    NotDelegateCall
} from "src/errors.sol";

/// @notice A remove() revert the assistant must NOT swallow (i.e. neither CoordinateStillLive nor CoordinateNotCached).
error MockUnexpectedRemoveError();

/// @notice Minimal Safe stand-in that delegatecalls a target — mirrors how a Gnosis Safe executes a delegatecall
///         action. Under the delegatecall, `address(this)` is this Safe, which is exactly the context the wrapper
///         relies on (it forces `receiver = address(this)` and the adapter tracks `address(this)`).
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

/// @notice Records submit/remove calls, standing in for the balance adapter to isolate the wrapper's behavior. The
///         adapter self-scopes by msg.sender, so the mock records msg.sender as the tracked account.
contract MockTracker {
    address public lastAccount;
    address public lastVault;
    uint256 public lastTicket;
    uint256 public lastTimestamp;
    uint256 public submits;
    uint256 public removes;

    // Simulate the real adapter's fail-loud removal guards, to exercise the assistant's selective catch.
    bool public revertStillLive; // partial claim: position still owed
    bool public revertNotCached; // ticket was never tracked
    bool public revertOther; // an unexpected error the assistant must NOT swallow

    function setRemoveReverts(bool stillLive, bool notCached) external {
        revertStillLive = stillLive;
        revertNotCached = notCached;
    }

    function setRevertOther(bool v) external {
        revertOther = v;
    }

    function submit(address vault, uint256 positionTicket, uint256 timestamp) external {
        lastAccount = msg.sender;
        lastVault = vault;
        lastTicket = positionTicket;
        lastTimestamp = timestamp;
        submits++;
    }

    function remove(address vault, uint256 positionTicket, uint256 timestamp) external {
        if (revertStillLive) revert CoordinateStillLive(msg.sender, positionTicket);
        if (revertNotCached) revert CoordinateNotCached(msg.sender, positionTicket);
        if (revertOther) revert MockUnexpectedRemoveError();
        lastAccount = msg.sender;
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

/// @title StakeWiseV3ExitQueueAssistant unit tests
/// @notice The wrapper is permissionless (no roles/admin): a Safe delegatecalls it to enter/claim and feed the adapter,
///         which self-scopes by msg.sender. `onlyDelegateCall` is the only guard — a direct call reverts.
contract StakeWiseV3ExitQueueAssistantTest is BalanceAdapterTestBase {
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

    // ---- Isolated (mock tracker): receiver forcing + adapter calls ----

    function _wrapperWithMockTracker() internal returns (StakeWiseV3ExitQueueAssistant w, MockTracker t) {
        t = new MockTracker();
        w = new StakeWiseV3ExitQueueAssistant(address(t));
    }

    function test_enterExitQueue_forcesReceiverAndSubmits() public {
        (StakeWiseV3ExitQueueAssistant w, MockTracker t) = _wrapperWithMockTracker();

        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));

        assertEq(vault.lastEnterReceiver(), address(safe), "receiver forced to the Safe");
        assertEq(vault.lastEnterShares(), 5 ether);
        assertEq(t.submits(), 1);
        assertEq(t.lastAccount(), address(safe), "adapter fed with msg.sender = the Safe");
        assertEq(t.lastVault(), address(vault));
        assertEq(t.lastTicket(), ticket);
        assertEq(t.lastTimestamp(), block.timestamp);
    }

    function test_enterExitQueue_revertsOnDirectCall() public {
        (StakeWiseV3ExitQueueAssistant w,) = _wrapperWithMockTracker();
        // Called directly on the singleton (not via delegatecall) → address(this) == SELF → NotDelegateCall.
        vm.expectRevert(NotDelegateCall.selector);
        w.enterExitQueue(address(vault), 5 ether);
    }

    function test_claimExitedAssets_revertsOnDirectCall() public {
        (StakeWiseV3ExitQueueAssistant w,) = _wrapperWithMockTracker();
        vm.expectRevert(NotDelegateCall.selector);
        w.claimExitedAssets(address(vault), 1000, block.timestamp, 1);
    }

    function test_claimExitedAssets_claimsAndRemoves() public {
        (StakeWiseV3ExitQueueAssistant w, MockTracker t) = _wrapperWithMockTracker();
        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));
        uint256 ts = block.timestamp;

        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), ticket, ts, 1)));
        assertEq(vault.lastClaimTicket(), ticket);
        assertEq(t.removes(), 1);
        assertEq(t.lastAccount(), address(safe));
        assertEq(t.lastTicket(), ticket);
    }

    /// @notice A partial claim leaves the ticket still owed; the adapter reverts CoordinateStillLive on remove, which
    ///         the assistant swallows — the claim itself still succeeds (the residual stays tracked, never dropped).
    function test_claimExitedAssets_partialClaim_keepsTracking() public {
        (StakeWiseV3ExitQueueAssistant w, MockTracker t) = _wrapperWithMockTracker();
        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));
        uint256 ts = block.timestamp;

        t.setRemoveReverts(true, false); // position still owed after the partial claim
        // Does not revert: the CoordinateStillLive from remove is swallowed and the ticket stays tracked.
        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), ticket, ts, 1)));
        assertEq(vault.lastClaimTicket(), ticket); // claim happened
        assertEq(t.removes(), 0); // remove reverted internally → not counted (ticket kept)
    }

    /// @notice An untracked ticket (e.g. cleared via clearAccount) makes remove revert CoordinateNotCached; the
    ///         assistant swallows it so the claim still succeeds (nothing to untrack — never block the claim).
    function test_claimExitedAssets_untrackedTicket_swallowsAndClaims() public {
        (StakeWiseV3ExitQueueAssistant w, MockTracker t) = _wrapperWithMockTracker();
        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));
        uint256 ts = block.timestamp;

        t.setRemoveReverts(false, true); // ticket not tracked → remove reverts CoordinateNotCached
        // Does not revert: the claim happens and CoordinateNotCached is swallowed.
        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), ticket, ts, 1)));
        assertEq(vault.lastClaimTicket(), ticket);
        assertEq(t.removes(), 0);
    }

    /// @notice An unexpected remove() revert (neither CoordinateStillLive nor CoordinateNotCached) bubbles up.
    function test_claimExitedAssets_bubblesUnexpected() public {
        (StakeWiseV3ExitQueueAssistant w, MockTracker t) = _wrapperWithMockTracker();
        bytes memory ret = safe.exec(address(w), abi.encodeCall(w.enterExitQueue, (address(vault), 5 ether)));
        uint256 ticket = abi.decode(ret, (uint256));
        uint256 ts = block.timestamp;

        t.setRevertOther(true);
        vm.expectRevert(MockUnexpectedRemoveError.selector);
        safe.exec(address(w), abi.encodeCall(w.claimExitedAssets, (address(vault), ticket, ts, 1)));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueAssistant(address(0));
    }

    function test_constructor_revertsWhenAdapterNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "adapter"));
        new StakeWiseV3ExitQueueAssistant(makeAddr("eoa"));
    }

    // ---- End-to-end with the real adapter + full mock vault ----

    function test_endToEnd_enterTracksBalance_thenClaimClears() public {
        StakeWiseV3ExitQueueAssistedBalanceAdapter adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), DELAY
        );
        balances.addSupportedAssetForTest(NATIVE);
        StakeWiseV3ExitQueueAssistant w = new StakeWiseV3ExitQueueAssistant(address(adapter));
        // No roles anywhere: the Safe delegatecalls the wrapper, which feeds the adapter with msg.sender = the Safe.

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
