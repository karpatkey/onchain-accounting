// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";

/// @title NAVCalculatorAssetKindTest
/// @notice Covers the NAV's asset read surface: the MANAGER-gated registry setter, and `getAssetInfo` forwarding both
///         classification axes AND the display labels so a consumer needs ONE entry point and ONE call rather than
///         three addresses or three round trips.
/// @dev **Every failure branch this feature adds is reached by a test here, deliberately.** The rule comes from #241
///      and #253 the expensive way: three guards were written into `08_DeployAssetKindRegistry` on reasoning alone,
///      never executing their failure paths, and all three turned out to be defective — one checked local state and
///      called it an on-chain check, one prescribed a recovery for a cause it could not distinguish, one was
///      near-tautological. A guard whose failure branch has never run is indistinguishable from a guard that cannot
///      run. So: the zero-address revert is reached, the unset-registry read is reached, and the registry's own
///      `AssetNotClassified` is asserted to PROPAGATE rather than being swallowed.
///
///      **This suite was REWRITTEN as part of the change that deleted `getAssetKind`, not after it.** The three
///      properties above were the whole of that function's NAV-side coverage; carrying them over in the same commit
///      is what stops a deleted function from silently taking its tests with it. Every assertion below that names
///      `getAssetInfo` is the direct descendant of one that named `getAssetKind`, plus the label coverage the
///      combined getter adds.
contract NAVCalculatorAssetKindTest is SuperTest {
    AssetKindRegistry internal registry;

    function setUp() public {
        setupAll();
        // The registry derives ALL of its authority from the NAV, so it is constructed against this NAV and then
        // granted MANAGER on it — the same wiring `08_DeployAssetKindRegistry` performs.
        registry = new AssetKindRegistry(address(nav));
        vm.prank(admin);
        nav.grantRole(MANAGER, address(registry));
    }

    function _noLabels() internal pure returns (string[] memory) {
        return new string[](0);
    }

    /// @dev A label list in SIGNIFICANT order: index 0 is the protocol, index 1 narrows to the product.
    function _labels(string memory a, string memory b) internal pure returns (string[] memory l) {
        l = new string[](2);
        l[0] = a;
        l[1] = b;
    }

    /// @dev Labels can only be written at REGISTRATION, so a label test needs an asset the NAV does not already
    ///      hold — `usdc`/`weth`/`dai` are registered by `setupAll`, and re-registering one reverts. This mints a
    ///      fresh token with its own feed and registers it THROUGH the facade, which is the only path that labels.
    function _registerLabelled(string[] memory labels) internal returns (address token) {
        Mock_ERC20 t20 = new Mock_ERC20("LBL", 18);
        Mock_PriceOracleChainlink feed = new Mock_PriceOracleChainlink("LBL", 100_000_000, 8);
        vm.prank(navCalculatorManager);
        registry.registerAsset(
            address(t20), address(feed), IPrices.PriceType.Chainlink, type(uint256).max, AccrualKind.None, labels
        );
        return address(t20);
    }

    // ============================================================
    // setAssetKindRegistry
    // ============================================================

    function test_setAssetKindRegistry_storesAndIsReadable() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));
        assertEq(address(nav.assetKindRegistry()), address(registry));
    }

    function test_setAssetKindRegistry_isManagerGated() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotAuthorized.selector);
        nav.setAssetKindRegistry(address(registry));
    }

    /// @dev **The zero-address branch, REACHED rather than reasoned about.** Clearing the registry by accident would
    ///      present as a registry outage — every `getAssetInfo` reverting — rather than as the config change it is, so
    ///      it is rejected at the setter where the cause is still visible.
    function test_setAssetKindRegistry_rejectsZeroAddress() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.setAssetKindRegistry(address(0));
    }

    /// @dev Re-settable on purpose, and this is load-bearing for LABELS specifically, not just for upgrades: labels
    ///      are write-once in the registry, so replacing the registry IS the repair path for a wrong label. If this
    ///      ever stopped being re-settable, a typo would become permanent.
    function test_setAssetKindRegistry_isResettable() public {
        AssetKindRegistry second = new AssetKindRegistry(address(nav));
        vm.startPrank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));
        nav.setAssetKindRegistry(address(second));
        vm.stopPrank();
        assertEq(address(nav.assetKindRegistry()), address(second));
    }

    // ============================================================
    // getAssetInfo — the single entry point
    // ============================================================

    function test_getAssetInfo_forwardsToTheRegistry() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.prank(navCalculatorManager);
        registry.setAssetKind(address(weth), AccrualKind.Appreciating);

        (PegKind peg, AccrualKind accrual,) = nav.getAssetInfo(address(weth));
        // WETH carries no `pegToleranceBps` here, so the derived axis is Floating — this also proves the NAV is
        // returning the registry's DERIVED value and not a stored default of its own.
        assertEq(uint8(peg), uint8(PegKind.Floating));
        assertEq(uint8(accrual), uint8(AccrualKind.Appreciating));
    }

    /// @dev **The window between deploying the new implementation and calling the setter, stated as an assertion
    ///      rather than left to inference.** `assetKindRegistry` is zero until set, so this call reaches
    ///      `address(0)`. A caller in that window gets a REVERT.
    ///
    ///      That is the outcome to want. The alternative — returning `(Pegged, None, [])` because both enums are the
    ///      zero value and an empty array is a legitimate label set — would be a confident wrong answer: `Pegged +
    ///      None` is USDC's real classification and no labels is a real state, so the whole tuple is indistinguishable
    ///      from a configured reply. Adding labels to this getter made that failure mode MORE plausible-looking, not
    ///      less. This test exists to fail if anyone ever "helpfully" makes the getter tolerant.
    function test_getAssetInfo_revertsWhenRegistryUnset() public {
        assertEq(address(nav.assetKindRegistry()), address(0), "precondition: registry unset");
        vm.expectRevert();
        nav.getAssetInfo(address(weth));
    }

    /// @dev The registry's fail-closed read must survive the extra hop. `AssetNotClassified` PROPAGATES with its asset
    ///      argument intact — the NAV does not catch it and does not substitute a default. A consumer can therefore
    ///      distinguish "not classified" from every other failure, which is the whole point of the registry reverting
    ///      instead of zero-filling.
    function test_getAssetInfo_propagatesAssetNotClassified() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, address(weth)));
        nav.getAssetInfo(address(weth));
    }

    /// @dev The registry is reachable directly as well as through the NAV, and both must agree on ALL THREE fields.
    ///      The NAV is a convenience entry point, not a second source of truth.
    function test_getAssetInfo_agreesWithReadingTheRegistryDirectly() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        address token = _registerLabelled(_labels("Circle", "Stablecoin"));

        (PegKind navPeg, AccrualKind navAccrual, string[] memory navLabels) = nav.getAssetInfo(token);
        (PegKind regPeg, AccrualKind regAccrual, string[] memory regLabels) = registry.getAssetInfo(token);
        assertEq(uint8(navPeg), uint8(regPeg));
        assertEq(uint8(navAccrual), uint8(regAccrual));
        assertEq(navLabels.length, regLabels.length);
        for (uint256 i; i < navLabels.length; ++i) {
            assertEq(navLabels[i], regLabels[i]);
        }
    }

    // ============================================================
    // Labels across the hop
    // ============================================================

    /// @dev **Order is significant and must survive the forward.** Index 0 is the protocol, later indices narrow to
    ///      the product — the house rule `ProtocolNames.sol` states for `protocolName()` vs `positionLabels()`. A
    ///      forward that returned the right SET in the wrong ORDER would render as "Savings Aave v3", so this asserts
    ///      per index rather than by membership.
    function test_getAssetInfo_preservesLabelOrderAcrossTheHop() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        address token = _registerLabelled(_labels("Aave v3", "Savings"));

        (,, string[] memory labels) = nav.getAssetInfo(token);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Aave v3", "index 0 is the protocol");
        assertEq(labels[1], "Savings", "index 1 narrows to the product");
    }

    /// @dev **Zero labels is a legitimate answer, NOT an error, and the NAV must not invent one.** `positionLabels()`
    ///      already returns empty arrays legitimately, so this has precedent. The asset here IS classified — only its
    ///      labels are absent — so the classification half must still return normally. This is the test that fails if
    ///      anyone models "unlabelled" as a gap and makes the getter revert on it.
    function test_getAssetInfo_returnsEmptyLabelsForAClassifiedButUnlabelledAsset() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.prank(navCalculatorManager);
        registry.setAssetKind(address(weth), AccrualKind.Appreciating);

        (PegKind peg, AccrualKind accrual, string[] memory labels) = nav.getAssetInfo(address(weth));
        assertEq(labels.length, 0, "no labels is an answer, not a failure");
        assertEq(uint8(peg), uint8(PegKind.Floating));
        assertEq(uint8(accrual), uint8(AccrualKind.Appreciating));
    }

    // ============================================================
    // The ABI break
    // ============================================================

    /// @dev **`getAssetKind(address)` is GONE from the NAV, and this pins it as deliberate.** It shipped in #257 and
    ///      was removed days later, undeployed, because `getAssetInfo` DISPLACES its selector rather than adding one —
    ///      +87 bytes against a +182 floor for any forwarding read, where keeping both cost +291 and adding a separate
    ///      label getter cost +202. The registry still exposes `getAssetKind`; only the NAV-side forward was dropped.
    ///
    ///      Asserted by raw selector rather than by absence of a Solidity symbol, because a compile-time check would
    ///      pass vacuously — you cannot call a function that does not exist, so nothing would ever have run.
    function test_getAssetKind_selectorIsNoLongerRoutedByTheNav() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.prank(navCalculatorManager);
        registry.setAssetKind(address(weth), AccrualKind.Appreciating);

        // Classified, so the OLD getter would have succeeded had it still been routed. A revert here therefore means
        // "no such function", not "no such asset" — which is what makes the assertion about the ABI and not the data.
        (bool ok,) = address(nav).staticcall(abi.encodeWithSignature("getAssetKind(address)", address(weth)));
        assertFalse(ok, "getAssetKind must no longer be routed by the NAV");

        (bool okNew,) = address(nav).staticcall(abi.encodeWithSignature("getAssetInfo(address)", address(weth)));
        assertTrue(okNew, "getAssetInfo replaces it");
    }
}
