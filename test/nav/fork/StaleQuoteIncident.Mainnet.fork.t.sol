// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title Replay of the 2026-10-10 stale-quote incident (#351, ADR 0029)
/// @notice At mainnet block 26161132 the Chainlink BTC/USD feed was 3,612 s old against a 3,600 s heartbeat, so every
///         WBTC feed was stale. The deployed (pre-ADR-0029) NAV then valued the account's ~4.78 WBTC of positions at 0
///         AND, with the quote asset unpriced, returned the remaining USD sum as if it were WBTC:
///         `getAccountNav(ACCOUNT, WBTC).value == 194871206` ("1.9487 WBTC"). Two blocks earlier (26161130, feed
///         3,588 s old, fresh) it read 477998010 (4.78 WBTC). Both readings were confirmed with `cast` against the
///         live proxy.
/// @dev Upgrades the live proxy on the fork to THIS build (`_useNewNavImpl` etches the new PriceFeedLib and
///      NAVRegistryLib at their pinned addresses and the new NAVCalculator runtime at the proxy's implementation —
///      NAVCalculator's own bytecode changed too, since `irregularForSelected` became `public`). Storage is read
///      unchanged, so the live feed and adapter configuration is what is being priced.
contract StaleQuoteIncidentMainnetForkTest is TestEnvConfigurator {
    address internal constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214; // live NAVCalculator proxy
    address internal constant ACCOUNT = 0x0295E5d0530C23E560CdbFc097C488a0A0D7752D;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    uint256 internal constant STALE_BLOCK = 26_161_132; // BTC/USD age 3,612 s > 3,600 s heartbeat
    uint256 internal constant FRESH_BLOCK = 26_161_130; // BTC/USD age 3,588 s
    int256 internal constant FRESH_READING = 477_998_010; // the live NAV at FRESH_BLOCK (4.78 WBTC, 8 dp)
    int256 internal constant BROKEN_READING = 194_871_206; // the live (old) NAV at STALE_BLOCK

    function _fork(uint256 blockNumber) internal {
        createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), blockNumber);
    }

    function _contains(INAVCalculator.Asset[] memory list, address asset) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].asset == asset) return true;
        }
        return false;
    }

    function _sum(INAVCalculator.Position[] memory ps) internal pure returns (int256 s) {
        for (uint256 i = 0; i < ps.length; i++) {
            s += ps[i].value;
        }
    }

    /// @dev Pins the incident itself on the UNMODIFIED live NAV, so the replay below is known to start from the bug.
    function test_liveNav_reproducesTheIncident() public {
        _fork(STALE_BLOCK);
        INAVCalculator.NAV memory r = INAVCalculator(NAV).getAccountNav(ACCOUNT, WBTC);
        assertEq(r.value, BROKEN_READING, "the live NAV returned the USD remainder labelled as WBTC");
        assertTrue(r.quoteAssetStale);
    }

    /// @dev Control: at the fresh block the new build reads exactly what the live NAV read.
    function test_freshBlock_newBuildMatchesLive() public {
        _fork(FRESH_BLOCK);
        assertEq(INAVCalculator(NAV).getAccountNav(ACCOUNT, WBTC).value, FRESH_READING, "live control");
        _useNewNavImpl(NAV);

        INAVCalculator.NAV memory r = INAVCalculator(NAV).getAccountNav(ACCOUNT, WBTC);
        assertEq(r.value, FRESH_READING, "a fresh read is unchanged by ADR 0029");
        assertFalse(r.quoteAssetStale);
        assertFalse(_contains(r.stalePriceAssets, WBTC));
    }

    /// @dev The fix: at the stale block the new build values the WBTC at its last-known price and keeps the result
    ///      in WBTC units — ~4.78 WBTC, flagged, consistent with the positions — instead of "1.9487 WBTC".
    function test_staleBlock_newBuildKeepsValueInQuoteUnits() public {
        _fork(STALE_BLOCK);
        _useNewNavImpl(NAV);
        INAVCalculator nav = INAVCalculator(NAV);

        INAVCalculator.PriceFeedData memory pd = nav.getPriceData(WBTC);
        assertTrue(pd.stale, "precondition: WBTC is stale at this block");
        assertEq(pd.healthyFeedCount, 0);
        assertGt(pd.price, 0, "the stale WBTC feed still supplies its last price");

        INAVCalculator.NAV memory r = nav.getAccountNav(ACCOUNT, WBTC);
        emit log_named_int("NAV in WBTC (8 dp) at the stale block", r.value);
        assertTrue(r.quoteAssetStale, "quote flagged stale");
        assertTrue(_contains(r.stalePriceAssets, WBTC), "WBTC listed in stalePriceAssets");
        assertTrue(r.value != BROKEN_READING, "not the broken reading");
        // Same BTC/USD round as the fresh block (no update in between), so only the USD legs can move: within 0.1%.
        assertApproxEqRel(r.value, FRESH_READING, 1e15, "~4.78 WBTC, matching the fresh read");

        INAVCalculator.Position[] memory ps = nav.getAccountPositions(ACCOUNT, WBTC);
        assertEq(_sum(ps), r.value, "value == sum of positions");
        for (uint256 i = 0; i < ps.length; i++) {
            assertTrue(ps[i].quoteAssetStale, "every position carries quoteAssetStale");
        }
        assertEq(nav.getAccountNavVerbose(ACCOUNT, WBTC).nav.value, r.value, "verbose == NAV");
        assertEq(nav.getAccountNavForAdapters(ACCOUNT, WBTC, nav.getAllAdapters()).value, r.value, "slice == NAV");
    }
}
