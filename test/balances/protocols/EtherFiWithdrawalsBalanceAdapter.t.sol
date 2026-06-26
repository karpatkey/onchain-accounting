// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {
    EtherFiWithdrawalsBalanceAdapter,
    IEtherFiWithdrawRequestNFT
} from "src/balances/protocols/EtherFiWithdrawalsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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

/// @title EtherFiWithdrawalsBalanceAdapter unit tests
contract EtherFiWithdrawalsBalanceAdapterTest is BalanceAdapterTestBase {
    EtherFiWithdrawalsBalanceAdapter public adapter;
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
        // owner = this test contract, so it can submit ids.
        adapter =
            new EtherFiWithdrawalsBalanceAdapter(address(nft), address(lp), NATIVE, address(balances), address(this));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalsBalanceAdapter(address(0), address(lp), NATIVE, address(balances), address(this));
    }

    function test_constructor_revertsOnZeroLp() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalsBalanceAdapter(address(nft), address(0), NATIVE, address(balances), address(this));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalsBalanceAdapter(address(nft), address(lp), address(0), address(balances), address(this));
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(bytes("WithdrawRequestNFT must be a contract"));
        new EtherFiWithdrawalsBalanceAdapter(makeAddr("eoa"), address(lp), NATIVE, address(balances), address(this));
    }

    // ---- Ownership / submission ----

    function test_submit_onlyOwner() public {
        uint256[] memory ids = _ids(1);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        adapter.submitTokenIds(holder, ids);
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

    function test_submit_skipsNonOwnedId() public {
        nft.setRequest(1, other, 1 ether, 1 ether, true, 0, true, 1 ether);
        adapter.submitTokenIds(holder, _ids(1));
        assertEq(adapter.tokenIdsOf(holder).length, 0); // not owned by holder → not stored
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
        nft.setRequest(1, holder, 1, 1, true, uint32(1e9), false, 0); // gross 1 wei, fee 1 gwei
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

    function test_getAdapterPositions_identity() public {
        nft.setRequest(1, holder, 2 ether, 2 ether, true, 0, true, 2 ether);
        adapter.submitTokenIds(holder, _ids(1));
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].isDebt, false);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].balanceAsset.asset, NATIVE);
        assertEq(p[0].protocolId, ProtocolIds.ETHERFI_WITHDRAWAL);
        assertEq(p[0].positionId, "");
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
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
        EtherFiWithdrawalsBalanceAdapter a2 =
            new EtherFiWithdrawalsBalanceAdapter(address(nft), address(lp), NATIVE, address(freshNav), address(this));
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

    function test_submit_capsAtMaxTokenIds() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        uint256[] memory ids = new uint256[](cap + 5);
        for (uint256 i = 0; i < cap + 5; i++) {
            nft.setRequest(i + 1, holder, 1 ether, 1 ether, true, 0, true, 1 ether);
            ids[i] = i + 1;
        }
        adapter.submitTokenIds(holder, ids);
        assertEq(adapter.tokenIdsOf(holder).length, cap, "cache must be capped at MAX_TOKEN_IDS");
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
