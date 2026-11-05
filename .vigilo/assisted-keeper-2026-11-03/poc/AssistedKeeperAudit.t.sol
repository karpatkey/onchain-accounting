// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Vigilo audit PoCs for PR #360 (ADR 0030) — assisted keeper path. Audit-only; not part of the PR.
// Each test either VALIDATES a candidate finding or REFUTES it (negative PoC). See
// .vigilo/assisted-keeper-2026-11-03/reports/ for the write-up.

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    MockWithdrawRequestNFT,
    MockLiquidityPool
} from "test/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueue.t.sol";
import {
    MockStakingNFT,
    MockStakingViewer
} from "test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/StakeWiseV3ExitQueueAssistant.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal Safe stand-in: delegatecalls the assistant (msg.sender seen by the adapter = this contract).
contract AuditSafe {
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

contract AuditRegistry {
    mapping(address => bool) public vaults;

    function setVault(address v, bool ok) external {
        vaults[v] = ok;
    }
}

/// @notice Faithful port of stakewise/v3-core `main` VaultEnterExit exit-queue semantics (calculateExitedAssets incl.
///         the `leftTickets == 1` rounding, claimExitedAssets delete + re-queue under `ticket + exitedTickets` with the
///         same timestamp, uncollateralized immediate redemption) over a port of the ExitQueue checkpoint library.
contract StakeWiseModelVault {
    struct Checkpoint {
        uint160 totalTickets;
        uint96 exitedAssets;
    }

    Checkpoint[] internal _cps;
    mapping(bytes32 => uint256) internal _exitRequests;
    mapping(address => uint256) public balanceOf;
    uint256 public queuedShares;
    uint256 public constant DELAY = 1 days;
    bool public collateralized = true;

    function mint(address to, uint256 shares) external {
        balanceOf[to] += shares;
    }

    function setCollateralized(bool c) external {
        collateralized = c;
    }

    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1 for clarity
    }

    function _latestTotal() internal view returns (uint256) {
        return _cps.length == 0 ? 0 : _cps[_cps.length - 1].totalTickets;
    }

    /// @notice Process `shares` of the queue paying `assets` (the keeper/harvest checkpoint).
    function checkpoint(uint256 shares, uint256 assets) external {
        _cps.push(Checkpoint(uint160(_latestTotal() + shares), uint96(assets)));
        queuedShares -= shares;
    }

    function enterExitQueue(uint256 shares, address receiver) external returns (uint256 positionTicket) {
        require(shares > 0 && receiver != address(0));
        if (!collateralized) {
            balanceOf[msg.sender] -= shares;
            payable(receiver).transfer(convertToAssets(shares));
            return type(uint256).max;
        }
        positionTicket = _latestTotal() + queuedShares;
        _exitRequests[keccak256(abi.encode(receiver, block.timestamp, positionTicket))] = shares;
        balanceOf[msg.sender] -= shares;
        queuedShares += shares;
    }

    function getExitQueueIndex(uint256 positionTicket) external view returns (int256) {
        uint256 high = _cps.length;
        uint256 low;
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_cps[mid].totalTickets > positionTicket) high = mid;
            else low = mid + 1;
        }
        return high < _cps.length ? int256(high) : -1;
    }

    function _calc(uint256 checkpointIdx, uint256 positionTicket, uint256 positionShares)
        internal
        view
        returns (uint256 burnedShares, uint256 exitedAssets)
    {
        uint256 length = _cps.length;
        if (checkpointIdx >= length || positionShares == 0) return (0, 0);
        uint256 prevTotalTickets = checkpointIdx == 0 ? 0 : _cps[checkpointIdx - 1].totalTickets;
        Checkpoint memory cp = _cps[checkpointIdx];
        uint256 currTotalTickets = cp.totalTickets;
        uint256 checkpointAssets = cp.exitedAssets;
        require(!(positionTicket < prevTotalTickets || currTotalTickets <= positionTicket), "InvalidCheckpointIndex");
        uint256 availableShares = currTotalTickets - positionTicket;
        while (true) {
            uint256 checkpointShares = currTotalTickets - prevTotalTickets;
            uint256 sharesDelta = Math.min(availableShares, positionShares - burnedShares);
            burnedShares += sharesDelta;
            exitedAssets += Math.mulDiv(sharesDelta, checkpointAssets, checkpointShares);
            checkpointIdx++;
            if (positionShares <= burnedShares || checkpointIdx >= length) return (burnedShares, exitedAssets);
            prevTotalTickets = currTotalTickets;
            cp = _cps[checkpointIdx];
            currTotalTickets = cp.totalTickets;
            checkpointAssets = cp.exitedAssets;
            availableShares = currTotalTickets - prevTotalTickets;
        }
    }

    function calculateExitedAssets(address receiver, uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex)
        public
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets)
    {
        uint256 exitingTickets = _exitRequests[keccak256(abi.encode(receiver, timestamp, positionTicket))];
        if (exitingTickets == 0) return (0, 0, 0);
        (exitedTickets, exitedAssets) = _calc(exitQueueIndex, positionTicket, exitingTickets);
        leftTickets = exitingTickets - exitedTickets;
        if (leftTickets == 1) {
            leftTickets = 0;
            exitedTickets += 1;
        }
    }

    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external {
        (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets) =
            calculateExitedAssets(msg.sender, positionTicket, timestamp, exitQueueIndex);
        require(block.timestamp >= timestamp + DELAY && exitedTickets != 0 && exitedAssets != 0, "NotProcessed");
        delete _exitRequests[keccak256(abi.encode(msg.sender, timestamp, positionTicket))];
        if (leftTickets > 1) {
            _exitRequests[keccak256(abi.encode(msg.sender, timestamp, positionTicket + exitedTickets))] = leftTickets;
        }
        payable(msg.sender).transfer(exitedAssets);
    }

    receive() external payable {}
}

/// @title StakeWise Assistant remainder (Decision 5) vs a faithful StakeWise model + insufficient-gas sweep.
contract AuditStakeWiseRemainderTest is BalanceAdapterTestBase {
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    AuditSafe internal safe;
    StakeWiseModelVault internal vault;
    AuditRegistry internal registry;
    StakeWiseV3ExitQueueAssistedBalanceAdapter internal adapter;
    StakeWiseV3ExitQueueAssistant internal assistant;

    function setUp() public override {
        super.setUp();
        balances.addSupportedAssetForTest(NATIVE);
        safe = new AuditSafe();
        vault = new StakeWiseModelVault();
        registry = new AuditRegistry();
        registry.setVault(address(vault), true);
        adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), 1 days, address(this)
        );
        assistant = new StakeWiseV3ExitQueueAssistant(address(adapter));
        vm.deal(address(vault), 1_000 ether);
        vm.warp(1_700_000_000);
    }

    function _enter(uint256 shares) internal returns (uint256 ticket, uint256 ts) {
        vault.mint(address(safe), shares);
        ts = block.timestamp;
        ticket = abi.decode(
            safe.exec(address(assistant), abi.encodeCall(assistant.enterExitQueue, (address(vault), shares))),
            (uint256)
        );
    }

    function _owed() internal view returns (uint256 a) {
        (a,) = adapter.getAdapterBalanceForAsset(address(safe), NATIVE);
    }

    /// @notice Decision 5 validated end-to-end: a partial claim deregisters the claimed ticket and registers exactly
    ///         the remainder; NAV after = NAV before - claimed (no drop-out, no double count).
    function test_remainder_partialClaim_tracksExactRemainder_noDoubleCount() public {
        (uint256 ticket, uint256 ts) = _enter(10 ether);
        // a second request so the remainder must not alias it
        vm.warp(block.timestamp + 1);
        (uint256 ticket2,) = _enter(5 ether);
        vault.checkpoint(4 ether, 4 ether); // processes 4 of the first 10
        vm.warp(ts + 1 days);
        uint256 before = _owed();
        assertEq(before, 15 ether, "both requests valued");

        uint256 idx = uint256(vault.getExitQueueIndex(ticket));
        safe.exec(address(assistant), abi.encodeCall(assistant.claimExitedAssets, (address(vault), ticket, ts, idx)));

        assertEq(_owed(), before - 4 ether, "NAV = before - claimed");
        bytes[] memory coords = adapter.coordsOf(address(safe));
        assertEq(coords.length, 2, "old ticket replaced by remainder");
        bool foundRemainder;
        for (uint256 i; i < coords.length; ++i) {
            (address v, uint256 t, uint256 s) = abi.decode(coords[i], (address, uint256, uint256));
            assertEq(v, address(vault));
            assertTrue(t != ticket, "claimed ticket deregistered");
            if (t == ticket + 4 ether) {
                foundRemainder = true;
                assertEq(s, ts, "remainder keeps entry timestamp");
            } else {
                assertEq(t, ticket2);
            }
        }
        assertTrue(foundRemainder, "remainder registered");
    }

    /// @notice leftTickets == 1 rounding: StakeWise drops the 1-ticket remainder; the Assistant must not register.
    function test_remainder_singleLeftoverTicket_notRegistered() public {
        (uint256 ticket,) = _enter(10);
        uint256 ts = 1_700_000_000; // pinned: via_ir re-reads block.timestamp after vm.warp
        vault.checkpoint(9, 9);
        vm.warp(ts + 1 days);
        uint256 idx = uint256(vault.getExitQueueIndex(ticket));
        safe.exec(address(assistant), abi.encodeCall(assistant.claimExitedAssets, (address(vault), ticket, ts, idx)));
        assertEq(adapter.coordsOf(address(safe)).length, 0, "nothing left to track");
    }

    /// @notice Uncollateralized vault: immediate redemption returns type(uint256).max; the Assistant must not revert.
    function test_uncollateralized_enter_doesNotRevert_noEntry() public {
        vault.setCollateralized(false);
        (uint256 ticket,) = _enter(3 ether);
        assertEq(ticket, type(uint256).max);
        assertEq(adapter.coordsOf(address(safe)).length, 0);
    }

    /// @notice Insufficient-gas griefing of the bare `catch {}` around the remainder `submit`: sweep the outer gas and
    ///         assert there is NO gas value where the claim succeeds while the remainder is left untracked.
    ///         (The real Safe has an even longer post-call tail than AuditSafe, which only makes starving harder.)
    function test_remainder_gasSweep_noSilentUntrackedSuccess() public {
        (uint256 ticket, uint256 ts) = _enter(10 ether);
        vault.checkpoint(4 ether, 4 ether);
        vm.warp(ts + 1 days);
        uint256 idx = uint256(vault.getExitQueueIndex(ticket));
        bytes memory call_ = abi.encodeCall(
            AuditSafe.exec,
            (address(assistant), abi.encodeCall(assistant.claimExitedAssets, (address(vault), ticket, ts, idx)))
        );
        bytes memory remainder = abi.encode(address(vault), ticket + 4 ether, ts);

        uint256 successes;
        uint256 silentUntracked;
        for (uint256 g = 40_000; g <= 400_000; g += 500) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(safe).call{gas: g}(call_);
            if (ok) {
                successes++;
                bytes[] memory coords = adapter.coordsOf(address(safe));
                bool tracked;
                for (uint256 i; i < coords.length; ++i) {
                    if (keccak256(coords[i]) == keccak256(remainder)) tracked = true;
                }
                if (!tracked) silentUntracked++;
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("successful claims in sweep", successes);
        emit log_named_uint("claims that succeeded with remainder untracked", silentUntracked);
        assertGt(successes, 0, "sweep reached the success region");
        assertEq(silentUntracked, 0, "no gas value starves only the remainder registration");
    }
}

/// @title removeFor gas-griefing sweep (S6): a caller choosing the gas cannot turn a live position into "dead".
contract AuditRemoveForGasGriefTest is BalanceAdapterTestBase {
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal holder = makeAddr("holder");
    address internal attacker = makeAddr("attacker");

    function _sweep(address target, bytes memory data, address acct, bytes memory coord, bytes memory cacheView)
        internal
        returns (uint256 drops)
    {
        for (uint256 g = 3_000; g <= 200_000; g += 250) {
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            (bool ok,) = target.call{gas: g}(data);
            (, bytes memory ret) = target.staticcall(cacheView);
            bytes[] memory coords = abi.decode(ret, (bytes[]));
            bool still;
            for (uint256 i; i < coords.length; ++i) {
                if (keccak256(coords[i]) == keccak256(coord)) still = true;
            }
            if (ok || !still) drops++;
            vm.revertToState(snap);
        }
        acct; // silence
    }

    function test_etherfi_removeFor_gasSweep_neverDropsLive() public {
        balances.addSupportedAssetForTest(NATIVE);
        MockWithdrawRequestNFT nft = new MockWithdrawRequestNFT();
        MockLiquidityPool lp = new MockLiquidityPool();
        EtherFiWithdrawalQueueAssistedBalanceAdapter a =
            new EtherFiWithdrawalQueueAssistedBalanceAdapter(address(nft), address(lp), NATIVE, address(balances), address(this));
        nft.setRequest(7, holder, 1 ether, 1 ether, true, 0, false, 0);
        vm.prank(holder);
        a.submit(7);
        bytes memory coord = abi.encode(uint256(7));
        uint256 drops = _sweep(
            address(a), abi.encodeCall(a.removeFor, (holder, coord)), holder, coord, abi.encodeCall(a.coordsOf, (holder))
        );
        assertEq(drops, 0, "ether.fi live request never removable by gas choice");
    }

    function test_nexus_removeFor_gasSweep_neverDropsLive() public {
        MockStakingNFT nft = new MockStakingNFT();
        MockStakingViewer viewer = new MockStakingViewer();
        Mock_ERC20 nxm = _createAndRegisterToken("NXM", 18);
        NexusMutualStakingPoolsAssistedBalanceAdapter a = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this)
        );
        nft.setToken(9, 1, holder);
        viewer.setToken(9, 1, 10 ether, 0, 0);
        vm.prank(holder);
        a.submit(9);
        bytes memory coord = abi.encode(uint256(9));
        uint256 drops = _sweep(
            address(a), abi.encodeCall(a.removeFor, (holder, coord)), holder, coord, abi.encodeCall(a.coordsOf, (holder))
        );
        assertEq(drops, 0, "Nexus live stake never removable by gas choice");
    }

    function test_stakewise_removeFor_gasSweep_neverDropsLive() public {
        balances.addSupportedAssetForTest(NATIVE);
        StakeWiseModelVault vault = new StakeWiseModelVault();
        AuditRegistry registry = new AuditRegistry();
        registry.setVault(address(vault), true);
        StakeWiseV3ExitQueueAssistedBalanceAdapter a = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), 1 days, address(this)
        );
        vault.mint(holder, 10 ether);
        vm.prank(holder);
        uint256 ticket = vault.enterExitQueue(10 ether, holder);
        uint256 ts = block.timestamp;
        vm.prank(holder);
        a.submit(address(vault), ticket, ts);
        bytes memory coord = abi.encode(address(vault), ticket, ts);
        uint256 drops = _sweep(
            address(a), abi.encodeCall(a.removeFor, (holder, coord)), holder, coord, abi.encodeCall(a.coordsOf, (holder))
        );
        assertEq(drops, 0, "StakeWise live request never removable by gas choice");
    }
}

/// @title OWNER_RESERVE (S13): keeper saturation vs the owner's Assistant path — residual quantified.
contract AuditOwnerReserveTest is BalanceAdapterTestBase {
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal keeper = makeAddr("keeper");
    address internal safe_ = makeAddr("safe");
    EtherFiWithdrawalQueueAssistedBalanceAdapter internal a;
    MockWithdrawRequestNFT internal nft;

    function setUp() public override {
        super.setUp();
        balances.addSupportedAssetForTest(NATIVE);
        nft = new MockWithdrawRequestNFT();
        MockLiquidityPool lp = new MockLiquidityPool();
        a = new EtherFiWithdrawalQueueAssistedBalanceAdapter(address(nft), address(lp), NATIVE, address(balances), address(this));
        a.grantRole(a.SUBMITTER_ROLE(), keeper);
    }

    /// @notice Keeper fills 224 third-party dust requests; owner still gets exactly 32 of its own; the 33rd owner
    ///         submit (i.e. the Assistant's requestWithdraw) reverts CoordinateCacheFull until evict.
    function test_keeperSaturation_ownerKeeps32_then_blocked_until_evict() public {
        for (uint256 i = 1; i <= 300; ++i) {
            nft.setRequest(i, safe_, 1, 1, true, 0, false, 0);
        }
        vm.startPrank(keeper);
        for (uint256 i = 1; i <= 224; ++i) {
            a.submitFor(safe_, abi.encode(i));
        }
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, safe_, uint256(224)));
        a.submitFor(safe_, abi.encode(uint256(225)));
        vm.stopPrank();

        vm.startPrank(safe_);
        for (uint256 i = 225; i <= 256; ++i) {
            a.submit(i);
        }
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, safe_, uint256(256)));
        a.submit(257);
        a.evict(abi.encode(uint256(1))); // owner-only recovery
        a.submit(257);
        vm.stopPrank();
        assertEq(a.tokenIdsOf(safe_).length, 256);
    }

    /// @notice Preview O(n^2) dedupe at the cap stays well inside an eth_call budget.
    function test_preview_atCap_gas() public {
        bytes[] memory coords = new bytes[](256);
        for (uint256 i; i < 256; ++i) {
            nft.setRequest(i + 1, safe_, 1 ether, 1 ether, true, 0, false, 0);
            coords[i] = abi.encode(i + 1);
        }
        uint256 g = gasleft();
        INAVCalculator.PositionBalance[] memory p = a.previewPositions(safe_, abi.encode(coords));
        uint256 used = g - gasleft();
        emit log_named_uint("preview(256) gas", used);
        assertEq(p.length, 256);
        assertLt(used, 30_000_000);
    }
}
