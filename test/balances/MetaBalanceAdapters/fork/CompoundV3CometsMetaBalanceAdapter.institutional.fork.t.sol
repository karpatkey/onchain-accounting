// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    CompoundV3CometsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/CompoundV3CometsMetaBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IInstitutionalComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function borrowBalanceOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function collateralBalanceOf(address account, address asset) external view returns (uint128);
    function baseToken() external view returns (address);
}

/// @title Compound Institutional USDC (ciUSDCv3) through the LIVE mainnet NAV
/// @notice The BTC Carry Fund's Portfolio Safe opens a ciUSDCv3 position (WBTC and cbBTC collateral, USDC borrow)
///         on a fork, and the test reads it back through the LIVE NAV proxy and the LIVE `CompoundV3CometsMeta`
///         adapter, which already has ciUSDCv3 as an instance. No new adapter or registration is
///         involved: this pins that the existing generic Comet reader values this market correctly.
/// @dev Pricing is the NAV's own feeds (BTC/USD for WBTC, the registered cbBTC feed, USDC/USD), never the Comet's
///      `getPrice`: the adapter reports amounts only and the NAV prices them. Expected values come from the same
///      NAV's `calculateValue`, so the assertions isolate the adapter's amounts and the NAV's debt netting.
///
///      The block is pinned. The live implementation and `PriceFeedLib` at that block are the pre-#354 ones, so
///      the stale-feed case is pinned twice, by implementation rather than by observed value: once on the live
///      implementation (a stale debt valued at 0, flagged) and once with this tree's implementation etched in
///      (ADR 0029: the stale debt at its last price, flagged).
contract CompoundV3CometsMetaInstitutionalForkTest is BalanceAdapterTestBase {
    address internal constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    /// @dev `script/config/deployments/1.json` `.balanceAdapters.CompoundV3CometsMeta`.
    address internal constant COMET_META = 0xDf85833a69B74e86e38160405a12bA7356AcdCdf;
    /// @dev `script/config/deployments/1.json` `.balanceAdapters.ERC20Default` (wallet balances).
    address internal constant ERC20_DEFAULT = 0x4Bc39Dce61245F5A63189d1FA03E6D76646f1EE6;

    /// @dev Compound Institutional USDC on Ethereum (`CometWithExtendedAssetList`), base USDC,
    ///      collaterals WETH / wstETH / cbBTC / WBTC.
    address internal constant CI_USDC_V3 = 0x207158a267CBD2598BB3d611D8CBdEE2709F2F8C;
    address internal constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address internal constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    /// @dev BTC Carry Fund Portfolio Safe. It holds no ciUSDCv3 position at FORK_BLOCK.
    address internal constant SAFE = 0x0295E5d0530C23E560CdbFc097C488a0A0D7752D;
    address internal constant SINK = address(0xdEaD);

    uint256 internal constant FORK_BLOCK = 26_256_000;

    uint256 internal constant WBTC_IN = 1e8; // 1 WBTC
    uint256 internal constant CBBTC_IN = 5e7; // 0.5 cbBTC
    uint256 internal constant BORROW = 50_000e6; // 50,000 USDC
    uint256 internal constant USDC_IN = 25_000e6; // base-supply-only case

    IInstitutionalComet internal comet = IInstitutionalComet(CI_USDC_V3);
    INAVCalculator internal nav = INAVCalculator(NAV);

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    function _instance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(CI_USDC_V3)));
    }

    function _positions(address adapter) internal view returns (INAVCalculator.PositionBalance[] memory) {
        return
            CompoundV3CometsMetaBalanceAdapter(adapter).getAdapterPositionsForInstances(SAFE, _instance(), address(0));
    }

    function _slice(address[] memory adapters, address quote) internal view returns (INAVCalculator.PartialNAV memory) {
        return nav.getAccountNavForAdapters(SAFE, quote, adapters);
    }

    function _cometOnly() internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = COMET_META;
    }

    function _walletAndComet() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = ERC20_DEFAULT;
        a[1] = COMET_META;
    }

    /// @dev Value of `amount` of `asset` in `quote`, priced by the live NAV's own feeds.
    function _value(address asset, uint256 amount, address quote) internal view returns (int256 v) {
        if (amount == 0) return 0;
        address[] memory a = new address[](1);
        uint256[] memory m = new uint256[](1);
        a[0] = asset;
        m[0] = amount;
        (v,) = nav.calculateValue(a, m, quote);
    }

    function _leg(INAVCalculator.PositionBalance[] memory p, address asset)
        internal
        pure
        returns (INAVCalculator.PositionBalance memory found, bool ok)
    {
        for (uint256 i; i < p.length; ++i) {
            if (p[i].balanceAsset.asset == asset) return (p[i], true);
        }
    }

    function _contains(INAVCalculator.Asset[] memory list, address asset) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i].asset == asset) return true;
        }
        return false;
    }

    function _supply(address asset, uint256 amount) internal {
        deal(asset, SAFE, IERC20(asset).balanceOf(SAFE) + amount);
        vm.startPrank(SAFE);
        IERC20(asset).approve(CI_USDC_V3, amount);
        comet.supply(asset, amount);
        vm.stopPrank();
    }

    /// @dev Supply WBTC + cbBTC and borrow USDC from the Safe, the way the agents will (no on-behalf calls).
    function _openPosition() internal {
        _supply(WBTC, WBTC_IN);
        _supply(CBBTC, CBBTC_IN);
        vm.prank(SAFE);
        comet.withdraw(USDC, BORROW);
    }

    /// @dev collateral value - debt value, from the Comet's own balances and the NAV's own prices.
    function _expectedCometValue(address quote) internal view returns (int256) {
        return _value(WBTC, comet.collateralBalanceOf(SAFE, WBTC), quote)
            + _value(CBBTC, comet.collateralBalanceOf(SAFE, CBBTC), quote) + _value(USDC, comet.balanceOf(SAFE), quote)
            - _value(USDC, comet.borrowBalanceOf(SAFE), quote);
    }

    /// @dev Stamp every Chainlink-ABI primary and monitor feed of `asset` with `updatedAt`, keeping its last answer.
    ///      Called BEFORE a `vm.warp` with the post-warp timestamp: some feeds (RedStone) revert on a live read once
    ///      the clock has moved past their data, so the answer has to be captured first. `Custom` feeds are skipped:
    ///      the NAV reads them through `getLatestPrice()`, which a `latestRoundData` mock would not reach.
    function _refreshFeeds(address asset, uint256 updatedAt) internal {
        _stamp(IPrices(NAV).getPriceFeeds(asset), updatedAt);
        _stamp(IPrices(NAV).getMonitorFeeds(asset), updatedAt);
    }

    function _stamp(IPrices.PriceFeedConfig[] memory feeds, uint256 updatedAt) internal {
        for (uint256 i; i < feeds.length; ++i) {
            if (feeds[i].priceType == IPrices.PriceType.Custom) continue;
            AggregatorV3Interface f = AggregatorV3Interface(feeds[i].priceFeed);
            (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = f.latestRoundData();
            vm.mockCall(
                address(f),
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(roundId, answer, startedAt < updatedAt ? startedAt : updatedAt, updatedAt, answeredInRound)
            );
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Registration on the live NAV
    // ---------------------------------------------------------------------------------------------------------

    /// @notice The live NAV already reads ciUSDCv3: the adapter is registered, the comet is one of its instances,
    ///         and every asset the BTC Carry position uses is registered with a price feed.
    function test_liveNav_alreadyCoversCiUSDCv3() public view {
        assertTrue(IBalances(NAV).isAdapterRegistered(COMET_META), "CompoundV3CometsMeta not registered");
        bytes32[] memory live = IBalances(NAV).getMetaInstances(COMET_META);
        bool found;
        for (uint256 i; i < live.length; ++i) {
            if (live[i] == _instance()[0]) found = true;
        }
        assertTrue(found, "ciUSDCv3 is not an instance of the live adapter");

        assertTrue(nav.isAssetRegistered(USDC), "USDC");
        assertTrue(nav.isAssetRegistered(WBTC), "WBTC");
        assertTrue(nav.isAssetRegistered(CBBTC), "cbBTC");
        assertEq(comet.baseToken(), USDC);

        // The comet enumerates WBTC and cbBTC as collaterals, so the adapter will emit their legs.
        address[] memory supported =
            CompoundV3CometsMetaBalanceAdapter(COMET_META).underlyingAssetsSupportedForInstances(_instance());
        bool hasWbtc;
        bool hasCbbtc;
        for (uint256 i; i < supported.length; ++i) {
            if (supported[i] == WBTC) hasWbtc = true;
            if (supported[i] == CBBTC) hasCbbtc = true;
        }
        assertTrue(hasWbtc && hasCbbtc, "WBTC and cbBTC must be enumerated collaterals");
    }

    /// @notice The adapter compiled from this tree reports exactly what the deployed one does.
    function test_committedSourceMatchesDeployedAdapter() public {
        _openPosition();
        CompoundV3CometsMetaBalanceAdapter fresh = new CompoundV3CometsMetaBalanceAdapter(COMPOUND_REWARDS, COMP, NAV);
        INAVCalculator.PositionBalance[] memory a = _positions(COMET_META);
        INAVCalculator.PositionBalance[] memory b = _positions(address(fresh));
        assertEq(a.length, b.length, "leg count");
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].balanceAsset.asset, b[i].balanceAsset.asset);
            assertEq(a[i].amount, b[i].amount);
            assertEq(a[i].isDebt, b[i].isDebt);
            assertEq(uint8(a[i].positionKind), uint8(b[i].positionKind));
            assertEq(a[i].positionId, b[i].positionId);
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Position cases
    // ---------------------------------------------------------------------------------------------------------

    /// @notice No position: no legs, and the comet slice is worth zero.
    function test_zeroPosition() public view {
        assertEq(_positions(COMET_META).length, 0, "no ciUSDCv3 legs before the position is opened");
        assertEq(comet.borrowBalanceOf(SAFE), 0);
        assertEq(comet.balanceOf(SAFE), 0);
    }

    /// @notice Open WBTC + cbBTC collateral and a USDC borrow: legs match the Comet to the unit, the comet slice
    ///         is collateral value minus debt value, and the NAV moves by exactly that once the borrowed USDC leaves.
    function test_openPosition_navNetsCollateralMinusDebt() public {
        int256 sliceBefore = _slice(_cometOnly(), address(0)).value;
        int256 navBefore = _slice(_walletAndComet(), address(0)).value;

        _openPosition();

        INAVCalculator.PositionBalance[] memory p = _positions(COMET_META);
        assertEq(p.length, 3, "WBTC collateral + cbBTC collateral + USDC borrow, no rewards leg");
        (INAVCalculator.PositionBalance memory w, bool okW) = _leg(p, WBTC);
        (INAVCalculator.PositionBalance memory c, bool okC) = _leg(p, CBBTC);
        (INAVCalculator.PositionBalance memory d, bool okD) = _leg(p, USDC);
        assertTrue(okW && okC && okD, "missing leg");

        assertEq(w.amount, comet.collateralBalanceOf(SAFE, WBTC), "WBTC leg == collateralBalanceOf");
        assertEq(w.amount, WBTC_IN);
        assertFalse(w.isDebt);
        assertEq(uint8(w.positionKind), uint8(PositionKind.Collateral));

        assertEq(c.amount, comet.collateralBalanceOf(SAFE, CBBTC), "cbBTC leg == collateralBalanceOf");
        assertEq(c.amount, CBBTC_IN);
        assertEq(uint8(c.positionKind), uint8(PositionKind.Collateral));

        assertEq(d.amount, comet.borrowBalanceOf(SAFE), "USDC leg == borrowBalanceOf");
        assertGe(d.amount, BORROW);
        assertLe(d.amount, BORROW + 1, "a fresh borrow carries at most one unit of index rounding");
        assertTrue(d.isDebt);
        assertEq(uint8(d.positionKind), uint8(PositionKind.Borrowed));

        // The comet slice is collateral value minus debt value, in USD and in WBTC (the fund's unit).
        INAVCalculator.PartialNAV memory usd = _slice(_cometOnly(), address(0));
        assertEq(usd.stalePriceAssets.length, 0, "precondition: fresh feeds at FORK_BLOCK");
        assertApproxEqAbs(usd.value - sliceBefore, _expectedCometValue(address(0)), 2, "USD: collateral - debt");
        assertLt(usd.value, _value(WBTC, WBTC_IN, address(0)) + _value(CBBTC, CBBTC_IN, address(0)), "debt netted");

        INAVCalculator.PartialNAV memory inBtc = _slice(_cometOnly(), WBTC);
        assertFalse(inBtc.quoteAssetStale);
        assertApproxEqAbs(inBtc.value, _expectedCometValue(WBTC), 2, "WBTC quote: collateral - debt");
        emit log_named_decimal_int("comet slice, USD", usd.value, 8);
        emit log_named_decimal_int("comet slice, WBTC", inBtc.value, 8);
        emit log_named_decimal_uint("USDC debt", d.amount, 6);

        // Supplying from the wallet and borrowing into it are NAV-neutral (dealt BTC aside). Sending the borrowed
        // USDC away then lowers the NAV by exactly its value: the debt stays counted.
        int256 dealt = _value(WBTC, WBTC_IN, address(0)) + _value(CBBTC, CBBTC_IN, address(0));
        int256 navOpen = _slice(_walletAndComet(), address(0)).value;
        assertApproxEqAbs(navOpen - navBefore, dealt, 2, "open is NAV-neutral apart from the dealt collateral");

        vm.prank(SAFE);
        IERC20(USDC).transfer(SINK, BORROW);
        int256 navAfter = _slice(_walletAndComet(), address(0)).value;
        assertApproxEqAbs(navAfter - navOpen, -_value(USDC, BORROW, address(0)), 2, "debt still counted");
    }

    /// @notice Base supply only: one `Supplied` leg equal to the Comet's `balanceOf`, NAV-neutral move from wallet.
    function test_baseSupplyOnly() public {
        int256 navBefore = _slice(_walletAndComet(), address(0)).value;
        _supply(USDC, USDC_IN);

        INAVCalculator.PositionBalance[] memory p = _positions(COMET_META);
        assertEq(p.length, 1, "one Supplied leg");
        assertEq(p[0].balanceAsset.asset, USDC);
        assertEq(p[0].amount, comet.balanceOf(SAFE), "leg == balanceOf");
        assertApproxEqAbs(p[0].amount, USDC_IN, 1);
        assertFalse(p[0].isDebt);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));

        // The wallet is back to its starting USDC, so the NAV grows by exactly the comet balance, which Comet
        // rounds down by up to one USDC unit against the amount supplied.
        int256 navAfter = _slice(_walletAndComet(), address(0)).value;
        assertApproxEqAbs(
            navAfter - navBefore, _value(USDC, comet.balanceOf(SAFE), address(0)), 2, "only the supply is new"
        );
    }

    /// @notice Interest accrues in the view: after 30 days the debt leg equals the Comet's accrued
    ///         `borrowBalanceOf`, has grown, and the NAV nets the larger debt.
    function test_interestAccrual_overWarp() public {
        _openPosition();
        uint256 debt0 = comet.borrowBalanceOf(SAFE);

        uint256 later = block.timestamp + 30 days;
        _refreshFeeds(WBTC, later);
        _refreshFeeds(CBBTC, later);
        _refreshFeeds(USDC, later);
        vm.warp(later);
        vm.roll(block.number + 30 * 7200);

        uint256 debt1 = comet.borrowBalanceOf(SAFE);
        assertGt(debt1, debt0, "borrow interest accrued");
        emit log_named_decimal_uint("debt after 30 days", debt1, 6);
        (INAVCalculator.PositionBalance memory d,) = _leg(_positions(COMET_META), USDC);
        assertEq(d.amount, debt1, "adapter accrues exactly like borrowBalanceOf, without a state-changing accrue");

        INAVCalculator.PartialNAV memory usd = _slice(_cometOnly(), address(0));
        assertEq(usd.stalePriceAssets.length, 0, "feeds re-stamped fresh");
        assertApproxEqAbs(usd.value, _expectedCometValue(address(0)), 2, "NAV nets the accrued debt");
    }

    /// @notice The same accrual on the supply side.
    function test_interestAccrual_baseSupply() public {
        _supply(USDC, USDC_IN);
        uint256 bal0 = comet.balanceOf(SAFE);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 * 7200);

        uint256 bal1 = comet.balanceOf(SAFE);
        assertGt(bal1, bal0, "supply interest accrued");
        assertEq(_positions(COMET_META)[0].amount, bal1, "adapter == balanceOf after accrual");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Stale and missing feeds
    // ---------------------------------------------------------------------------------------------------------

    /// @notice LIVE implementation at FORK_BLOCK (pre-#354): a stale USDC feed values the debt at 0, but never
    ///         silently — the adapter still emits the full debt leg and USDC is in `stalePriceAssets`.
    function test_staleDebtFeed_liveLibrary_valuedAtZeroAndFlagged() public {
        (int256 collateralValue,, INAVCalculator.PartialNAV memory s) = _staleUsdcDebt();
        assertEq(s.value, collateralValue, "pre-#354 library: the stale debt is valued at 0 (and flagged)");
    }

    /// @notice THIS TREE's implementation (ADR 0029, #354) etched in: the same stale USDC debt is subtracted at its
    ///         last price and still flagged. Pinned by implementation, so a regression that drops the stale debt
    ///         under the new library fails here instead of passing as the pre-#354 arm.
    function test_staleDebtFeed_adr0029_valuedAtLastPriceAndFlagged() public {
        _useNewNavImpl(NAV);
        (int256 collateralValue, int256 debtAtLastPrice, INAVCalculator.PartialNAV memory s) = _staleUsdcDebt();
        assertApproxEqAbs(s.value, collateralValue - debtAtLastPrice, 2, "ADR 0029: stale debt at last price");
    }

    /// @dev Opens the position, makes every Chainlink-ABI USDC feed two days old (under the 7-day cap, so the new
    ///      library treats it as usable-stale) and returns the comet slice, after asserting what holds under both
    ///      implementations: the full debt leg is emitted and USDC (only) is flagged stale.
    function _staleUsdcDebt()
        internal
        returns (int256 collateralValue, int256 debtAtLastPrice, INAVCalculator.PartialNAV memory s)
    {
        _openPosition();
        collateralValue = _value(WBTC, WBTC_IN, address(0)) + _value(CBBTC, CBBTC_IN, address(0));
        debtAtLastPrice = _value(USDC, comet.borrowBalanceOf(SAFE), address(0));

        // Make every USDC feed (primary and monitor) two days old; BTC feeds stay fresh.
        _stamp(IPrices(NAV).getPriceFeeds(USDC), block.timestamp - 2 days);
        _stamp(IPrices(NAV).getMonitorFeeds(USDC), block.timestamp - 2 days);

        (INAVCalculator.PositionBalance memory d, bool ok) = _leg(_positions(COMET_META), USDC);
        assertTrue(ok && d.isDebt, "the debt leg is emitted whatever its price");
        assertEq(d.amount, comet.borrowBalanceOf(SAFE));

        s = _slice(_cometOnly(), address(0));
        assertTrue(_contains(s.stalePriceAssets, USDC), "a stale debt asset is always flagged");
        assertFalse(_contains(s.stalePriceAssets, WBTC), "WBTC is fresh");
    }

    /// @notice Missing feed, debt side: if the base (USDC) is not registered, the whole comet position is dropped
    ///         rather than reporting the BTC collateral without its debt (which would over-report by the borrow).
    function test_unregisteredBase_dropsWholePositionNotJustTheDebt() public {
        _openPosition();
        address[] memory onlyBtc = new address[](2);
        onlyBtc[0] = WBTC;
        onlyBtc[1] = CBBTC;
        balances = _deployBalancesForAdapter(onlyBtc);
        CompoundV3CometsMetaBalanceAdapter a =
            new CompoundV3CometsMetaBalanceAdapter(COMPOUND_REWARDS, COMP, address(balances));
        assertEq(a.getAdapterPositionsForInstances(SAFE, _instance(), address(0)).length, 0);
    }

    /// @notice Missing feed, collateral side: if a collateral is not registered, its leg is dropped and the debt
    ///         stays, so the NAV can only under-report.
    function test_unregisteredCollateral_keepsTheDebt() public {
        _openPosition();
        address[] memory noCbbtc = new address[](2);
        noCbbtc[0] = USDC;
        noCbbtc[1] = WBTC;
        balances = _deployBalancesForAdapter(noCbbtc);
        CompoundV3CometsMetaBalanceAdapter a =
            new CompoundV3CometsMetaBalanceAdapter(COMPOUND_REWARDS, COMP, address(balances));
        INAVCalculator.PositionBalance[] memory p = a.getAdapterPositionsForInstances(SAFE, _instance(), address(0));
        assertEq(p.length, 2, "WBTC collateral + USDC debt; cbBTC dropped");
        (, bool hasCbbtc) = _leg(p, CBBTC);
        assertFalse(hasCbbtc);
        (INAVCalculator.PositionBalance memory d, bool okD) = _leg(p, USDC);
        assertTrue(okD && d.isDebt, "debt kept");
        assertEq(d.amount, comet.borrowBalanceOf(SAFE));
    }
}
