// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {IAttestedBalanceAdapter} from "src/balances/IAttestedBalanceAdapter.sol";
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

    function _verifyPayload(bytes32, address, bytes memory)
        internal
        view
        virtual
        override
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        return (new address[](0), new uint256[](0), new bytes[](0));
    }

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view virtual override returns (INAVCalculator.PositionBalance[] memory legs) {
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

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        // Over-declares COUNT only: the two legs PARTITION the value, so the magnitude bound is untouched and
        // this fixture isolates the leg-count property it exists to test.
        legs = new INAVCalculator.PositionBalance[](2); // declares 1 (inherited default), emits 2
        legs[0] = _row(meta, liveValue / 2, abi.encode(address(this)), bytes32(0));
        legs[1] = _row(meta, liveValue - liveValue / 2, abi.encode(address(this)), keccak256("second"));
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
        bytes memory c,
        bool fromCache
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        if (asset != greedy) return super._assetLegs(a, asset, meta, liveValue, v, c, fromCache);
        // Three legs that PARTITION the value: over-declares count, respects magnitude.
        legs = new INAVCalculator.PositionBalance[](3); // declares 1, emits 3
        legs[0] = _row(meta, liveValue / 3, abi.encode(address(this)), bytes32(uint256(0)));
        legs[1] = _row(meta, liveValue / 3, abi.encode(address(this)), bytes32(uint256(1)));
        legs[2] = _row(meta, liveValue - 2 * (liveValue / 3), abi.encode(address(this)), bytes32(uint256(2)));
    }
}

/// @notice Returns ONE preview entry while `_assetLegs` emits two — an under-declaring member on the fail-loud path.
contract PreviewOverEmitter is OverEmittingMember {
    address public asset;

    constructor(address nav_, address admin_, address asset_) OverEmittingMember(nav_, admin_) {
        asset = asset_;
    }

    function _verifyPayload(bytes32, address, bytes memory)
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

/// @notice Over-emits for a REGISTERED asset while an UNREGISTERED one pads the account-wide buffer.
/// @dev The shape that separates the preview's per-asset count bound from its aggregate one. `cap` sums
///      `_previewLegCount` over EVERY entry, including entries the loop then skips (`!found`, or `live == 0`), so
///      an aggregate-only bound let asset A silently borrow skipped asset B's budget and return more legs than it
///      declared — while the SAME data through `getAdapterPositions` drops A entirely. The two paths then
///      disagreed on identical inputs, which is the one outcome the shared `_assetLegs`/`_liveValue` tail exists
///      to prevent.
contract PreviewBudgetBorrower is ProbeMember {
    address public asset;
    address public unregistered;

    constructor(address nav_, address admin_, address asset_, address unregistered_) ProbeMember(nav_, admin_) {
        asset = asset_;
        unregistered = unregistered_;
    }

    function _verifyPayload(bytes32, address, bytes memory)
        internal
        view
        override
        returns (address[] memory assets, uint256[] memory values, bytes[] memory ctxs)
    {
        assets = new address[](2);
        values = new uint256[](2);
        ctxs = new bytes[](2);
        assets[0] = asset; // registered — over-emits below
        values[0] = 100 ether;
        assets[1] = unregistered; // skipped at `!found`, but its declared leg still sized the buffer
        values[1] = 100 ether;
    }

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](2); // declares 1 via the inherited `_previewLegCount`
        legs[0] = _row(meta, liveValue / 2, abi.encode(address(this)), bytes32(0));
        legs[1] = _row(meta, liveValue - liveValue / 2, abi.encode(address(this)), keccak256("borrowed"));
    }
}

/// @notice Returns arrays of mismatched length from the preview payload hook.
contract RaggedPreviewMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _verifyPayload(bytes32, address, bytes memory)
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

/// @notice Forges ONE leg on the PREVIEW path, on whichever axis `mode` selects.
/// @dev The preview carries its own copy of all four guards, and Vigilo measured that deleting every one of them
///      left the whole attested suite green — they were live code asserted by nothing, the identical defect class
///      the file's own docstring already records from round 3 on the sibling path. Every pre-existing preview
///      fixture builds through `_row` and is honest on all four axes, so none of them could ever reach a guard.
///      This member exists to drive each one. It declares and emits exactly ONE leg so the buffer-length revert
///      (`InvalidArguments`) cannot fire first and mask the guard under test.
contract PreviewForgingMember is ProbeMember {
    enum Mode {
        Debt,
        WrongAsset,
        WrongAdapter,
        OverValue
    }

    address public asset;
    address public other;
    Mode public mode;

    constructor(address nav_, address admin_, address asset_, address other_, Mode mode_) ProbeMember(nav_, admin_) {
        asset = asset_;
        other = other_;
        mode = mode_;
    }

    function _verifyPayload(bytes32, address, bytes memory)
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

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](1);
        if (mode == Mode.WrongAsset) {
            (INAVCalculator.Asset memory o,) = NAV_CALCULATOR.getRegisteredAsset(other);
            legs[0] = _row(o, liveValue, abi.encode(address(this)), bytes32(0));
            return legs;
        }
        legs[0] = _row(meta, mode == Mode.OverValue ? liveValue + 1 : liveValue, abi.encode(address(this)), bytes32(0));
        if (mode == Mode.Debt) legs[0].isDebt = true;
        if (mode == Mode.WrongAdapter) legs[0].balanceAdapter = address(0xBEEF);
    }
}

/// @notice Hand-builds a DEBT leg, bypassing `_row` entirely — the route the charter's compiler half cannot close.
/// @dev `_assetLegs` is necessarily virtual and returns member-constructed structs, so a member is never forced
///      through `_row`. This is the member the runtime charter check exists for.
contract DebtEmittingMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](1);
        legs[0].balanceAsset = meta;
        legs[0].balanceAdapter = address(this);
        legs[0].amount = liveValue;
        legs[0].isDebt = true; // hand-built, never touched `_row`
    }
}

/// @notice Declares ONE leg but returns [credit, debt] — the debt leg sits BEYOND the declared cap.
/// @dev The shape that slipped past the charter check while the slice bound was evaluated first: the bound broke
///      the loop before `legs[1]` was ever inspected, so the debt leg was dropped rather than rejected.
contract DebtBeyondCapMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](2); // declares 1 (inherited default)
        legs[0] = _row(meta, liveValue, abi.encode(address(this)), bytes32(0)); // fits
        legs[1].balanceAsset = meta; // beyond the cap, and a DEBT leg
        legs[1].balanceAdapter = address(this);
        legs[1].amount = liveValue;
        legs[1].isDebt = true;
    }
}

/// @notice Honest leg COUNT, honest direction — but each leg carries the FULL value, doubling the total.
/// @dev Passes the count cap and the credit-only check; the only thing that catches it is the magnitude bound.
contract DoubleCountingMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _cachedLegCount(address, address) internal pure override returns (uint256) {
        return 2; // honest: it really does emit two
    }

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](2);
        legs[0] = _row(meta, liveValue, abi.encode(address(this)), bytes32(0));
        legs[1] = _row(meta, liveValue, abi.encode(address(this)), keccak256("two")); // full value AGAIN
    }
}

/// @notice [credit(v/2), credit(v/2), debt] — the debt leg sits at surplus depth TWO.
/// @dev The shape that survived the first ordering fix. With a cap of 1 the loop used to `break` once the copy
///      budget was spent, terminating INSPECTION: j=0 copied, j=1 passed both checks and tripped the break, and
///      j=2 — the debt leg — was never looked at. Padding with a same-value credit is all it takes.
contract DebtBeyondCapPaddedMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _cachedLegCount(address, address) internal pure override returns (uint256) {
        return 3; // honest — so the count arm cannot be what catches this
    }

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](3); // declares 3 below — every leg is IN BOUNDS
        legs[0] = _row(meta, liveValue / 2, abi.encode(address(this)), bytes32(0));
        legs[1] = _row(meta, liveValue - liveValue / 2, abi.encode(address(this)), keccak256("pad"));
        legs[2].balanceAsset = meta; // depth 2, and a DEBT leg
        legs[2].balanceAdapter = address(this);
        legs[2].amount = 0; // zero so the magnitude bound cannot be what catches it
        legs[2].isDebt = true;
    }
}

/// @notice Denominates its leg in a DIFFERENT registered asset than the one being valued.
/// @dev `balanceAsset.asset` is the pricing key. Honest count, credit direction, and a magnitude equal to the
///      attested value in RAW units — yet priced in another token entirely.
contract AssetSpoofingMember is ProbeMember {
    address public spoof;

    constructor(address nav_, address admin_, address spoof_) ProbeMember(nav_, admin_) {
        spoof = spoof_;
    }

    function _assetLegs(address, address, INAVCalculator.Asset memory, uint256 liveValue, uint256, bytes memory, bool)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory legs)
    {
        (INAVCalculator.Asset memory other,) = NAV_CALCULATOR.getRegisteredAsset(spoof);
        legs = new INAVCalculator.PositionBalance[](1);
        legs[0] = _row(other, liveValue, abi.encode(address(this)), bytes32(0)); // wrong unit
    }
}

/// @notice Attributes its leg to ANOTHER adapter — the audit-trail axis.
contract AdapterSpoofingMember is ProbeMember {
    constructor(address nav_, address admin_) ProbeMember(nav_, admin_) {}

    function _assetLegs(
        address,
        address,
        INAVCalculator.Asset memory meta,
        uint256 liveValue,
        uint256,
        bytes memory,
        bool
    ) internal view override returns (INAVCalculator.PositionBalance[] memory legs) {
        legs = new INAVCalculator.PositionBalance[](1);
        legs[0] = _row(meta, liveValue, abi.encode(address(this)), bytes32(0));
        legs[0].balanceAdapter = address(0xBEEF); // repo-wide invariant says address(this)
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

    /// @notice FREEZE TRIPWIRE. `type(IAttestedBalanceAdapter).interfaceId` is the XOR of the interface's own
    ///         declared FUNCTION selectors, and every member bakes it into `supportsInterface` at compile time. So
    ///         it is frozen the moment any member deploys: adding a function afterwards strands deployed members
    ///         on the old id, and a consumer probing the family gets `false` from contracts that are, in every
    ///         other sense, members.
    /// @dev    Before the first deploy this test documents intent and makes the change deliberate. After it, this
    ///         is the difference between a silent consumer break and a red build. Errors and events do NOT enter
    ///         the id, so those remain freely extensible — which is why the family declares them on the interface
    ///         rather than splitting them out.
    ///
    ///         If this fails: you added, removed or re-signed an interface FUNCTION. If nothing is deployed yet,
    ///         update the constant deliberately. If anything is deployed, do not — add a v2 interface instead.
    function test_interfaceId_isFrozen() public pure {
        assertEq(
            type(IAttestedBalanceAdapter).interfaceId,
            bytes4(0xcd2e993b),
            "IAttestedBalanceAdapter function surface changed"
        );
    }

    /// @notice The family CHARTER is credit-only, and the base enforces it rather than documenting it.
    /// @dev The per-item DROP in `_collectLegs` is licensed only because a dropped leg can just shrink NAV. That
    ///      licence used to rest on member authors not overriding the reads; the read surface is now non-virtual
    ///      and `_row` cannot set `isDebt`, so the charter is compiler-enforced.
    ///      THE DISCRIMINATING MUTATION: re-add `virtual` to `getAdapterBalances` and have a probe member return
    ///      a debt leg — this test is what should stop that landing.
    /// @notice A member that hand-builds a DEBT leg is rejected at RUNTIME, not merely discouraged.
    /// @dev THE HOLE THIS CLOSES. The charter's compiler half — non-virtual reads, and `_row` being unable to set
    ///      `isDebt` — does NOT cover `_assetLegs`, which is necessarily virtual and returns member-built structs,
    ///      so nothing forces a member through `_row`. Until this check existed the interface claimed "the base
    ///      enforces it" while a member bypassing `_row` flowed a debt leg straight through `getAdapterPositions`.
    ///      It matters because the base's TWO silent drops are licensed only by credit-only: a dropped credit leg
    ///      shrinks NAV, a dropped debt leg inflates it — the one forbidden direction.
    ///      THE DISCRIMINATING MUTATION: remove the `legs[j].isDebt` check in `_collectLegs` and this passes.
    /// @notice A DEBT leg BEYOND the declared leg count must be REJECTED, not silently dropped.
    /// @dev THE OVER-REPORT THIS CLOSES, and the subtler of the two charter holes. The runtime check and the
    ///      per-asset slice bound share a loop, and while the bound ran FIRST it inspected only the legs that
    ///      fit: a member declaring one leg and returning [credit, debt] had its debt leg dropped by the bound
    ///      without ever being tested. NAV then reports the credit alone — LARGER than reality, the one direction
    ///      forbidden — with no revert and a green suite, because every other charter assertion examines only the
    ///      legs that survived the copy.
    ///      THE DISCRIMINATING MUTATION: move `if (taken == legCaps[i]) break;` back above the `isDebt` check and
    ///      this goes green while the adapter silently over-reports.
    function test_charter_debtLegBeyondTheCap_isInspectedBeforeTheAssetIsDropped() public {
        DebtBeyondCapMember m = new DebtBeyondCapMember(address(balances), admin);
        bytes32 submitterRole = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(submitterRole, address(this));
        m.feed(alice, address(tok), 100 ether);

        // Declares 1, emits [credit, debt] — over-emission AND a charter violation. The over-emission must NOT
        // short-circuit the charter check: dropping this asset silently would report 0 for a position whose true
        // net is NEGATIVE, which is an over-report. Omitting a debt leg inflates NAV exactly as much as emitting
        // a spurious credit does.
        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.DebtLegRejected.selector, address(tok)));
        m.getAdapterPositions(alice, address(0));
    }

    /// @notice Legs that sum to MORE than the asset's live value are rejected — the magnitude bound.
    /// @dev THE THIRD CHARTER HOLE, and the worst of them. Count and direction were both structurally enforced;
    ///      magnitude was not. A member with an HONEST leg count (declares two, emits two), building both legs
    ///      through `_row` so they are credits attributed to itself, could give each leg the FULL value and double
    ///      the account's reported holding — passing every other guard, unbounded rather than 2x-bounded, in the
    ///      one direction the family forbids. The family always intended legs to PARTITION the value (the README
    ///      recipe says to floor the split so they sum to at most the total); that obligation was documented and
    ///      unenforced.
    ///      THE DISCRIMINATING MUTATION: delete the `legSum > assetValue` check and this passes while
    ///      `getAdapterPositions` reports 2x what `getAdapterBalanceForAsset` does for the same account.
    function test_charter_legsSummingAboveTheValueAreRejected() public {
        DoubleCountingMember m = new DoubleCountingMember(address(balances), admin);
        bytes32 submitterRole = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(submitterRole, address(this));
        m.feed(alice, address(tok), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.LegSumExceedsValue.selector, address(tok)));
        m.getAdapterPositions(alice, address(0));
    }

    /// @notice A debt leg at surplus depth TWO is still rejected — the cap must not terminate INSPECTION.
    /// @dev THE HOLE THE FIRST ORDERING FIX LEFT. Moving the charter check above the `break` only covered surplus
    ///      depth ONE: with a cap of 1, `[credit(v/2), credit(v/2), debt]` copied j=0, passed j=1, hit the break,
    ///      and never inspected j=2. The debt leg's amount is deliberately ZERO here so the magnitude bound
    ///      cannot be what catches it — this test isolates inspection completeness.
    ///      THE DISCRIMINATING MUTATION: restore `if (taken == legCaps[i]) break;` in place of the count arm and
    ///      this passes while the debt leg is silently dropped.
    function test_charter_debtLegAtSurplusDepthTwoIsStillInspected() public {
        DebtBeyondCapPaddedMember m = new DebtBeyondCapPaddedMember(address(balances), admin);
        bytes32 role = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(role, address(this));
        m.feed(alice, address(tok), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.DebtLegRejected.selector, address(tok)));
        m.getAdapterPositions(alice, address(0));
    }

    /// @notice `balanceAdapter == address(this)` is the repo-wide audit trail, and only `_row` was upholding it.
    /// @dev `_assetLegs` is virtual and returns member-built structs, so nothing forced a member through `_row`.
    ///      NAV only reads this field for a fail-open display staticcall, so a forged one is not an over-report —
    ///      it breaks the reconciliation key every consumer of `PositionBalance` joins on.
    ///      THE DISCRIMINATING MUTATION: delete the `balanceAdapter != address(this)` check and this passes.
    function test_charter_legAttributedToAnotherAdapterIsRejected() public {
        AdapterSpoofingMember m = new AdapterSpoofingMember(address(balances), admin);
        bytes32 role = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(role, address(this));
        m.feed(alice, address(tok), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.LegAdapterMismatch.selector, address(tok)));
        m.getAdapterPositions(alice, address(0));
    }

    /// @notice A leg denominated in a DIFFERENT registered asset is rejected — the pricing key is pinned.
    /// @dev THE FOURTH AXIS. Count, direction and magnitude were all bounded; the UNIT was not. `balanceAsset.asset`
    ///      is what `PriceFeedLib` resolves a price feed from, so a member passing every other guard in the
    ///      attested asset's raw units could denominate its legs in any other registered asset and inflate
    ///      quote-NAV by the price ratio — unbounded, in the forbidden direction. Bounding amounts without
    ///      pinning the unit compares numbers that are not in the same currency.
    ///      THE DISCRIMINATING MUTATION: delete the `balanceAsset.asset != live[i]` check and this passes.
    function test_charter_legDenominatedInAnotherAssetIsRejected() public {
        Mock_ERC20 other = new Mock_ERC20("OTHER", 18);
        balances.addSupportedAssetForTest(address(other));
        AssetSpoofingMember m = new AssetSpoofingMember(address(balances), admin, address(other));
        bytes32 role = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(role, address(this));
        m.feed(alice, address(tok), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.LegAssetMismatch.selector, address(tok)));
        m.getAdapterPositions(alice, address(0));
    }

    function test_charter_handBuiltDebtLegIsRejectedAtRuntime() public {
        DebtEmittingMember m = new DebtEmittingMember(address(balances), admin);
        bytes32 submitterRole = m.SUBMITTER_ROLE();
        vm.prank(admin);
        m.grantRole(submitterRole, address(this));
        m.feed(alice, address(tok), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.DebtLegRejected.selector, address(tok)));
        m.getAdapterPositions(alice, address(0));
    }

    function test_charter_readSurfaceReportsCreditOnly() public {
        probe.feed(alice, address(tok), 100 ether);

        (, bool isDebtSingle) = probe.getAdapterBalanceForAsset(alice, address(tok));
        assertFalse(isDebtSingle, "per-asset read is credit-only");

        (,, bool[] memory isDebtMany) = probe.getAdapterBalances(alice);
        assertEq(isDebtMany.length, 1, "one entry");
        assertFalse(isDebtMany[0], "enumerated read is credit-only");

        INAVCalculator.PositionBalance[] memory positions = probe.getAdapterPositions(alice, address(0));
        assertFalse(positions[0].isDebt, "legs are credit-only");
    }

    /// @notice `isAttestationLive` separates the three states that all report a balance of zero.
    /// @dev Absent / stale / live-but-consumed need three different operational responses, and before this the
    ///      external surface could not tell them apart.
    function test_isAttestationLive_disambiguatesTheThreeZeroStates() public {
        // 1. Absent.
        assertFalse(probe.isAttestationLive(alice, address(tok)), "nothing cached");

        // 2. Live.
        probe.feed(alice, address(tok), 100 ether);
        assertTrue(probe.isAttestationLive(alice, address(tok)), "cached and current");

        // 3. Stale — reads zero, but the record is still there and still distinguishable from absent.
        probe.setEpoch(keccak256("rotated"));
        (uint256 amt,) = probe.getAdapterBalanceForAsset(alice, address(tok));
        assertEq(amt, 0, "stale reads zero");
        assertFalse(probe.isAttestationLive(alice, address(tok)), "and is reported stale, not absent");
        (, bytes32 epoch,) = probe.attestations(alice, address(tok));
        assertTrue(epoch != bytes32(0), "still cached, so a consumer can tell stale from absent");
    }

    /// @notice The cap is readable through the family interface, without knowing the member.
    function test_maxAssetsPerAccount_isExposedOnTheInterface() public view {
        assertEq(IAttestedBalanceAdapter(address(probe)).maxAssetsPerAccount(), 4, "probe cap");
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
    ///         build its legs through `_row` — a member that emits debt is REJECTED by the base at runtime (`DebtLegRejected`).
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

        // The greedy asset now drops ENTIRELY (it over-emits) rather than being capped at its declared 1. The
        // property under test is unchanged and is the one that matters: whatever happens to the greedy asset is
        // CONFINED to it. An account-wide leg budget let the greedy asset consume its neighbour's capacity, so
        // the neighbour lost everything — that is the regression this pins, and it is still pinned.
        assertEq(positions.length, 1, "the greedy asset drops whole; the honest neighbour is untouched");
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

    /// @notice Ragged arrays out of `_verifyPayload` must fail loud and attributably.
    /// @dev    Also asserted by nothing until now (Vigilo mutation-verified: deleting the guard left 98/98 green).
    ///         THE DISCRIMINATING MUTATION: drop the length check and this reverts with a bare Panic instead.
    /// @notice Each of the preview path's four guards actually fires. They were dead code before these tests.
    /// @dev THE DISCRIMINATING MUTATION: delete any one guard in `_buildVerifiedLegs` and exactly one of these
    ///      four fails. Vigilo measured the pre-existing suite at 133/133 green with ALL of them deleted.
    function test_previewCharter_debtLegIsRejected() public {
        _previewForging(PreviewForgingMember.Mode.Debt, IAttestedBalanceAdapter.DebtLegRejected.selector);
    }

    function test_previewCharter_legInAnotherAssetIsRejected() public {
        _previewForging(PreviewForgingMember.Mode.WrongAsset, IAttestedBalanceAdapter.LegAssetMismatch.selector);
    }

    function test_previewCharter_legAttributedElsewhereIsRejected() public {
        _previewForging(PreviewForgingMember.Mode.WrongAdapter, IAttestedBalanceAdapter.LegAdapterMismatch.selector);
    }

    function test_previewCharter_legAboveTheValueIsRejected() public {
        _previewForging(PreviewForgingMember.Mode.OverValue, IAttestedBalanceAdapter.LegSumExceedsValue.selector);
    }

    function _previewForging(PreviewForgingMember.Mode mode, bytes4 expected) private {
        Mock_ERC20 other = new Mock_ERC20("OTHER", 18);
        balances.addSupportedAssetForTest(address(other));
        PreviewForgingMember m = new PreviewForgingMember(address(balances), admin, address(tok), address(other), mode);
        vm.expectRevert(abi.encodeWithSelector(expected, address(tok)));
        m.previewPositions(alice, abi.encode(uint256(1)));
    }

    /// @notice The preview bounds the leg count PER ASSET, not only against the account-wide buffer.
    /// @dev THE DISCRIMINATING MUTATION: delete the `legs.length > _previewLegCount(ctxs[i])` check and this
    ///      passes — the aggregate bound cannot catch it, because the skipped asset's declared leg leaves exactly
    ///      enough room. Without the per-asset bound the preview accepts a leg count the cache path rejects.
    function test_previewCountBound_isPerAsset_notJustTheAccountWideBuffer() public {
        Mock_ERC20 unregistered = new Mock_ERC20("UNREG", 18); // deliberately NOT registered on the NAV
        PreviewBudgetBorrower m =
            new PreviewBudgetBorrower(address(balances), admin, address(tok), address(unregistered));

        vm.expectRevert(InvalidArguments.selector);
        m.previewPositions(alice, abi.encode(uint256(1)));
    }

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
    function test_memberOverEmittingLegs_dropsTheAsset_ratherThanTruncatingIt() public {
        OverEmittingMember over = new OverEmittingMember(address(balances), admin);
        bytes32 submitterRole = over.SUBMITTER_ROLE();
        vm.prank(admin);
        over.grantRole(submitterRole, address(this));
        over.feed(alice, address(tok), 100 ether);

        INAVCalculator.PositionBalance[] memory positions = over.getAdapterPositions(alice, address(0));

        // Truncating to the declared count was the ORIGINAL behaviour and this test asserted it. It was
        // replaced because truncation discards legs WITHOUT inspecting them, and a discarded debt leg is an
        // over-report. Dropping the asset outright is the same direction the `catch` arm already takes.
        assertEq(positions.length, 0, "no panic, and no partial set either");
    }
}
