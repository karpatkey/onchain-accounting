// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    IEtherFiWithdrawRequestNFT
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of ether.fi's WithdrawRequestNFT. ownerOf reverts for unset/burned ids (ERC721 semantics).
contract MockWithdrawRequestNFT {
    mapping(uint256 => address) private _owner;
    mapping(uint256 => IEtherFiWithdrawRequestNFT.WithdrawRequest) private _req;
    mapping(uint256 => bool) private _finalized;
    mapping(uint256 => uint256) private _claimable;
    bool public revertGetRequest;
    bool public revertIsValid;
    bool public revertIsFinalized;
    bool public revertGetClaimable;

    function setRevertGetRequest(bool v) external {
        revertGetRequest = v;
    }

    function setRevertIsValid(bool v) external {
        revertIsValid = v;
    }

    function setRevertIsFinalized(bool v) external {
        revertIsFinalized = v;
    }

    function setRevertGetClaimable(bool v) external {
        revertGetClaimable = v;
    }

    function setRequest(
        uint256 id,
        address owner_,
        uint96 amountOfEEth,
        uint96 shareOfEEth,
        bool valid,
        uint32 feeGwei,
        bool finalized_,
        uint256 claimable_
    ) external {
        _owner[id] = owner_;
        _req[id] = IEtherFiWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, valid, feeGwei);
        _finalized[id] = finalized_;
        _claimable[id] = claimable_;
    }

    function burn(uint256 id) external {
        delete _owner[id];
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = _owner[id];
        require(o != address(0), "nonexistent");
        return o;
    }

    function getRequest(uint256 id) external view returns (IEtherFiWithdrawRequestNFT.WithdrawRequest memory) {
        require(!revertGetRequest, "getRequest reverted");
        return _req[id];
    }

    function getClaimableAmount(uint256 id) external view returns (uint256) {
        require(!revertGetClaimable, "getClaimableAmount reverted");
        return _claimable[id];
    }

    function isFinalized(uint256 id) external view returns (bool) {
        require(!revertIsFinalized, "isFinalized reverted");
        return _finalized[id];
    }

    function isValid(uint256 id) external view returns (bool) {
        require(!revertIsValid, "isValid reverted");
        return _req[id].isValid;
    }
}

/// @notice Minimal mock of ether.fi's LiquidityPool — `amountForShare` at a settable rate (wei per share, 1e18-scaled).
contract MockLiquidityPool {
    uint256 public rateWad = 1e18; // 1 share = 1 ETH by default
    bool public doRevert;

    function setRate(uint256 r) external {
        rateWad = r;
    }

    function setRevert(bool v) external {
        doRevert = v;
    }

    function amountForShare(uint256 share) external view returns (uint256) {
        require(!doRevert, "amountForShare reverted");
        return (share * rateWad) / 1e18;
    }
}

/// @title EtherFiWithdrawalQueueAssistedBalanceAdapter (wrapper-fed) unit tests
contract EtherFiWithdrawalQueueAssistedBalanceAdapterTest is BalanceAdapterTestBase {
    EtherFiWithdrawalQueueAssistedBalanceAdapter public adapter;
    MockWithdrawRequestNFT public nft;
    MockLiquidityPool public lp;

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address holder = address(this);
    address other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        nft = new MockWithdrawRequestNFT();
        lp = new MockLiquidityPool();
        balances.addSupportedAssetForTest(NATIVE);
        // admin = wrapper = this test contract, so it holds WRAPPER_ROLE and can submit/remove ids.
        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), address(this)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(0), address(lp), NATIVE, address(balances), address(this)
        );
    }

    function test_constructor_revertsOnZeroLp() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(0), NATIVE, address(balances), address(this)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), address(0), address(balances), address(this)
        );
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "WithdrawRequestNFT"));
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            makeAddr("eoa"), address(lp), NATIVE, address(balances), address(this)
        );
    }

    function test_submit_storesOwnedId_andDedups() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        adapter.submit(1); // idempotent
        uint256[] memory cached = adapter.tokenIdsOf(holder);
        assertEq(cached.length, 1);
        assertEq(cached[0], 1);
    }

    /// @notice Writes are fail-loud: submitting an id not owned by the account reverts CoordinateNotOwned.
    function test_submit_revertsOnNonOwnedId() public {
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, uint256(1)));
        adapter.submit(1);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    // ---- remove (WRAPPER_ROLE-gated; requires the request to have been claimed/burned) ----

    /// @notice remove untracks a claimed (burned) request.
    function test_remove_removesClaimedId() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.burn(1); // claimed → ownerOf reverts
        adapter.remove(1);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    /// @notice remove reverts RequestNotClaimed if the request still exists (still owned — not yet claimed).
    function test_remove_revertsOnLiveOwnedId() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, uint256(1)));
        adapter.remove(1);
        assertEq(adapter.tokenIdsOf(holder).length, 1, "cache unchanged after the reverted remove");
    }

    /// @notice remove of an id the caller no longer owns (transferred away) succeeds — it is not the caller's live
    ///         position anymore, so dropping it only under-reports (safe). Only an id still owned BY THE CALLER is
    ///         un-removable (CoordinateStillLive, see {test_remove_revertsOnLiveOwnedId}).
    function test_remove_transferredAway_removable() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether); // transferred away from the caller
        adapter.remove(1);
        assertEq(adapter.tokenIdsOf(holder).length, 0, "no longer the caller's position, so removable");
    }

    // ---- Valuation ----

    function test_finalized_usesGetClaimableAmount() public {
        nft.setRequest(1, holder, 5 ether, 5 ether, true, 0, true, 4_999_000_000_000_000_000);
        adapter.submit(1);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4_999_000_000_000_000_000);
        assertEq(d, false);
    }

    function test_pending_minOfEEthAndShare_minusFee() public {
        // amountOfEEth = 10, shareValue = 9.8 (rate 0.98), fee = 0.1 → min(10,9.8) - 0.1 = 9.7
        lp.setRate(0.98e18);
        nft.setRequest(1, holder, 10 ether, 10 ether, true, uint32(0.1e9), false, 0);
        adapter.submit(1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 9.7 ether);
    }

    function test_pending_feeExceedsGross_clampsZero() public {
        nft.setRequest(1, holder, 1, 1, true, uint32(1e9), false, 0);
        adapter.submit(1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_invalidRequest_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, false, 0, true, 1 ether); // isValid=false
        adapter.submit(1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_transferredAway_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether); // now owned by other
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_burned_dropped_doesNotRevert() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.burn(1); // ownerOf now reverts
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_aggregatesAcrossIds() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 3 ether);
        adapter.submit(1);
        adapter.submit(2);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4 ether);
    }

    // ---- Positions / identity ----

    function _assertRequestLeg(INAVCalculator.PositionBalance memory leg) internal view {
        string[] memory labels = adapter.positionLabels(leg.positionId);
        assertEq(labels.length, 2, "static breadcrumb = [category, symbol]");
        assertEq(labels[0], "Withdrawal Queue");
        assertEq(labels[1], "eETH");
        assertTrue(leg.positionInstanceId != bytes32(0), "positionInstanceId carries the tokenId");
    }

    function test_getAdapterPositions_identity() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether); // finalized → claimable
        adapter.submit(1);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].isDebt, false);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].balanceAsset.asset, NATIVE);
        assertEq(p[0].protocolSubId, ProtocolIds.ETHERFI_WITHDRAWAL);
        assertEq(p[0].protocolId, ProtocolIds.ETHERFI);
        assertEq(p[0].positionId, abi.encode(adapter.WITHDRAW_REQUEST_NFT()));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(p[0].isLocked, "finalized request -> claimable leg");
        _assertRequestLeg(p[0]);
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)), "tokenId rides in positionInstanceId");
    }

    function test_getAdapterPositions_lockedLeg() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, false, 0); // pending; valued via amountForShare (rate 1)
        adapter.submit(1);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertTrue(p[0].isLocked, "pending request -> locked leg");
        _assertRequestLeg(p[0]);
    }

    function test_getAdapterPositions_perRequestLegs_mixedClaimableAndLocked() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether); // finalized → claimable 2
        nft.setRequest(2, holder, 1 ether, 1 ether, true, 0, false, 0); // pending → locked 1 (rate 1)
        adapter.submit(1);
        adapter.submit(2);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2, "two requests -> two per-request legs");

        bytes memory expectedId = abi.encode(adapter.WITHDRAW_REQUEST_NFT());
        uint256 claimable;
        uint256 locked;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, expectedId, "both legs share the static positionId");
            _assertRequestLeg(p[i]);
            if (p[i].isLocked) locked += p[i].amount;
            else claimable += p[i].amount;
        }
        assertEq(claimable, 2 ether);
        assertEq(locked, 1 ether);
        assertTrue(p[0].positionInstanceId != p[1].positionInstanceId, "distinct positionInstanceIds");

        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(claimable + locked, agg, "sum of legs == aggregate");
    }

    function test_getAdapterPositions_nonOwnedCachedId_discarded_noLeg() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 3 ether);
        adapter.submit(1);
        adapter.submit(2);
        nft.setRequest(2, other, 3 ether, 3 ether, true, 0, true, 3 ether); // id 2 transferred away

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1, "non-owned cached id is discarded");
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
    }

    function test_getAdapterPositions_assetFilterMismatch_empty() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        adapter.submit(1);
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

    // ---- Registered-asset + live-read-revert branches (never-revert guarantee) ----

    function test_unregisteredUnderlying_positionsEmpty_butBalanceStillOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        EtherFiWithdrawalQueueAssistedBalanceAdapter a2 = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(freshNav), address(this)
        );
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        a2.submit(1);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0);
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 1 ether);
    }

    function test_pending_getRequestReverts_droppedNotReverted() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, false, 0); // pending
        adapter.submit(1);
        nft.setRevertGetRequest(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_pending_amountForShareReverts_droppedNotReverted() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, false, 0); // pending
        adapter.submit(1);
        lp.setRevert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    /// @notice Writes are fail-loud at the cap: submitting one id past MAX_TOKEN_IDS reverts CoordinateCacheFull.
    function test_submit_revertsWhenCacheFull() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        for (uint256 i = 0; i < cap; i++) {
            nft.setRequest(i + 1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
            adapter.submit(i + 1);
        }
        assertEq(adapter.tokenIdsOf(holder).length, cap, "cache filled to MAX_TOKEN_IDS");

        nft.setRequest(cap + 1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, holder, cap));
        adapter.submit(cap + 1);
        assertEq(adapter.tokenIdsOf(holder).length, cap, "cache unchanged after the reverted submit");
    }

    // ---- Additional constructor guards ----

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(address(nft), address(lp), NATIVE, address(0), address(this));
    }

    function test_constructor_revertsWhenLpNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "LiquidityPool"));
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), makeAddr("eoaLp"), NATIVE, address(balances), address(this)
        );
    }

    function test_constructor_revertsWhenNavNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, makeAddr("eoaNav"), address(this)
        );
    }

    // ---- Events ----

    event CoordSubmitted(address indexed account, uint256 indexed id);
    event CoordCleared(address indexed account, uint256 indexed id);
    event AccountCleared(address indexed account);

    function test_submit_emitsCoordSubmitted() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit CoordSubmitted(holder, 1);
        adapter.submit(1);
    }

    function test_remove_emitsCoordCleared() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.burn(1); // claimed → removable
        vm.expectEmit(true, true, false, true, address(adapter));
        emit CoordCleared(holder, 1);
        adapter.remove(1);
    }

    function test_clearAccount_emitsAndClearsMultiple() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        nft.setRequest(2, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        adapter.submit(2);
        assertEq(adapter.tokenIdsOf(holder).length, 2);
        vm.expectEmit(true, false, false, false, address(adapter));
        emit AccountCleared(holder);
        adapter.clearAccount();
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    // ---- submit / remove edge cases ----

    /// @notice A resubmit of an id the account has since transferred away reverts (ownership re-checked every call).
    function test_submit_resubmitAfterTransfer_reverts() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether); // transferred to other
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, uint256(1)));
        adapter.submit(1);
        assertEq(adapter.tokenIdsOf(holder).length, 1, "prior cache entry preserved");
    }

    /// @notice remove of an id the caller never cached is fail-loud (CoordinateNotCached), keyed on msg.sender.
    function test_remove_uncached_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, holder, uint256(999)));
        adapter.remove(999);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    // ---- IBalanceAdapter getter branches ----

    function test_getAdapterBalanceForAsset_wrongAsset_zero() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, address(0xdead));
        assertEq(amt, 0);
        assertEq(d, false);
    }

    function test_getAdapterBalanceForAsset_zeroAccount_zero() public view {
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(address(0), NATIVE);
        assertEq(amt, 0);
        assertEq(d, false);
    }

    function test_getAdapterBalances_emptyWhenZero() public view {
        (address[] memory a, uint256[] memory amts, bool[] memory d) = adapter.getAdapterBalances(holder);
        assertEq(a.length, 0);
        assertEq(amts.length, 0);
        assertEq(d.length, 0);
    }

    function test_getAdapterBalances_reportsTotal() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 3 ether);
        adapter.submit(1);
        adapter.submit(2);
        (address[] memory a, uint256[] memory amts, bool[] memory d) = adapter.getAdapterBalances(holder);
        assertEq(a.length, 1);
        assertEq(a[0], NATIVE);
        assertEq(amts[0], 4 ether);
        assertEq(d[0], false);
    }

    function test_getAdapterPositions_zeroAccount_empty() public view {
        assertEq(adapter.getAdapterPositions(address(0), address(0)).length, 0);
    }

    function test_getAdapterPositions_assetFilterUnderlying_returnsLegs() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        adapter.submit(1);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, NATIVE);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
    }

    /// @notice A cached id that values to 0 (e.g. invalidated) emits no leg; owned ones still do.
    function test_getAdapterPositions_zeroOwedLeg_skipped() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether); // valued → leg
        nft.setRequest(2, holder, 1 ether, 1 ether, false, 0, true, 1 ether); // owned but invalid → owed 0 → skipped
        adapter.submit(1);
        adapter.submit(2);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1, "zero-owed (invalid) leg skipped");
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
    }

    // ---- Remaining live-read try/catch branches (never-revert) ----

    function test_finalized_getClaimableAmountReverts_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether); // finalized
        adapter.submit(1);
        nft.setRevertGetClaimable(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_isFinalizedReverts_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, false, 0);
        adapter.submit(1);
        nft.setRevertIsFinalized(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_isValidReverts_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submit(1);
        nft.setRevertIsValid(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    /// @dev Configuration-view probe: a consumer describing configuration has no positionId, so it can only call
    ///      `positionLabels("")`. This adapter's breadcrumb is positionId-independent and it emits a single
    ///      positionId (`abi.encode(WITHDRAW_REQUEST_NFT)`; the per-request NFT id rides in `positionInstanceId`),
    ///      so the probe answers with the full constant breadcrumb. What this pins is that the probe never
    ///      silently collapses to `[]` — a positionId-derived leaf added later must still return at least the
    ///      `"Withdrawal Queue"` category per the `_labels` empty-leaf convention.
    ///
    ///      Note this adapter carries the `IAssistedBalanceAdapter` marker yet answers with a CONSTANT breadcrumb.
    ///      That is why the marker cannot be used to infer "labels are per-position" — see the corresponding note
    ///      in the Nexus suite.
    function test_positionLabels_emptyProbe_returnsTheConstantShape() public view {
        string[] memory labels = adapter.positionLabels("");
        assertEq(labels.length, 2);
        assertEq(labels[0], "Withdrawal Queue");
        assertEq(labels[1], "eETH");
    }
}
