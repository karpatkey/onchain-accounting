// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter,
    IEtherFiWithdrawRequestNFT
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {AssistedBalanceAdapter} from "src/balances/AssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

    function setRevertGetRequest(bool v) external {
        revertGetRequest = v;
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
        return _claimable[id];
    }

    function isFinalized(uint256 id) external view returns (bool) {
        return _finalized[id];
    }

    function isValid(uint256 id) external view returns (bool) {
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

/// @title EtherFiWithdrawalQueueAssistedBalanceAdapter unit tests
contract EtherFiWithdrawalQueueAssistedBalanceAdapterTest is BalanceAdapterTestBase {
    EtherFiWithdrawalQueueAssistedBalanceAdapter public adapter;
    MockWithdrawRequestNFT public nft;
    MockLiquidityPool public lp;

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address holder = makeAddr("holder");
    address other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        nft = new MockWithdrawRequestNFT();
        lp = new MockLiquidityPool();
        balances.addSupportedAssetForTest(NATIVE);
        // admin = assistant = this test contract, so it can submit ids.
        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), address(this), address(this)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(0), address(lp), NATIVE, address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroLp() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(0), NATIVE, address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), address(0), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "WithdrawRequestNFT"));
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            makeAddr("eoa"), address(lp), NATIVE, address(balances), address(this), address(this)
        );
    }

    // ---- Access control / submission ----

    function test_submit_onlyAssistantRole() public {
        uint256[] memory ids = _ids(1);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, other, keccak256("ASSISTANT_ROLE")
            )
        );
        adapter.submitTokenIds(holder, ids);
    }

    function test_assistantRole_grantedToConstructorArg() public view {
        assertTrue(adapter.hasRole(adapter.ASSISTANT_ROLE(), address(this)));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adapter.hasRole(adapter.ASSISTANT_ROLE(), other));
    }

    function test_admin_canGrantAssistantRole() public {
        // A fresh adapter with `this` as admin only (no initial assistant); `other` is granted later by the admin.
        EtherFiWithdrawalQueueAssistedBalanceAdapter a2 = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), address(this), address(0)
        );
        bytes32 role = a2.ASSISTANT_ROLE();
        assertFalse(a2.hasRole(role, other));
        a2.grantRole(role, other);
        assertTrue(a2.hasRole(role, other));

        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        vm.prank(other);
        a2.submitTokenIds(holder, _ids(1));
        assertEq(a2.tokenIdsOf(holder).length, 1);
    }

    function test_submit_storesOwnedId_andDedups() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        uint256[] memory ids = _ids(1);
        adapter.submitTokenIds(holder, ids);
        adapter.submitTokenIds(holder, ids); // dedup
        uint256[] memory cached = adapter.tokenIdsOf(holder);
        assertEq(cached.length, 1);
        assertEq(cached[0], 1);
    }

    /// @notice Writes are fail-loud: submitting an id not owned by the account reverts NotTokenOwner (matching the
    ///         sibling assisted NFT-id adapters) rather than silently dropping it.
    function test_submit_revertsOnNonOwnedId() public {
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, holder, uint256(1)));
        adapter.submitTokenIds(holder, _ids(1));
        assertEq(adapter.tokenIdsOf(holder).length, 0); // nothing stored — the whole submit reverted
    }

    function test_clearTokenId_andClearAccount() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        nft.setRequest(2, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        adapter.submitTokenIds(holder, ids);
        adapter.clearTokenId(holder, 1);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        adapter.clearAccount(holder);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    // ---- Valuation ----

    function test_finalized_usesGetClaimableAmount() public {
        nft.setRequest(1, holder, 5 ether, 5 ether, true, 0, true, 4_999_000_000_000_000_000);
        adapter.submitTokenIds(holder, _ids(1));
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4_999_000_000_000_000_000);
        assertEq(d, false);
    }

    function test_pending_minOfEEthAndShare_minusFee() public {
        // amountOfEEth = 10, shareValue = 9.8 (rate 0.98), fee = 0.1 → min(10,9.8) - 0.1 = 9.7
        lp.setRate(0.98e18);
        nft.setRequest(1, holder, 10 ether, 10 ether, true, uint32(0.1e9), false, 0);
        adapter.submitTokenIds(holder, _ids(1));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 9.7 ether);
    }

    function test_pending_feeExceedsGross_clampsZero() public {
        nft.setRequest(1, holder, 1, 1, true, uint32(1e9), false, 0); // gross 1 wei, fee 1e9 gwei (1 ether) >> gross
        adapter.submitTokenIds(holder, _ids(1));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_invalidRequest_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, false, 0, true, 1 ether); // isValid=false
        adapter.submitTokenIds(holder, _ids(1));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_transferredAway_dropped() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submitTokenIds(holder, _ids(1));
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether); // now owned by other
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_burned_dropped_doesNotRevert() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submitTokenIds(holder, _ids(1));
        nft.burn(1); // ownerOf now reverts
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_aggregatesAcrossIds() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 3 ether);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        adapter.submitTokenIds(holder, ids);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4 ether);
    }

    // ---- Positions / identity ----

    /// @dev Asserts a per-request leg: the static breadcrumb is `["Withdrawal Queue", "eETH"]` (positionId-derived, no
    ///      ephemeral id), and the tokenId rides in the typed `positionInstanceId` (bytes32(uint256 tokenId)).
    function _assertRequestLeg(INAVCalculator.PositionBalance memory leg) internal view {
        string[] memory labels = adapter.positionLabels(leg.positionId);
        assertEq(labels.length, 2, "static breadcrumb = [category]");
        assertEq(labels[0], "Withdrawal Queue");
        assertEq(labels[1], "eETH");
        assertTrue(leg.positionInstanceId != bytes32(0), "positionInstanceId carries the tokenId");
    }

    function test_getAdapterPositions_identity() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether); // finalized → claimable
        adapter.submitTokenIds(holder, _ids(1));
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
        // A single pending (not finalized) request → one locked leg.
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, false, 0); // pending; valued via amountForShare (rate 1)
        adapter.submitTokenIds(holder, _ids(1));
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertTrue(p[0].isLocked, "pending request -> locked leg");
        assertEq(p[0].positionId, abi.encode(adapter.WITHDRAW_REQUEST_NFT()));
        _assertRequestLeg(p[0]);
    }

    function test_getAdapterPositions_perRequestLegs_mixedClaimableAndLocked() public {
        // One finalized (claimable) + one pending (locked) request → two per-request legs sharing the static
        // positionId, each carrying its own tokenId in the typed positionInstanceId.
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether); // finalized → claimable 2
        nft.setRequest(2, holder, 1 ether, 1 ether, true, 0, false, 0); // pending → locked 1 (rate 1)
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        adapter.submitTokenIds(holder, ids);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2, "two requests -> two per-request legs");

        bytes memory expectedId = abi.encode(adapter.WITHDRAW_REQUEST_NFT());
        uint256 claimable;
        uint256 locked;
        bool sawClaimable;
        bool sawLocked;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, NATIVE);
            assertEq(p[i].balanceAdapter, address(adapter));
            assertFalse(p[i].isDebt);
            assertEq(p[i].positionId, expectedId, "both legs share the static positionId");
            _assertRequestLeg(p[i]);
            if (p[i].isLocked) {
                locked += p[i].amount;
                sawLocked = true;
            } else {
                claimable += p[i].amount;
                sawClaimable = true;
            }
        }
        assertTrue(sawClaimable && sawLocked, "one claimable + one locked leg present");
        assertEq(claimable, 2 ether, "claimable = finalized getClaimableAmount");
        assertEq(locked, 1 ether, "locked = pending estimate");
        // Distinct requests carry distinct positionInstanceIds.
        assertTrue(
            p[0].positionInstanceId != p[1].positionInstanceId, "each request leg has a distinct positionInstanceId"
        );

        // NAV-total invariance: sum of per-request legs == the aggregate balance.
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(claimable + locked, agg, "sum of legs == aggregate");
    }

    function test_getAdapterPositions_twoSameStateRequests_twoLegs_sumToAggregate() public {
        // Two owned cached ids of the SAME (finalized) state → two distinct labelled legs summing to the aggregate.
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether); // finalized → claimable 2
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 3 ether); // finalized → claimable 3
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        adapter.submitTokenIds(holder, ids);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2, "same-state requests still emit one leg each (no aggregation)");

        bytes memory expectedId = abi.encode(adapter.WITHDRAW_REQUEST_NFT());
        uint256 sum;
        for (uint256 i = 0; i < p.length; i++) {
            assertFalse(p[i].isLocked, "finalized request -> claimable leg");
            assertEq(p[i].positionId, expectedId, "legs share the static positionId");
            _assertRequestLeg(p[i]);
            sum += p[i].amount;
        }
        // Distinct ids → distinct positionInstanceIds even though state is identical.
        assertTrue(p[0].positionInstanceId != p[1].positionInstanceId, "distinct ids -> distinct positionInstanceIds");
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(sum, agg, "sum of legs == aggregate");
        assertEq(sum, 5 ether);
    }

    function test_getAdapterPositions_nonOwnedCachedId_discarded_noLeg() public {
        // One owned id + one id transferred away after caching → only the owned id emits a leg.
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 3 ether);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        adapter.submitTokenIds(holder, ids);
        assertEq(adapter.tokenIdsOf(holder).length, 2, "both ids cached");

        // id 2 is transferred to `other` after caching — reads must discard it (no leg) without reverting.
        nft.setRequest(2, other, 3 ether, 3 ether, true, 0, true, 3 ether);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1, "non-owned cached id is discarded");
        assertEq(p[0].amount, 2 ether, "only the still-owned request is valued");
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));

        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(p[0].amount, agg, "sum of legs == aggregate (discarded id excluded)");
    }

    function test_getAdapterPositions_assetFilterMismatch_empty() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        adapter.submitTokenIds(holder, _ids(1));
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
        // Fresh NAV harness that does NOT register the native sentinel.
        BalancesHarness freshNav = new BalancesHarness();
        EtherFiWithdrawalQueueAssistedBalanceAdapter a2 = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(freshNav), address(this), address(this)
        );
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
        a2.submitTokenIds(holder, _ids(1));
        // getAdapterPositions drops the leg (underlying not registered) — even though owed > 0.
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0);
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 1 ether);
    }

    function test_pending_getRequestReverts_droppedNotReverted() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, false, 0); // pending
        adapter.submitTokenIds(holder, _ids(1));
        nft.setRevertGetRequest(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0); // dropped to 0, scan did not revert
    }

    function test_pending_amountForShareReverts_droppedNotReverted() public {
        nft.setRequest(1, holder, 1 ether, 1 ether, true, 0, false, 0); // pending
        adapter.submitTokenIds(holder, _ids(1));
        lp.setRevert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    /// @notice Writes are fail-loud at the cap: a submitted list longer than MAX_TOKEN_IDS reverts TokenIdCacheFull
    ///         rather than silently dropping the overflow. Submit is replace semantics, so the cap is hit within a
    ///         single list, not by accumulating across calls.
    function test_submit_revertsWhenCacheFull() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        // A single list of exactly MAX_TOKEN_IDS is accepted.
        uint256[] memory ids = new uint256[](cap);
        for (uint256 i = 0; i < cap; i++) {
            nft.setRequest(i + 1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
            ids[i] = i + 1;
        }
        adapter.submitTokenIds(holder, ids);
        assertEq(adapter.tokenIdsOf(holder).length, cap, "cache filled to MAX_TOKEN_IDS");

        // A single list of MAX_TOKEN_IDS + 1 is fail-loud (the cap+1-th add reverts).
        uint256[] memory tooMany = new uint256[](cap + 1);
        for (uint256 i = 0; i < cap + 1; i++) {
            nft.setRequest(i + 1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
            tooMany[i] = i + 1;
        }
        vm.expectRevert(abi.encodeWithSelector(TokenIdCacheFull.selector, holder, cap));
        adapter.submitTokenIds(holder, tooMany);
        // The reverted submit left the prior set intact (the submit reverts atomically, so any partial delta changes
        // roll back with it — the base reconciles as a delta, not a clear-and-readd).
        assertEq(adapter.tokenIdsOf(holder).length, cap, "cache unchanged after the reverted submit");
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
