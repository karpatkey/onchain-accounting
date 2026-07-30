// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SuperTest} from "test/SuperTest.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title PoC — `PriceFeedLib._sumPositionValues` is a behaviour-preserving extraction (commit 8b7f3d22)
/// @notice Commit 8b7f3d22 lifted the per-position valuation loop out of `PriceFeedLib.computeNav` into a new
///         `private view` helper `_sumPositionValues`, purely to free a `via_ir` stack slot. Nothing about the
///         summation was supposed to change. This file is the executed check of that claim.
///
///         The oracle is `computeNavAndPositions` / `getAccountNavVerbose`, which the delta did NOT touch: it keeps
///         its own, structurally independent copy of the valuation walk (`_enrichAll` → `_enrichPosition`) with its
///         own argument threading, its own iteration and its own accumulator. The two share only the leaf
///         arithmetic (`_priceConversion`) — which is exactly right here, because the delta moved threading,
///         iteration and accumulation and left the arithmetic alone. Any dropped, swapped, mis-scoped or
///         wrongly-signed argument in the extraction shows up as `getAccountNav` disagreeing with
///         `getAccountNavVerbose`.
///
///         To close the shared-arithmetic blind spot, {test_E1_usdNav_matchesIndependentlyComputedTotal} also pins
///         the total against a hand-derived literal, so the pair cannot agree on a wrong number.
///
///         Scenario is deliberately hostile to argument threading: five positions across three balance adapters,
///         canonical token decimals of 2 / 6 / 8 / 18 (so `_getRegisteredAsset(...).decimals` differs per row and a
///         swapped `assetIndex` / `registeredAssets` pair mis-scales), a feed whose price differs per asset (so a
///         mis-threaded `priceFeeds` cache mis-prices), and both credit and debt legs (so a lost `isDebt` flips a
///         sign). Assets are registered in a different order than they are held.
contract PoC_ComputeNavEquivalence is SuperTest {
    Mock_ERC20 internal tk8; // 8-decimal token
    Mock_ERC20 internal tk2; // 2-decimal token

    Mock_CustomPriceFeed internal tk8Feed;
    Mock_CustomPriceFeed internal tk2Feed;

    Mock_CustomBalanceAdapter internal adapterA;
    Mock_CustomBalanceAdapter internal adapterB;

    // Held amounts, in each token's own decimals.
    uint256 internal constant USDC_AMT = 1_234_567; // 1.234567 USDC  (6 dp)
    uint256 internal constant WETH_AMT = 5e17; // 0.5 WETH       (18 dp)
    uint256 internal constant DAI_DEBT = 2_000e18; // 2000 DAI DEBT  (18 dp)
    uint256 internal constant TK8_AMT = 3e8; // 3.0 TK8        (8 dp)
    uint256 internal constant TK2_DEBT = 1234; // 12.34 TK2 DEBT (2 dp)

    // Feed prices, all 8-dp.
    int256 internal constant USDC_PX = 1e8; // $1.00
    int256 internal constant DAI_PX = 1e8; // $1.00
    int256 internal constant WETH_PX = 324_057_000_000; // $3240.57  (SuperTest default)
    int256 internal constant TK8_PX = 12_345_678; // $0.12345678
    int256 internal constant TK2_PX = 777_000_000; // $7.77

    function setUp() public {
        setupAll();

        tk8 = new Mock_ERC20("TK8", 8);
        tk2 = new Mock_ERC20("TK2", 2);
        vm.label(address(tk8), "TK8");
        vm.label(address(tk2), "TK2");

        tk8Feed = new Mock_CustomPriceFeed("TK8", address(tk8), uint256(TK8_PX), 8);
        tk2Feed = new Mock_CustomPriceFeed("TK2", address(tk2), uint256(TK2_PX), 8);

        // Register in an order unrelated to the holding order, so a confused index cannot pass by coincidence.
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(tk2), address(tk2Feed), IPrices.PriceType.Custom, type(uint256).max);
        nav.registerAsset(address(tk8), address(tk8Feed), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        adapterA = new Mock_CustomBalanceAdapter();
        adapterB = new Mock_CustomBalanceAdapter();

        address[] memory aAssets = new address[](2);
        aAssets[0] = address(usdc);
        aAssets[1] = address(weth);
        adapterA.setUnderlyingAssetsSupported(aAssets);
        adapterA.setBalance(address(usdc), safe, USDC_AMT, false);
        adapterA.setBalance(address(weth), safe, WETH_AMT, false);

        address[] memory bAssets = new address[](3);
        bAssets[0] = address(dai);
        bAssets[1] = address(tk8);
        bAssets[2] = address(tk2);
        adapterB.setUnderlyingAssetsSupported(bAssets);
        adapterB.setBalance(address(dai), safe, DAI_DEBT, true);
        adapterB.setBalance(address(tk8), safe, TK8_AMT, false);
        adapterB.setBalance(address(tk2), safe, TK2_DEBT, true);

        address[] memory adapters = new address[](2);
        adapters[0] = address(adapterA);
        adapters[1] = address(adapterB);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(adapters);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev Independent restatement of the USD leg of `_priceConversion`, written from the formula rather than by
    ///      calling the library, so agreement is not circular. NAV_DECIMALS is 8.
    function _usdValue(uint256 amount, bool isDebt, uint8 tokenDecimals, int256 price) internal pure returns (int256) {
        int256 signed = isDebt ? -int256(amount) : int256(amount);
        return (signed * price) / int256(10 ** (uint256(tokenDecimals) + 8 - 8));
    }

    function _sumVerbosePositionValues(INAVCalculator.VerbosePosition[] memory ps) internal pure returns (int256 s) {
        for (uint256 i = 0; i < ps.length; i++) {
            s += ps[i].position.value;
        }
    }

    // =========================================================================
    // E1 — the extracted sum, against a hand-derived total (USD quote)
    // =========================================================================

    /// @notice `getAccountNav` in USD equals a total derived by hand from the five held legs. Pins the accumulator
    ///         and every per-row argument at once, independently of the verbose path.
    function test_E1_usdNav_matchesIndependentlyComputedTotal() public view {
        int256 expected = _usdValue(USDC_AMT, false, 6, USDC_PX) + _usdValue(WETH_AMT, false, 18, WETH_PX)
            + _usdValue(DAI_DEBT, true, 18, DAI_PX) + _usdValue(TK8_AMT, false, 8, TK8_PX)
            + _usdValue(TK2_DEBT, true, 2, TK2_PX);

        // Belt and braces: the same figure as a literal, so a drift in the helper cannot silently track a drift in
        // the library. -$473.99186266, expressed in NAV_DECIMALS (8).
        assertEq(expected, -47_399_186_266, "hand-derived total must equal the pinned literal");

        INAVCalculator.NAV memory n = nav.getAccountNav(safe, address(0));
        assertEq(n.value, expected, "computeNav/_sumPositionValues total");

        // Non-vacuity: the scenario must actually be summing something signed and non-trivial.
        assertLt(n.value, int256(0), "scenario must be net debt (proves isDebt threading survives)");
        assertTrue(n.value != 0, "scenario must not be empty");
    }

    // =========================================================================
    // E2 — differential: extracted loop vs the untouched enrichment loop
    // =========================================================================

    /// @notice `getAccountNav` (extracted `_sumPositionValues`) equals `getAccountNavVerbose` (untouched
    ///         `_enrichAll`), and equals the element-wise sum of the verbose per-position values. USD quote.
    function test_E2_plainNavEqualsVerboseNav_usdQuote() public view {
        INAVCalculator.NAV memory plain = nav.getAccountNav(safe, address(0));
        INAVCalculator.VerboseNAV memory verbose = nav.getAccountNavVerbose(safe, address(0));

        assertEq(plain.value, verbose.nav.value, "plain vs verbose total (USD)");
        assertEq(
            plain.value,
            _sumVerbosePositionValues(verbose.positions),
            "plain total vs element-wise sum of verbose position values (USD)"
        );

        // Non-vacuity: the verbose walk must have seen the five funded legs (plus any zero-amount
        // ERC20Default rows, which contribute nothing).
        assertGe(verbose.positions.length, 5, "verbose walk must cover all five funded legs");
        assertTrue(plain.value != 0, "must not be comparing zero to zero");
    }

    /// @notice Same differential with a NON-USD quote asset, which is the only thing that exercises the
    ///         `quoteInfo.price` / `quoteInfo.priceDecimals` / `quoteInfo.assetDecimals` arguments the extraction
    ///         now passes across a function boundary as a memory struct.
    function test_E2_plainNavEqualsVerboseNav_wethQuote() public view {
        INAVCalculator.NAV memory plain = nav.getAccountNav(safe, address(weth));
        INAVCalculator.VerboseNAV memory verbose = nav.getAccountNavVerbose(safe, address(weth));

        assertEq(plain.value, verbose.nav.value, "plain vs verbose total (WETH quote)");
        assertEq(
            plain.value,
            _sumVerbosePositionValues(verbose.positions),
            "plain total vs element-wise sum of verbose position values (WETH quote)"
        );

        // The quote conversion must actually have happened — a WETH-quoted total cannot equal the USD one here.
        INAVCalculator.NAV memory usd = nav.getAccountNav(safe, address(0));
        assertTrue(plain.value != usd.value, "quote conversion must be live, else the test is vacuous");
        assertTrue(plain.value != 0, "must not be comparing zero to zero");
        assertEq(plain.quoteAsset.asset, address(weth), "quote asset threaded through");
    }

    // =========================================================================
    // E3 — accumulator behaviour across differing array lengths
    // =========================================================================

    /// @notice The same `_sumPositionValues` is the paginated read. Summing disjoint adapter slices must reproduce
    ///         the complete NAV, which pins the accumulator's behaviour at three different `allPositions.length`
    ///         values (including the boundary shapes the extraction's loop bounds control).
    function test_E3_sliceSumEqualsCompleteNav() public view {
        address[] memory all = nav.getAllAdapters();
        assertEq(all.length, 3, "ERC20Default + adapterA + adapterB");

        address[] memory s1 = new address[](2);
        s1[0] = all[0];
        s1[1] = address(adapterA);

        address[] memory s2 = new address[](1);
        s2[0] = address(adapterB);

        INAVCalculator.PartialNAV memory p1 = nav.getAccountNavForAdapters(safe, address(0), s1);
        INAVCalculator.PartialNAV memory p2 = nav.getAccountNavForAdapters(safe, address(0), s2);
        INAVCalculator.NAV memory whole = nav.getAccountNav(safe, address(0));

        assertEq(p1.value + p2.value, whole.value, "sum of slices == complete NAV");

        // Non-vacuity: both slices must carry weight, and with opposite signs.
        assertGt(p1.value, int256(0), "slice 1 is net credit");
        assertLt(p2.value, int256(0), "slice 2 is net debt");
    }

    /// @notice Loop-bound edge: an adapter slice that yields ZERO positions must sum to exactly zero, and adding it
    ///         to the other slices must be a no-op. Covers the `positionsLength == 0` path of the extracted loop.
    function test_E3_emptySliceSumsToZero() public {
        Mock_CustomBalanceAdapter empty = new Mock_CustomBalanceAdapter();
        address[] memory eAssets = new address[](1);
        eAssets[0] = address(usdc);
        empty.setUnderlyingAssetsSupported(eAssets);
        // No balances set → adapter reports nothing for `safe`.

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(empty);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(toAdd);

        address[] memory justEmpty = new address[](1);
        justEmpty[0] = address(empty);
        INAVCalculator.PartialNAV memory pe = nav.getAccountNavForAdapters(safe, address(0), justEmpty);
        assertEq(pe.value, int256(0), "empty slice contributes exactly zero");

        // And the complete NAV is unchanged by its presence.
        INAVCalculator.NAV memory whole = nav.getAccountNav(safe, address(0));
        assertEq(whole.value, -47_399_186_266, "complete NAV unchanged by an empty adapter");
    }

    /// @notice Single-position slice: the smallest non-empty loop. Its value must equal the hand-derived value of
    ///         that one leg, so the extraction's first-iteration behaviour is pinned on its own.
    function test_E3_singlePositionSliceMatchesItsOwnLeg() public {
        Mock_CustomBalanceAdapter solo = new Mock_CustomBalanceAdapter();
        address[] memory sAssets = new address[](1);
        sAssets[0] = address(tk2);
        solo.setUnderlyingAssetsSupported(sAssets);
        solo.setBalance(address(tk2), safe, TK2_DEBT, true);

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(solo);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(toAdd);

        address[] memory justSolo = new address[](1);
        justSolo[0] = address(solo);
        INAVCalculator.PartialNAV memory ps = nav.getAccountNavForAdapters(safe, address(0), justSolo);

        assertEq(ps.value, _usdValue(TK2_DEBT, true, 2, TK2_PX), "single-leg slice value");
        assertEq(ps.value, -9_588_180_000, "single-leg slice value, pinned literal");
    }

    // =========================================================================
    // E4 — the extraction must not have desensitised the sum to its inputs
    // =========================================================================

    /// @notice A price change on ONE asset must move the total by exactly that leg's delta, on both the plain and
    ///         the verbose path. Proves the extracted loop still reads `priceFeeds` per row rather than, say,
    ///         caching one feed outside the loop.
    function test_E4_perAssetPriceChangeMovesTotalByExactlyThatLeg() public {
        int256 before = nav.getAccountNav(safe, address(0)).value;

        tk8Feed.setPrice(uint256(TK8_PX) * 2);

        int256 afterPlain = nav.getAccountNav(safe, address(0)).value;
        int256 afterVerbose = nav.getAccountNavVerbose(safe, address(0)).nav.value;

        int256 delta = _usdValue(TK8_AMT, false, 8, TK8_PX); // doubling adds one more of the same leg
        assertEq(afterPlain - before, delta, "plain path tracks the per-asset price change");
        assertEq(afterVerbose, afterPlain, "verbose path agrees after the change");
        assertTrue(delta != 0, "delta must be non-zero, else the assertion is vacuous");
    }

    /// @notice Flipping one leg's `isDebt` must move the total by exactly twice that leg, on both paths. Proves the
    ///         sign argument still reaches `_priceConversion` per row.
    function test_E4_debtFlipMovesTotalByTwiceThatLeg() public {
        int256 before = nav.getAccountNav(safe, address(0)).value;

        adapterB.setBalance(address(dai), safe, DAI_DEBT, false); // debt → credit

        int256 afterPlain = nav.getAccountNav(safe, address(0)).value;
        int256 afterVerbose = nav.getAccountNavVerbose(safe, address(0)).nav.value;

        int256 leg = _usdValue(DAI_DEBT, false, 18, DAI_PX);
        assertEq(afterPlain - before, 2 * leg, "plain path tracks the isDebt flip");
        assertEq(afterVerbose, afterPlain, "verbose path agrees after the flip");
        assertGt(afterPlain, before, "flip must increase the NAV");
    }
}
