// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/Test.sol";
import {SuperTest} from "test/SuperTest.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {AccrualKind} from "src/utils/AssetKind.sol";
import {MANAGER} from "src/constants.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title The unregister→re-register window, exercised
/// @notice The repair path that {AssetKindRegistry-setAssetLabels} replaces requires unregistering the asset first.
///         This pins what a NAV read actually DOES mid-window when an adapter still reports a position denominated in
///         the now-unregistered asset — the one thing the design analysis traced in code but never ran.
/// @dev The distinction matters operationally. A REVERT is loud and self-announcing: every consumer sees the read
///      fail and nobody acts on a wrong number. A SILENT DROP is the dangerous outcome — NAV returns a smaller,
///      plausible figure with no error and no flag, and a consumer cannot tell the asset was omitted from an asset
///      that is genuinely worth nothing.
contract AssetUnregisterWindowTest is SuperTest {
    Mock_ERC20 internal tok;
    Mock_CustomBalanceAdapter internal adapter;

    function setUp() public {
        setupAll();
        tok = new Mock_ERC20("WINDOW", 18);

        address feed = address(new Mock_PriceOracleChainlink("W/USD", 2000e8, 8));
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(tok), feed, IPrices.PriceType.Chainlink, type(uint256).max);

        // An adapter that reports a position denominated in `tok`, and keeps reporting it after unregistration —
        // exactly the state a meta-adapter is in mid-window, since adapters are immutable and know nothing about
        // the NAV's asset registry.
        adapter = new Mock_CustomBalanceAdapter();
        address[] memory supported = new address[](1);
        supported[0] = address(tok);
        adapter.setUnderlyingAssetsSupported(supported);
        adapter.setBalance(address(tok), alice, 3e18, false);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(adapters);
    }

    function test_midWindow_navReadWithPositionInUnregisteredAsset() public {
        INAVCalculator.NAV memory before = nav.getAccountNav(alice, address(0));
        console2.log("BEFORE  nav totalValue:", uint256(before.value));

        assertGt(before.value, 0, "the position is priced while the asset is registered");

        // THE WINDOW OPENS. This is transaction 1 of the old repair path.
        vm.prank(navCalculatorManager);
        nav.unregisterAsset(address(tok));
        assertFalse(nav.isAssetRegistered(address(tok)), "asset is out of the registry");

        // The adapter is immutable and still reports the position.
        (uint256 amt,) = adapter.balanceOf(address(tok), alice);
        assertEq(amt, 3e18, "adapter still reports the position mid-window");

        // Does the NAV read revert, or silently drop it? PIN THE ANSWER — an earlier revision of this test only
        // logged the branch it took, which meant it passed whether the read reverted, returned zero, or returned a
        // flagged non-zero. It measured the behaviour without asserting it, so nothing would have gone red if the
        // behaviour changed. Each of the three assertions below is a separate claim about the SAME failure:
        //   ok            — it does NOT revert (a revert would be the benign outcome, and would fail this)
        //   value == 0    — the position is dropped entirely, not repriced or partially counted
        //   stale empty   — and nothing marks it, so the zero is indistinguishable from a genuinely empty account
        // If any of the three ever flips, the mid-window behaviour has changed and this test must be re-read, not
        // re-baselined.
        (bool ok, bytes memory ret) =
            address(nav).staticcall(abi.encodeCall(INAVCalculator.getAccountNav, (alice, address(0))));
        assertTrue(ok, "MEASURED: the mid-window read does NOT revert - it succeeds");

        INAVCalculator.NAV memory during = abi.decode(ret, (INAVCalculator.NAV));
        assertEq(during.value, 0, "MEASURED: the position is silently dropped - NAV falls to zero");
        assertEq(during.stalePriceAssets.length, 0, "MEASURED: nothing is flagged - stalePriceAssets stays empty");
        assertFalse(during.sequencerDown, "and no sequencer flag either");

        // The whole point, stated as an assertion rather than a log: a healthy-looking zero.
        assertLt(during.value, before.value, "the reported NAV collapsed while the account's holdings did not");
    }

    /// @notice The PR's headline claim, proved against a REAL `NAVCalculator` rather than a mock: correcting a label
    ///         with {AssetKindRegistry-setAssetLabels} leaves the asset's pricing configuration untouched.
    /// @dev This arm exists because the claim was otherwise only tested against `MockNav`, which holds no feed state
    ///      at all — so nothing anywhere asserted the thing the change is FOR. The contrast with
    ///      {test_midWindow_navReadWithPositionInUnregisteredAsset} above is the whole argument for the setter: the
    ///      old repair path drops every one of these, this one drops none.
    function test_setAssetLabels_leavesPricingConfigurationIntact() public {
        AssetKindRegistry registry = new AssetKindRegistry(address(nav));
        vm.prank(admin);
        nav.grantRole(MANAGER, address(registry));

        Mock_ERC20 lbl = new Mock_ERC20("LBL", 18);
        address primary = address(new Mock_PriceOracleChainlink("L/USD", 1e8, 8));
        address monitor = address(new Mock_PriceOracleChainlink("L/USD monitor", 1e8, 8));

        string[] memory before_ = new string[](2);
        before_[0] = "Protocol";
        before_[1] = "TYPO";
        vm.startPrank(navCalculatorManager);
        registry.registerAsset(
            address(lbl), primary, IPrices.PriceType.Chainlink, type(uint256).max, AccrualKind.None, before_
        );
        nav.setDivergenceTolerance(address(lbl), 250);
        nav.setPegTolerance(address(lbl), 100);
        nav.addMonitorFeed(address(lbl), monitor, IPrices.PriceType.Chainlink, 86_400);
        vm.stopPrank();

        uint256 feedsBefore = nav.getPriceFeedCount(address(lbl));
        uint256 monitorsBefore = nav.getMonitorFeedCount(address(lbl));
        IPrices.AssetPricing memory pricingBefore = nav.getAssetPricing(address(lbl));
        (int256 priceBefore,,,) = nav.latestPrice(address(lbl));

        string[] memory fixed_ = new string[](2);
        fixed_[0] = "Protocol";
        fixed_[1] = "CORRECT";
        vm.prank(navCalculatorManager);
        registry.setAssetLabels(address(lbl), fixed_);

        assertEq(registry.getAssetLabels(address(lbl))[1], "CORRECT", "the label was actually corrected");
        assertTrue(nav.isAssetRegistered(address(lbl)), "asset never left the NAV");
        assertEq(nav.getPriceFeedCount(address(lbl)), feedsBefore, "price feeds intact");
        assertEq(nav.getMonitorFeedCount(address(lbl)), monitorsBefore, "monitor feeds intact");
        IPrices.AssetPricing memory pricingAfter = nav.getAssetPricing(address(lbl));
        assertEq(
            pricingAfter.divergenceToleranceBps, pricingBefore.divergenceToleranceBps, "divergence tolerance intact"
        );
        assertEq(
            pricingAfter.pegToleranceBps,
            pricingBefore.pegToleranceBps,
            "peg tolerance intact - PegKind is derived from it"
        );
        (int256 priceAfter,,,) = nav.latestPrice(address(lbl));
        assertEq(priceAfter, priceBefore, "the asset still prices identically");
    }
}
