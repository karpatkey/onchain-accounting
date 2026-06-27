// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {StakeWiseExitQueueBalanceAdapter} from "src/balances/AssistedBalanceAdapters/StakeWiseExitQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of a StakeWise V3 vault's exit-queue reads. Faithful to the two states that matter:
///         fully-pending (idx == -1, valued via the still-queued shares) and checkpointed (idx >= 0, exitedAssets
///         claimable). To prove the adapter passes an out-of-range index when fully pending — the way the real
///         ExitQueue library returns the full queued shares without reverting — calculateExitedAssets REVERTS if
///         idx < 0 and the caller does not pass type(uint256).max (mirroring `Errors.InvalidCheckpointIndex`).
contract MockStakeWiseVault {
    struct Req {
        uint256 leftShares;
        uint256 exitedAssets;
        bool set;
    }

    mapping(bytes32 => Req) private _req; // key(receiver, ticket, ts) → request
    mapping(uint256 => int256) private _idx; // ticket → checkpoint index
    mapping(uint256 => bool) private _idxSet;
    uint256 public rateWad = 1e18; // 1 share = 1 asset by default
    bool public revertIndex;
    bool public revertCalc;
    bool public revertConvert;

    function setIndex(uint256 ticket, int256 idx) external {
        _idx[ticket] = idx;
        _idxSet[ticket] = true;
    }

    function setRequest(address receiver, uint256 ticket, uint256 ts, uint256 leftShares, uint256 exitedAssets)
        external
    {
        _req[keccak256(abi.encode(receiver, ticket, ts))] = Req(leftShares, exitedAssets, true);
    }

    function clearRequest(address receiver, uint256 ticket, uint256 ts) external {
        delete _req[keccak256(abi.encode(receiver, ticket, ts))];
    }

    function setRate(uint256 r) external {
        rateWad = r;
    }

    function setRevertIndex(bool v) external {
        revertIndex = v;
    }

    function setRevertCalc(bool v) external {
        revertCalc = v;
    }

    function setRevertConvert(bool v) external {
        revertConvert = v;
    }

    function getExitQueueIndex(uint256 ticket) external view returns (int256) {
        require(!revertIndex, "idx revert");
        return _idxSet[ticket] ? _idx[ticket] : int256(0);
    }

    function calculateExitedAssets(address receiver, uint256 ticket, uint256 ts, uint256 queryIdx)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets)
    {
        require(!revertCalc, "calc revert");
        int256 idx = _idxSet[ticket] ? _idx[ticket] : int256(0);
        // Real ExitQueue: a valid small index for a not-yet-checkpointed position reverts; an out-of-range index
        // early-returns (0,0) for the exited portion, so leftTickets = full queued shares.
        if (idx < 0) require(queryIdx == type(uint256).max, "InvalidCheckpointIndex");
        Req memory r = _req[keccak256(abi.encode(receiver, ticket, ts))];
        if (!r.set) return (0, 0, 0);
        return (r.leftShares, 0, r.exitedAssets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!revertConvert, "convert revert");
        return (shares * rateWad) / 1e18;
    }
}

contract MockVaultsRegistry {
    mapping(address => bool) public vaults;

    function setVault(address v, bool ok) external {
        vaults[v] = ok;
    }
}

/// @title StakeWiseExitQueueBalanceAdapter unit tests
contract StakeWiseExitQueueBalanceAdapterTest is BalanceAdapterTestBase {
    StakeWiseExitQueueBalanceAdapter public adapter;
    MockStakeWiseVault public vault;
    MockVaultsRegistry public registry;

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address holder = makeAddr("holder");
    address other = makeAddr("other");

    uint256 constant TICKET = 12_345;
    uint256 constant TS = 1_700_000_000;

    function setUp() public override {
        super.setUp();
        vault = new MockStakeWiseVault();
        registry = new MockVaultsRegistry();
        registry.setVault(address(vault), true);
        balances.addSupportedAssetForTest(NATIVE);
        // admin = assistant = this test contract, so it can submit positions.
        adapter =
            new StakeWiseExitQueueBalanceAdapter(address(registry), NATIVE, address(balances), address(this), address(this));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseExitQueueBalanceAdapter(address(0), NATIVE, address(balances), address(this), address(this));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseExitQueueBalanceAdapter(address(registry), address(0), address(balances), address(this), address(this));
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseExitQueueBalanceAdapter(address(registry), NATIVE, address(0), address(this), address(this));
    }

    function test_constructor_revertsWhenRegistryNotContract() public {
        vm.expectRevert(bytes("VaultsRegistry must be a contract"));
        new StakeWiseExitQueueBalanceAdapter(makeAddr("eoa"), NATIVE, address(balances), address(this), address(this));
    }

    // ---- Access control / submission ----

    function test_submit_onlyAssistant() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, other, keccak256("ASSISTANT_ROLE")
            )
        );
        adapter.submitPositions(holder, _claimable());
    }

    function test_submit_storesValidPosition_andDedups() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether); // claimable
        adapter.submitPositions(holder, _claimable());
        adapter.submitPositions(holder, _claimable()); // dedup
        StakeWiseExitQueueBalanceAdapter.ExitPosition[] memory cached = adapter.positionsOf(holder);
        assertEq(cached.length, 1);
        assertEq(cached[0].vault, address(vault));
        assertEq(cached[0].positionTicket, TICKET);
        assertEq(cached[0].timestamp, TS);
    }

    function test_submit_skipsVaultNotInRegistry() public {
        registry.setVault(address(vault), false);
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_submit_skipsTupleWithZeroOwed() public {
        // Registered vault, but no exit request set for (holder, TICKET, TS) → owed 0 → skipped.
        vault.setIndex(TICKET, 1);
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_submitPositionsBatch_storesAcrossAccounts() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(other, TICKET + 1, TS, 0, 2 ether);
        address[] memory accounts = new address[](2);
        accounts[0] = holder;
        accounts[1] = other;
        StakeWiseExitQueueBalanceAdapter.ExitPosition[][] memory positions =
            new StakeWiseExitQueueBalanceAdapter.ExitPosition[][](2);
        positions[0] = new StakeWiseExitQueueBalanceAdapter.ExitPosition[](1);
        positions[0][0] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        positions[1] = new StakeWiseExitQueueBalanceAdapter.ExitPosition[](1);
        positions[1][0] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositionsBatch(accounts, positions);
        assertEq(adapter.positionsOf(holder).length, 1);
        assertEq(adapter.positionsOf(other).length, 1);
        (uint256 a1,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        (uint256 a2,) = adapter.getAdapterBalanceForAsset(other, NATIVE);
        assertEq(a1, 1 ether);
        assertEq(a2, 2 ether);
    }

    function test_submitPositionsBatch_revertsOnLengthMismatch() public {
        address[] memory accounts = new address[](2);
        StakeWiseExitQueueBalanceAdapter.ExitPosition[][] memory positions =
            new StakeWiseExitQueueBalanceAdapter.ExitPosition[][](1);
        vm.expectRevert(ArrayLengthMismatch.selector);
        adapter.submitPositionsBatch(accounts, positions);
    }

    function test_clearPosition_absentKey_noop() public {
        // Clearing a never-submitted position is idempotent (no revert, no state change).
        adapter.clearPosition(holder, address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_clearPosition_andClearAccount() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 2 ether);
        StakeWiseExitQueueBalanceAdapter.ExitPosition[] memory two =
            new StakeWiseExitQueueBalanceAdapter.ExitPosition[](2);
        two[0] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        two[1] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositions(holder, two);
        adapter.clearPosition(holder, address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 1);
        assertEq(adapter.positionsOf(holder)[0].positionTicket, TICKET + 1);
        adapter.clearAccount(holder);
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    // ---- Valuation ----

    function test_claimable_usesExitedAssets() public {
        vault.setIndex(TICKET, 1465);
        vault.setRequest(holder, TICKET, TS, 0, 4_999_000_000_000_000_000); // left 0, exitedAssets ~5 ETH
        adapter.submitPositions(holder, _claimable());
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4_999_000_000_000_000_000);
        assertEq(d, false);
    }

    function test_fullyPending_valuesQueuedSharesViaConvertToAssets() public {
        // idx == -1 (not yet checkpointed). Adapter must pass type(uint256).max (else the mock reverts).
        vault.setIndex(TICKET, -1);
        vault.setRate(0.98e18); // 1 share = 0.98 assets
        vault.setRequest(holder, TICKET, TS, 10 ether, 0); // 10 shares queued, nothing exited
        adapter.submitPositions(holder, _claimable());
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 9.8 ether); // convertToAssets(10) at 0.98
    }

    function test_partiallyExited_sumsExitedPlusQueued() public {
        vault.setIndex(TICKET, 7);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 3 ether, 2 ether); // 3 shares left + 2 ETH exited
        adapter.submitPositions(holder, _claimable());
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 5 ether); // 2 exited + convertToAssets(3) at 1.0
    }

    function test_wrongReceiver_dropped() public {
        // Position belongs to `other`; submitting it under `holder` → calculateExitedAssets(holder,…) == 0 → skip.
        vault.setIndex(TICKET, 1);
        vault.setRequest(other, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.positionsOf(holder).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_claimedAfterSubmit_dropped_doesNotRevert() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        vault.clearRequest(holder, TICKET, TS); // claimed → request deleted
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_aggregatesAcrossPositions() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 3 ether);
        StakeWiseExitQueueBalanceAdapter.ExitPosition[] memory two =
            new StakeWiseExitQueueBalanceAdapter.ExitPosition[](2);
        two[0] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        two[1] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositions(holder, two);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4 ether);
    }

    // ---- never-revert guarantee (try/catch branches) ----

    function test_getExitQueueIndexReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        vault.setRevertIndex(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_calculateExitedAssetsReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        vault.setRevertCalc(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_convertToAssetsReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, -1);
        vault.setRequest(holder, TICKET, TS, 5 ether, 0); // pending → needs convertToAssets
        adapter.submitPositions(holder, _claimable());
        vault.setRevertConvert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_submit_capsAtMaxPositions() public {
        uint256 cap = adapter.MAX_POSITIONS();
        StakeWiseExitQueueBalanceAdapter.ExitPosition[] memory many =
            new StakeWiseExitQueueBalanceAdapter.ExitPosition[](cap + 5);
        for (uint256 i = 0; i < cap + 5; i++) {
            vault.setIndex(i + 1, 1);
            vault.setRequest(holder, i + 1, TS, 0, 1 ether);
            many[i] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), i + 1, TS);
        }
        adapter.submitPositions(holder, many);
        assertEq(adapter.positionsOf(holder).length, cap, "cache must be capped at MAX_POSITIONS");
    }

    // ---- Positions / identity ----

    function test_getAdapterPositions_identity() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].isDebt, false);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].balanceAsset.asset, NATIVE);
        assertEq(p[0].protocolId, ProtocolIds.STAKEWISE_EXIT);
        assertEq(p[0].positionId, "");
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
    }

    function test_getAdapterBalances_shape() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], NATIVE);
        assertEq(amounts[0], 2 ether);
        assertEq(isDebt[0], false);
        // Zero owed → empty arrays.
        (address[] memory a2,,) = adapter.getAdapterBalances(other);
        assertEq(a2.length, 0);
    }

    function test_getAdapterPositions_assetFilterMatchesUnderlying() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, NATIVE);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].balanceAsset.asset, NATIVE);
    }

    function test_getAdapterPositions_assetFilterMismatch_empty() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.getAdapterPositions(holder, address(0xdead)).length, 0);
    }

    function test_getAdapterPositions_zeroOwed_empty() public view {
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], NATIVE);
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceStillOwed() public {
        // Fresh NAV harness that does NOT register the native sentinel.
        BalancesHarness freshNav = new BalancesHarness();
        StakeWiseExitQueueBalanceAdapter a2 = new StakeWiseExitQueueBalanceAdapter(
            address(registry), NATIVE, address(freshNav), address(this), address(this)
        );
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        a2.submitPositions(holder, _claimable());
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0); // dropped: underlying not registered
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 1 ether);
    }

    function _claimable() internal view returns (StakeWiseExitQueueBalanceAdapter.ExitPosition[] memory p) {
        p = new StakeWiseExitQueueBalanceAdapter.ExitPosition[](1);
        p[0] = StakeWiseExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
    }
}
