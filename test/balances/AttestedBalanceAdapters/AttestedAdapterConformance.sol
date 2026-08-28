// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {IAttestedBalanceAdapter} from "src/balances/IAttestedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AttestedAdapterConformance
/// @author KPK
/// @notice The attested family's **conformance kit**: an abstract suite every member's tests inherit, asserting the
///         invariants that make the family safe. A member supplies fixtures through the hooks below; the kit
///         supplies the assertions.
///
/// @dev **Why a test kit rather than more interface surface.** The family has one member and its interface freezes
///      at first deploy, so "what every member must satisfy" is safer expressed executably than as a frozen ABI: a
///      test costs nothing to change, runs in CI for every future member, and can assert behaviour a type system
///      cannot (that a tampered payload is *rejected*, that an upsert does not suppress, that the reported figure
///      never exceeds the attested one).
///
///      **What this kit CANNOT assert, stated plainly because a green suite is not evidence.** The fixtures are
///      member-authored, so the kit's trust root is review, not execution:
///      - It cannot check that {_verifyPayload} implements the member's REAL protocol verification. It only checks
///        that whatever `_tamperedPayload` returns is rejected. A vacuous tampered fixture — one that reverts for
///        an unrelated reason, or is not actually tampered — yields vacuous passes. **Reviewers must read the
///        member's fixtures, not just its results.**
///      - It cannot check feeder liveness or completeness. Those are off-chain properties.
///      - It cannot check gas behaviour against real protocol state; that is fork-test territory.
///      - It cannot check that submitter-controlled auxiliary metadata is honestly documented as unattested.
///
///      Members are expected to keep their own protocol-specific suite as well. This kit is the floor, not the
///      ceiling.
abstract contract AttestedAdapterConformance is BalanceAdapterTestBase {
    AttestedValueCache internal member;
    address internal submitter;
    address internal outsider;

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Fixtures a member must supply
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Deploy the member with `admin_` holding `DEFAULT_ADMIN_ROLE`, plus whatever protocol mocks it needs.
    function _deployMember(address admin_) internal virtual returns (AttestedValueCache);

    /// @notice A VALID payload for `account`, with the assets and attested values it should produce.
    /// @dev Must be accepted by the member's `_verifyPayload` and must reference assets registered on the NAV.
    function _validPayload(address account)
        internal
        virtual
        returns (bytes memory data, address[] memory assets, uint256[] memory values);

    /// @notice A payload that MUST fail the member's verification — a forged proof, a bad signature, a wrong leaf.
    /// @dev The single most important fixture, and the one a reviewer must actually read. It has to fail for the
    ///      RIGHT reason: because verification rejected it, not because it is malformed in some unrelated way.
    function _tamperedPayload(address account) internal virtual returns (bytes memory data);

    /// @notice Make every currently-cached attestation STALE, by whatever the member's validity scheme is —
    ///         rotating a root, advancing past a TTL, invalidating an anchor.
    function _rotateValidity() internal virtual;

    /// @notice Submit through the member's own TYPED entrypoint, if it has one; otherwise call the generic
    ///         `submit`. Exists so a typed convenience cannot quietly bypass the role gate the kit checks.
    function _submitViaTypedEntrypoint(address account, bytes memory data) internal virtual {
        IAttestedBalanceAdapter(address(member)).submit(account, data);
    }

    function setUp() public virtual override {
        super.setUp();
        submitter = makeAddr("conformanceSubmitter");
        outsider = makeAddr("conformanceOutsider");
        member = _deployMember(admin);
        bytes32 role = member.SUBMITTER_ROLE();
        vm.prank(admin);
        IAccessControl(address(member)).grantRole(role, submitter);
    }

    function _submit(address account, bytes memory data) internal {
        vm.prank(submitter);
        IAttestedBalanceAdapter(address(member)).submit(account, data);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 1. Authorization — submits gated, clears not
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice An address without `SUBMITTER_ROLE` cannot write, through EITHER entrypoint.
    /// @dev The typed half is the subtle one: a member adding a convenience `submitX(...)` that reaches the cache
    ///      without routing through the base's admission point would be a silent back door, and this is what
    ///      catches it.
    function test_conformance_submitIsRoleGated() public {
        (bytes memory data,,) = _validPayload(alice);

        bytes32 role = member.SUBMITTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        IAttestedBalanceAdapter(address(member)).submit(alice, data);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        _submitViaTypedEntrypoint(alice, data);
    }

    /// @notice The stale-gated clears stay PERMISSIONLESS — deliberately, and this pins it.
    /// @dev Role-gating removal is audit finding L-02: a compromised role-holder could then delete valid live
    ///      allocations. The stale gate makes clearing safe for anyone, and keeping it open means a wedged cache
    ///      can be repaired by anybody rather than only the keyholder.
    function test_conformance_clearsArePermissionless() public {
        (bytes memory data, address[] memory assets,) = _validPayload(alice);
        _submit(alice, data);
        _rotateValidity();

        vm.prank(outsider); // holds no role of any kind
        IAttestedBalanceAdapter(address(member)).clearAttestation(alice, assets[0]);

        (, bytes32 epoch,) = IAttestedBalanceAdapter(address(member)).attestations(alice, assets[0]);
        assertEq(epoch, bytes32(0), "a roleless caller can GC a dead entry");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 2. Verification is real — the one thing the base cannot check for a member
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice A tampered payload must never reach the cache, on the write path OR the preview path.
    /// @dev Both paths share one decoder by design, so this also pins that they have not been split apart.
    function test_conformance_tamperedPayloadNeverLands() public {
        bytes memory bad = _tamperedPayload(alice);

        vm.prank(submitter);
        vm.expectRevert();
        IAttestedBalanceAdapter(address(member)).submit(alice, bad);

        assertEq(IAttestedBalanceAdapter(address(member)).assetsOf(alice).length, 0, "nothing cached");

        vm.expectRevert();
        IAttestedBalanceAdapter(address(member)).previewPositions(alice, bad);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 3. Upsert semantics — a submit can add or refresh, never suppress
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Re-submitting the same payload must not duplicate the enumeration.
    /// @dev A duplicate entry would value one asset TWICE — the over-report direction the family forbids.
    function test_conformance_resubmitNeverDuplicatesEnumeration() public {
        (bytes memory data, address[] memory assets,) = _validPayload(alice);
        _submit(alice, data);
        uint256 firstCount = IAttestedBalanceAdapter(address(member)).assetsOf(alice).length;
        _submit(alice, data);

        address[] memory listed = IAttestedBalanceAdapter(address(member)).assetsOf(alice);
        assertEq(listed.length, firstCount, "re-submit must refresh in place, not push again");
        for (uint256 i; i < listed.length; ++i) {
            for (uint256 j = i + 1; j < listed.length; ++j) {
                assertTrue(listed[i] != listed[j], "enumeration contains a duplicate");
            }
        }
        assertTrue(assets.length > 0, "fixture sanity: payload carries at least one asset");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 4. Staleness — an entry that is no longer provably current reads ZERO
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice After validity rotates, the entry reads 0 everywhere — but is still distinguishable from absent.
    /// @dev The three-state distinction is the point: absent / stale / live-but-consumed need three different
    ///      operational responses, and `isAttestationLive` plus the presence sentinel is how a consumer tells them
    ///      apart without knowing the protocol.
    function test_conformance_staleReadsZeroButRemainsDistinguishable() public {
        (bytes memory data, address[] memory assets,) = _validPayload(alice);
        _submit(alice, data);
        assertTrue(IAttestedBalanceAdapter(address(member)).isAttestationLive(alice, assets[0]), "live before");

        _rotateValidity();

        (uint256 amt,) = IBalanceAdapter(address(member)).getAdapterBalanceForAsset(alice, assets[0]);
        assertEq(amt, 0, "stale reads zero");
        assertEq(IBalanceAdapter(address(member)).getAdapterPositions(alice, address(0)).length, 0, "and emits no legs");
        assertFalse(IAttestedBalanceAdapter(address(member)).isAttestationLive(alice, assets[0]), "reported stale");
        (, bytes32 epoch,) = IAttestedBalanceAdapter(address(member)).attestations(alice, assets[0]);
        assertTrue(epoch != bytes32(0), "still cached, so stale is distinguishable from absent");
    }

    /// @notice A LIVE entry cannot be cleared; a stale one can. This is what stops permissionless suppression.
    function test_conformance_clearIsStaleGated() public {
        (bytes memory data, address[] memory assets,) = _validPayload(alice);
        _submit(alice, data);

        vm.expectRevert(abi.encodeWithSelector(IAttestedBalanceAdapter.AttestationStillLive.selector, alice, assets[0]));
        IAttestedBalanceAdapter(address(member)).clearAttestation(alice, assets[0]);

        _rotateValidity();
        IAttestedBalanceAdapter(address(member)).clearAttestation(alice, assets[0]);
        assertEq(IAttestedBalanceAdapter(address(member)).assetsOf(alice).length, 0, "cleared once dead");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 5. The Iron Law and the family charter
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Reported amounts never exceed the ATTESTED figure. The family's central guarantee.
    /// @dev The base does not clamp `_liveValue` — clamping would be wrong for a member whose live figure can
    ///      legitimately grow past what was attested — so this is where the postcondition is enforced. A member
    ///      that legitimately exceeds it must OVERRIDE this test, which forces it to document why.
    function test_conformance_neverReportsMoreThanAttested() public virtual {
        (bytes memory data, address[] memory assets,) = _validPayload(alice);
        _submit(alice, data);

        for (uint256 i; i < assets.length; ++i) {
            (uint256 attested,,) = IAttestedBalanceAdapter(address(member)).attestations(alice, assets[i]);
            (uint256 reported,) = IBalanceAdapter(address(member)).getAdapterBalanceForAsset(alice, assets[i]);
            assertLe(reported, attested, "reported exceeds the attested figure");
        }

        // And the legs of an asset sum to at most what that asset reports.
        INAVCalculator.PositionBalance[] memory positions =
            IBalanceAdapter(address(member)).getAdapterPositions(alice, address(0));
        for (uint256 i; i < assets.length; ++i) {
            uint256 legSum;
            for (uint256 j; j < positions.length; ++j) {
                if (positions[j].balanceAsset.asset == assets[i]) legSum += positions[j].amount;
            }
            (uint256 reported,) = IBalanceAdapter(address(member)).getAdapterBalanceForAsset(alice, assets[i]);
            assertLe(legSum, reported, "legs sum above the reported balance");
        }
    }

    /// @notice CHARTER: every leg is a credit, and every leg carries `address(this)` as its adapter.
    /// @dev The per-item DROP in the base's read fan-out is licensed only by the credit-only charter — a dropped
    ///      credit leg can just shrink NAV, a dropped DEBT leg would inflate it.
    function test_conformance_creditOnlyAndSelfAttributed() public {
        (bytes memory data,,) = _validPayload(alice);
        _submit(alice, data);

        INAVCalculator.PositionBalance[] memory positions =
            IBalanceAdapter(address(member)).getAdapterPositions(alice, address(0));
        assertTrue(positions.length > 0, "fixture sanity: the payload should produce legs");
        for (uint256 i; i < positions.length; ++i) {
            assertFalse(positions[i].isDebt, "attested adapters report credits only");
            assertEq(positions[i].balanceAdapter, address(member), "balanceAdapter must be address(this)");
        }

        (,, bool[] memory isDebt) = IBalanceAdapter(address(member)).getAdapterBalances(alice);
        for (uint256 i; i < isDebt.length; ++i) {
            assertFalse(isDebt[i], "enumerated read is credit-only");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 6. The two paths agree
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice `previewPositions(account, payload)` matches `getAdapterPositions` after submitting that payload.
    /// @dev End-to-end proof of the one-decoder property: the write path and the cache-free preview share a single
    ///      `_verifyPayload` and a single leg builder, so they cannot drift. Asserted across the EXTERNAL surfaces,
    ///      which is the only place a consumer would notice a divergence.
    function test_conformance_previewMatchesCacheRead() public {
        (bytes memory data,,) = _validPayload(alice);

        INAVCalculator.PositionBalance[] memory previewed =
            IAttestedBalanceAdapter(address(member)).previewPositions(alice, data);

        _submit(alice, data);
        INAVCalculator.PositionBalance[] memory cached =
            IBalanceAdapter(address(member)).getAdapterPositions(alice, address(0));

        assertEq(previewed.length, cached.length, "preview and cache disagree on leg count");
        for (uint256 i; i < previewed.length; ++i) {
            assertEq(previewed[i].amount, cached[i].amount, "leg amount differs");
            assertEq(previewed[i].balanceAsset.asset, cached[i].balanceAsset.asset, "leg asset differs");
            assertEq(uint8(previewed[i].positionKind), uint8(cached[i].positionKind), "leg kind differs");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // 7. Family surface
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Every member advertises the whole family surface via ERC-165.
    function test_conformance_advertisesFamilyInterfaces() public view {
        assertTrue(member.supportsInterface(type(IAttestedBalanceAdapter).interfaceId), "attested marker");
        assertTrue(member.supportsInterface(type(IBalanceAdapter).interfaceId), "balance adapter");
        assertTrue(member.supportsInterface(type(IPositionDescribable).interfaceId), "position describable");
        assertTrue(member.supportsInterface(type(IAccessControl).interfaceId), "access control");
    }

    /// @notice The per-account cap is readable through the interface and is a real bound.
    function test_conformance_capIsExposedAndPositive() public view {
        assertTrue(IAttestedBalanceAdapter(address(member)).maxAssetsPerAccount() > 0, "cap must bound the read");
    }

    /// @notice An open universe: attested members cannot enumerate their asset set ahead of time.
    /// @dev The reads drive off the per-account cache instead, which is why `assetsOf` exists.
    function test_conformance_underlyingAssetsIsOpenUniverse() public view {
        assertEq(
            IBalanceAdapter(address(member)).underlyingAssetsSupported().length,
            0,
            "attested universes are not enumerable ahead of time"
        );
    }

    /// @notice Zero-address reads are safe and empty rather than reverting on the NAV path.
    function test_conformance_zeroAccountReadsAreEmpty() public view {
        (uint256 amt,) = IBalanceAdapter(address(member)).getAdapterBalanceForAsset(address(0), address(1));
        assertEq(amt, 0, "zero account reads zero");
        assertEq(IBalanceAdapter(address(member)).getAdapterPositions(address(0), address(0)).length, 0, "and no legs");
    }
}
