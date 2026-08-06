// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/Test.sol";
import {SuperTest} from "test/SuperTest.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
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

        // Does the NAV read revert, or silently drop it?
        (bool ok, bytes memory ret) =
            address(nav).staticcall(abi.encodeCall(INAVCalculator.getAccountNav, (alice, address(0))));
        console2.log("MID-WINDOW getAccountNav succeeded:", ok);
        if (ok) {
            INAVCalculator.NAV memory during = abi.decode(ret, (INAVCalculator.NAV));
            console2.log("MID-WINDOW nav totalValue:", uint256(during.value));

            console2.log("MID-WINDOW stalePriceAssets:", during.stalePriceAssets.length);
            console2.log("VERDICT: SILENT DROP - read succeeds, position omitted, no error");
        } else {
            console2.log("MID-WINDOW returndata length:", ret.length);
            if (ret.length >= 4) {
                console2.log("MID-WINDOW revert selector:");
                console2.logBytes4(bytes4(ret));
            }
            console2.log("VERDICT: REVERT - the read fails loudly");
        }
    }
}
