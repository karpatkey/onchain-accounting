// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice A minimal SECOND member of the attested family, written the way a new member plausibly would be.
/// @dev Deliberately keeps its own per-`(account, asset)` bookkeeping and overrides {_deleteMemberState} to drop
///      ONLY that — with no `super` call and no deletion of the base's own record. That is the shape that used to
///      wedge the cache permanently, and the shape this file exists to keep safe.
contract ProbeMember is AttestedValueCache {
    bytes32 public epoch = keccak256("E1");
    mapping(address => mapping(address => uint256)) public memberState;

    constructor(address nav_, address admin_) AttestedValueCache(nav_, admin_) {}

    function setEpoch(bytes32 e) external {
        epoch = e;
    }

    /// @dev Test feed. A real member would verify a proof here before calling `_upsertAttestation`.
    function feed(address account, address asset, uint256 value) external {
        memberState[account][asset] = value;
        _upsertAttestation(account, asset, value, epoch);
    }

    function _liveEpoch() internal view override returns (bytes32) {
        return epoch;
    }

    function _liveValue(address, address, uint256 attestedValue) internal pure override returns (uint256) {
        return attestedValue;
    }

    function _maxAssetsPerAccount() internal pure override returns (uint256) {
        return 4;
    }

    /// @dev Drops ONLY the member's own state. No `super` — and it must still be impossible to desynchronise the
    ///      base's record from its enumeration.
    function _deleteMemberState(address account, address asset) internal override {
        delete memberState[account][asset];
    }

    function _verifyPreviewPayload(bytes32, address, bytes calldata)
        internal
        view
        virtual
        override
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        return (new address[](0), new uint256[](0), new bytes[](0));
    }

    function _assetLegs(address, address, INAVCalculator.Asset memory meta, uint256 liveValue, uint256, bytes memory)
        internal
        view
        virtual
        override
        returns (INAVCalculator.PositionBalance[] memory legs)
    {
        legs = new INAVCalculator.PositionBalance[](1);
        legs[0] = _row(meta, liveValue, abi.encode(address(this)), bytes32(0));
    }

    function _protocolBrand() internal pure override returns (bytes32) {
        return keccak256("probe");
    }

    function _protocolId() internal pure override returns (bytes32) {
        return keccak256("probe");
    }

    function _protocolSubId() internal pure override returns (bytes32) {
        return keccak256("probe");
    }

    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Rewards;
    }

    function protocolName() external pure returns (string memory) {
        return "Probe";
    }

    function positionLabels(bytes calldata) external pure override returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Probe";
    }
}

/// @notice A member whose `_assetLegs` emits MORE legs than its `_cachedLegCount` declares.
/// @dev The realistic shape: a second member emitting a claimable leg plus a still-locked leg per asset (what the
///      sibling StakeWise assisted adapter does) while leaving the base's default `_cachedLegCount` of 1. In the
///      pre-refactor monolith the buffer size and the legs were derived from ONE expression and could not
///      disagree; the extraction split them into two independent hooks, so they can.
contract OverEmittingMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _assetLegs(address, address, INAVCalculator.Asset memory meta, uint256 liveValue, uint256, bytes memory)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory legs)
    {
        legs = new INAVCalculator.PositionBalance[](2); // declares 1 (inherited default), emits 2
        legs[0] = _row(meta, liveValue, abi.encode(address(this)), bytes32(0));
        legs[1] = _row(meta, liveValue, abi.encode(address(this)), keccak256("second"));
    }
}

/// @notice Over-emits for ONE asset and is perfectly correct for the other — the shape that exposes whether the
///         leg budget is per-asset or account-wide.
contract SelectiveOverEmitter is ProbeMember {
    address public greedy;

    constructor(address nav_, address admin_, address greedy_) ProbeMember(nav_, admin_) {
        greedy = greedy_;
    }

    function _assetLegs(
        address a,
        address asset,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256 v,
        bytes memory c
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        if (asset != greedy) return super._assetLegs(a, asset, meta, liveValue, v, c);
        legs = new INAVCalculator.PositionBalance[](3); // declares 1, emits 3
        for (uint256 i; i < 3; ++i) {
            legs[i] = _row(meta, liveValue, abi.encode(address(this)), bytes32(i));
        }
    }
}

/// @notice Returns ONE preview entry while `_assetLegs` emits two — an under-declaring member on the fail-loud path.
contract PreviewOverEmitter is OverEmittingMember {
    address public asset;

    constructor(address nav_, address admin_, address asset_) OverEmittingMember(nav_, admin_) {
        asset = asset_;
    }

    function _verifyPreviewPayload(bytes32, address, bytes calldata)
        internal
        view
        override
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
    {
        assets = new address[](1);
        values = new uint256[](1);
        ctxs = new bytes[](1);
        assets[0] = asset;
        values[0] = 100 ether;
        ctxs[0] = "";
    }
}

/// @notice Returns arrays of mismatched length from the preview payload hook.
contract RaggedPreviewMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _verifyPreviewPayload(bytes32, address, bytes calldata)
        internal
        view
        override
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
    {
        assets = new address[](2); // ragged: 2 assets, 1 value, 1 ctx
        values = new uint256[](1);
        ctxs = new bytes[](1);
    }
}

/// @notice Family-level tests for {AttestedValueCache}, exercised through a SECOND member rather than through
///         Merkl. The base exists to be inherited, so the properties that matter are the ones a future member
///         could break — and those are invisible in a suite that only ever instantiates the first member.
contract AttestedValueCacheTest is BalanceAdapterTestBase {
    ProbeMember internal probe;
    Mock_ERC20 internal tok;

    function setUp() public override {
        super.setUp();
        probe = new ProbeMember(address(balances), admin);
        bytes32 submitterRole = probe.SUBMITTER_ROLE();
        vm.prank(admin);
        probe.grantRole(submitterRole, address(this));
        tok = new Mock_ERC20("TOK", 18);
        balances.addSupportedAssetForTest(address(tok));
    }

    /// @notice A member that deletes ONLY its own state on a clear must NOT be able to leave the base's record
    ///         behind — the record and the enumeration have to stay in lockstep.
    /// @dev    THE REGRESSION. When `_deleteAttestation` was `internal virtual` and its docstring claimed
    ///         "Default: nothing", a member overriding it without `super` left `attestations[a][t].epoch != 0`
    ///         while `clearAttestation` still popped the asset off `_assetList`. Re-admission then computed
    ///         `isNew = a.epoch == bytes32(0)` -> FALSE and never re-pushed, so the pair became permanently
    ///         invisible to `getAdapterPositions`/`getAdapterBalances` (which drive off the list) while
    ///         `getAdapterBalanceForAsset` still reported it (it reads the mapping) — the two `IBalanceAdapter`
    ///         surfaces disagreeing, unrecoverably, because the clear that would reset it now reverts
    ///         `AttestationStillLive`.
    ///
    ///         The fix is structural, not documentary: `_deleteAttestation` is `private` and always erases the
    ///         base record, and members extend it through `_deleteMemberState`, whose default really is nothing.
    ///         THE DISCRIMINATING MUTATION: make `_deleteAttestation` `internal virtual` again and have
    ///         `ProbeMember` override it without `super` — this test fails on every assertion below.
    function test_memberDeletingOnlyItsOwnState_cannotDesyncTheBaseRecord() public {
        probe.feed(alice, address(tok), 100 ether);
        assertEq(probe.assetsOf(alice).length, 1, "precondition: enumerated once");

        // Rotate the epoch so the entry reads 0, then GC it — exactly what an operator's automatic pass does.
        probe.setEpoch(keccak256("E2"));
        probe.clearAttestation(alice, address(tok));

        // The base's own record must be gone, not merely delisted.
        (uint256 value, bytes32 epoch,) = probe.attestations(alice, address(tok));
        assertEq(epoch, bytes32(0), "base record erased, so the presence sentinel is clear");
        assertEq(value, 0, "and its value with it");
        assertEq(probe.assetsOf(alice).length, 0, "delisted");
        assertEq(probe.memberState(alice, address(tok)), 0, "member state dropped in lockstep");

        // Re-admission under the live epoch must re-enumerate rather than silently skip the push.
        probe.feed(alice, address(tok), 50 ether);
        assertEq(probe.assetsOf(alice).length, 1, "re-admitted and RE-ENUMERATED");

        // The two IBalanceAdapter surfaces must agree — the wedge made them disagree.
        (uint256 direct,) = probe.getAdapterBalanceForAsset(alice, address(tok));
        (, uint256[] memory amounts,) = probe.getAdapterBalances(alice);
        assertEq(direct, 50 ether, "per-asset read");
        assertEq(amounts.length, 1, "enumerated read sees it too");
        assertEq(amounts[0], 50 ether, "and agrees on the amount");
        assertEq(probe.getAdapterPositions(alice, address(0)).length, 1, "and it reaches NAV");
    }

    /// @notice `clearAccount` must erase every element's base record too, not just empty the list.
    /// @dev The bulk path clears the enumeration wholesale rather than element-by-element, so it is the likelier
    ///      place for a record to be orphaned.
    function test_clearAccount_erasesEveryBaseRecordNotJustTheList() public {
        Mock_ERC20 tok2 = new Mock_ERC20("TOK2", 18);
        balances.addSupportedAssetForTest(address(tok2));
        probe.feed(alice, address(tok), 10 ether);
        probe.feed(alice, address(tok2), 20 ether);

        probe.setEpoch(keccak256("E2"));
        probe.clearAccount(alice);

        assertEq(probe.assetsOf(alice).length, 0, "list emptied");
        (, bytes32 e1,) = probe.attestations(alice, address(tok));
        (, bytes32 e2,) = probe.attestations(alice, address(tok2));
        assertEq(e1, bytes32(0), "first record erased");
        assertEq(e2, bytes32(0), "second record erased");

        // Both must be re-admittable and re-enumerated.
        probe.feed(alice, address(tok), 1 ether);
        probe.feed(alice, address(tok2), 2 ether);
        assertEq(probe.assetsOf(alice).length, 2, "both re-enumerated");
    }

    /// @notice Every leg the base builds is a CREDIT. This is the precondition the per-asset DROP depends on.
    /// @dev    The base's `catch` discards a failing asset rather than re-raising, and that is licensed ONLY
    ///         because a dropped credit leg can just make NAV smaller. `AssistedCoordCache` re-raises instead,
    ///         precisely because a future member of THAT family could emit a debt leg, where a silent drop would
    ///         make NAV LARGER — the one direction forbidden here. Until now the licence was carried entirely in
    ///         prose; this pins the half that IS mechanical: `_row`, the base's only leg constructor, never sets
    ///         `isDebt` or `isLocked`. The other half stays a review rule, because nothing forces a member to
    ///         build its legs through `_row` — a member that emits debt MUST override `_collectLegs` to raise.
    ///         THE DISCRIMINATING MUTATION: set `row.isDebt = true` in `_row` and this fails.
    function test_baseLegConstructor_neverEmitsDebt() public {
        probe.feed(alice, address(tok), 100 ether);
        INAVCalculator.PositionBalance[] memory positions = probe.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 1, "precondition: one leg");
        assertFalse(positions[0].isDebt, "the drop licence depends on this being credit-only");
        assertFalse(positions[0].isLocked, "and on isLocked defaulting false");
        assertEq(positions[0].balanceAdapter, address(probe), "balanceAdapter is always address(this)");
    }

    /// @notice An over-emitting asset must NOT consume a well-behaved neighbour's leg budget.
    /// @dev    THE REGRESSION, and the one my previous fix got wrong. The first bound was written against the
    ///         ACCOUNT-WIDE scratch buffer (`count == tmp.length`), so the greedy asset simply took the slots
    ///         reserved for the assets after it, and those lost ALL their legs — while the docstring, ADR 0022 and
    ///         the single-asset test all claimed "only the surplus". It also made the adapter answer two different
    ///         ways for the same account: the FILTERED read `getAdapterPositions(a, honest)` returned the leg
    ///         (because the filter makes `cap == 1`) while the unfiltered read omitted it.
    ///
    ///         A single-asset fixture cannot see any of that, which is why this one seeds TWO with the greedy one
    ///         FIRST. THE DISCRIMINATING MUTATION: restore the bound to `if (count == tmp.length) break;` and the
    ///         honest asset's leg disappears.
    function test_overEmittingAsset_doesNotStarveAWellBehavedNeighbour() public {
        Mock_ERC20 honest = new Mock_ERC20("HONEST", 18);
        balances.addSupportedAssetForTest(address(honest));
        SelectiveOverEmitter m = new SelectiveOverEmitter(address(balances), admin, address(tok));
        bytes32 submitterRole = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(submitterRole, address(this));
        m.feed(alice, address(tok), 100 ether); // greedy, enumerated FIRST
        m.feed(alice, address(honest), 777 ether);

        INAVCalculator.PositionBalance[] memory positions = m.getAdapterPositions(alice, address(0));

        assertEq(positions.length, 2, "one leg each: greedy capped at its declared 1, honest keeps its own");
        bool sawHonest;
        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].balanceAsset.asset == address(honest)) {
                sawHonest = true;
                assertEq(positions[i].amount, 777 ether, "and at the right amount");
            }
        }
        assertTrue(sawHonest, "the well-behaved neighbour must survive its greedy predecessor");

        // The filtered and unfiltered reads must agree — they did not under the account-wide bound.
        assertEq(m.getAdapterPositions(alice, address(honest)).length, 1, "filtered read agrees with unfiltered");
    }

    /// @notice The PREVIEW is fail-loud by contract, so an under-declaring member must revert there, not truncate.
    /// @dev    The cache path's silent drop is licensed by the NAV read's fail-open behaviour — losing a leg beats
    ///         losing the account's whole NAV. The preview has neither that licence nor that risk: it is the
    ///         caller's own `eth_call`. Vigilo measured that deleting the old silent bound here left the entire
    ///         suite green, i.e. it was asserted by nothing.
    ///         THE DISCRIMINATING MUTATION: drop the `count + legs.length > tmp.length` revert and this passes.
    function test_previewUnderDeclaringMember_failsLoudRatherThanTruncating() public {
        PreviewOverEmitter over = new PreviewOverEmitter(address(balances), admin, address(tok));
        vm.expectRevert(InvalidArguments.selector);
        over.previewPositions(alice, abi.encode(uint256(1)));
    }

    /// @notice Ragged arrays out of `_verifyPreviewPayload` must fail loud and attributably.
    /// @dev    Also asserted by nothing until now (Vigilo mutation-verified: deleting the guard left 98/98 green).
    ///         THE DISCRIMINATING MUTATION: drop the length check and this reverts with a bare Panic instead.
    function test_previewRaggedArrays_revertAttributably() public {
        RaggedPreviewMember ragged = new RaggedPreviewMember(address(balances), admin);
        vm.expectRevert(InvalidArguments.selector);
        ragged.previewPositions(alice, abi.encode(uint256(1)));
    }

    /// @notice A member that emits more legs than its `_cachedLegCount` declares must lose only the SURPLUS legs —
    ///         never the whole adapter.
    /// @dev    THE REGRESSION. The scratch buffer is sized from `_cachedLegCount` while the legs come from the
    ///         unrelated `_assetLegs`, so the two can disagree once they are separate hooks. Writing past the
    ///         buffer raises Panic 0x32 in `_collectLegs`' OWN frame — outside the per-asset `try`, which only
    ///         wraps the external call — so the per-asset drop arm cannot absorb it. It bubbles out of
    ///         `getAdapterPositions`; `PriceFeedLib._getAdapterPositions` fails OPEN on a plain revert, so the
    ///         adapter's ENTIRE leg set silently leaves NAV for EVERY account, with no error and green CI if the
    ///         member's own tests only exercise single-leg assets.
    ///
    ///         THE DISCRIMINATING MUTATION: delete the `if (count == tmp.length) break;` bound in `_collectLegs`
    ///         and this test reverts with Panic 0x32 instead of returning.
    function test_memberOverEmittingLegs_losesOnlyTheSurplus_notTheWholeRead() public {
        OverEmittingMember over = new OverEmittingMember(address(balances), admin);
        bytes32 submitterRole = over.SUBMITTER_ROLE();
        vm.prank(admin);
        over.grantRole(submitterRole, address(this));
        over.feed(alice, address(tok), 100 ether);

        INAVCalculator.PositionBalance[] memory positions = over.getAdapterPositions(alice, address(0));

        assertEq(positions.length, 1, "bounded to the declared cap rather than panicking");
        assertEq(positions[0].amount, 100 ether, "and the leg that did fit is intact");
    }
}
