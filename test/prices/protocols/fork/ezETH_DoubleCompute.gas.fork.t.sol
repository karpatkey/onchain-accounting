// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ezETH_CustomPriceFeed} from "src/prices/protocols/ezETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {console2} from "forge-std/console2.sol";

interface IRestakeManagerTVL {
    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);
}

/// @title ezETH double-_compute gas measurement (audit finding #7)
/// @notice Quantifies the cost of `PriceFeedLib._selectFeedCore` calling BOTH `getLatestPrice()` and
///         `latestRoundData()` on a Custom feed, each of which re-runs the full `_compute()` — and therefore
///         re-runs `ezETH_CustomPriceFeed._rate()`, i.e. Renzo's `calculateTVLs()`.
/// @dev MEASUREMENT, not a regression pin. Every figure here is REPORTED via `console2` and the only
///      assertions are loose headroom bounds, deliberately:
///
///      - Warm/cold state makes absolute gas figures unstable, and this repo has been burned by pinning a
///        warm number as if it were a worst case. Both are printed so a reader can see the spread rather
///        than inherit one of them.
///      - Renzo's `calculateTVLs()` iterates every operator delegator x collateral token, so its cost GROWS
///        with Renzo's operator set. A tight assertion here would fail on Renzo's schedule, not ours.
///
///      The bounds that ARE asserted are the ones the finding turns on: that a single ezETH price read stays
///      far enough under the ~30M-gas complete-NAV-read budget that the doubling cannot starve it. If those
///      ever trip, the conclusion "measured, documented, no action" has expired.
contract ezETH_DoubleComputeGasForkTest is TestEnvConfigurator {
    ezETH_CustomPriceFeed oracle;

    address constant EZETH = 0xbf5495Efe5DB9ce00f80364C8B423567e58d2110;
    address constant RESTAKE_MANAGER = 0x74a09653A083691711cF8215a6ab074BB4e99ef5;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    uint256 constant FORK_BLOCK = 25_491_000;

    /// @dev The complete-read budget the NAV path is engineered against (~30M measured for a full
    ///      `getAccountNav`). One asset's price read consuming a large fraction of this is what would make
    ///      the doubling dangerous rather than merely wasteful.
    uint256 constant COMPLETE_READ_BUDGET = 30_000_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);
        oracle = new ezETH_CustomPriceFeed(EZETH, RESTAKE_MANAGER, NAV, WETH);
    }

    // External wrappers so each measurement pays a real call frame and cannot be inlined away.
    function callTVLs() external view returns (uint256) {
        (,, uint256 t) = IRestakeManagerTVL(RESTAKE_MANAGER).calculateTVLs();
        return t;
    }

    function callGetLatestPrice() external view returns (uint256 p, bool s) {
        return oracle.getLatestPrice();
    }

    function callLatestRoundData() external view returns (uint256 u) {
        (,,, u,) = oracle.latestRoundData();
    }

    function callGetPriceData(address asset) external view returns (int256) {
        return INAVCalculator(NAV).getPriceData(asset).price;
    }

    function _gas(bytes memory call_) internal returns (uint256 used, bool ok) {
        uint256 before = gasleft();
        (ok,) = address(this).call(call_);
        used = before - gasleft();
    }

    /// @notice Reports the isolated cost of each leg, and what the second `_compute()` actually buys.
    function test_report_doubleComputeCost() public {
        // Cold first, then warm: the delta is storage/account warming inside Renzo, not our doing, and it is
        // the honest range rather than one figure presented as if it were stable.
        (uint256 tvlCold,) = _gas(abi.encodeCall(this.callTVLs, ()));
        (uint256 tvlWarm,) = _gas(abi.encodeCall(this.callTVLs, ()));

        (uint256 glpCold, bool glpOk) = _gas(abi.encodeCall(this.callGetLatestPrice, ()));
        (uint256 glpWarm,) = _gas(abi.encodeCall(this.callGetLatestPrice, ()));

        (uint256 lrdWarm, bool lrdOk) = _gas(abi.encodeCall(this.callLatestRoundData, ()));

        console2.log("calculateTVLs cold          ", tvlCold);
        console2.log("calculateTVLs warm          ", tvlWarm);
        console2.log("getLatestPrice cold         ", glpCold);
        console2.log("getLatestPrice warm         ", glpWarm);
        console2.log("latestRoundData warm        ", lrdWarm);
        console2.log("selector pair (glp+lrd) warm", glpWarm + lrdWarm);
        console2.log("budget                      ", COMPLETE_READ_BUDGET);

        assertTrue(glpOk, "getLatestPrice must succeed at this block");
        assertTrue(lrdOk, "latestRoundData must succeed at this block");

        // The finding's danger condition: the PAIR consuming enough of the complete-read budget that a
        // starved calculateTVLs returns 0 and ezETH prices at $0. Assert an order-of-magnitude margin, not
        // a tight bound.
        assertLt(
            glpWarm + lrdWarm,
            COMPLETE_READ_BUDGET / 4,
            "ezETH selector pair now exceeds a quarter of the complete-read budget - finding #7 has become live"
        );
    }

    /// @notice `latestRoundData()`'s `answer` is discarded by BOTH consumers, so the second `_compute()` is
    ///         executed only for its `updatedAt` — which does not depend on `_rate()` at all.
    /// @dev This is the finding's real shape, and it is stronger than "runs twice". In `BaseCustomPriceFeed`
    ///      `_compute()` takes `updatedAt` from `NavBaseUsdLib.baseUsd(NAV, BASE_ASSET)` BEFORE calling
    ///      `_rate()`, and returns that same `updatedAt` on both the success and the `rate == 0` early-return
    ///      paths. `PriceFeedLib` destructures the tuple as `(uint80, int256, uint256, uint256 u, uint80)` at
    ///      both call sites (lines ~115 and ~388), taking only `u`. So the `calculateTVLs()` executed by the
    ///      second call cannot influence anything the caller reads.
    ///
    ///      Recorded as a test rather than a comment because it is the premise any future fix rests on: if
    ///      `updatedAt` ever starts depending on the rate, a fix that skips `_rate()` in `latestRoundData()`
    ///      would silently change selection.
    function test_latestRoundDataUpdatedAtIsIndependentOfRate() public {
        (,,, uint256 u1,) = oracle.latestRoundData();

        // Break `_rate()` without touching the base: point the feed at a RestakeManager with no code, so
        // `_rate()` returns 0 (the staticcall succeeds with an empty reply and fails the size gate).
        ezETH_CustomPriceFeed broken = new ezETH_CustomPriceFeed(EZETH, address(0xdead), NAV, WETH);
        (, int256 answer,, uint256 u2,) = broken.latestRoundData();
        (uint256 p, bool s) = broken.getLatestPrice();

        assertEq(p, 0, "a zero rate must produce no price");
        assertTrue(s, "a zero rate must mark the feed stale");
        assertEq(answer, int256(0), "answer is zeroed when stale");
        assertEq(u2, u1, "updatedAt is the base's, unaffected by the rate - so the second _compute is wasted work");
    }

    /// @notice Whole-path control: ezETH's price read against a plain two-Chainlink-leg feed on the same NAV.
    /// @dev rETH is the control the finding asks for. Both go through the same `_selectFeedCore` two-call
    ///      pattern, so the DIFFERENCE isolates what an O(operator-delegators) `_rate()` costs versus an
    ///      O(1) one, with the interface overhead common to both.
    function test_report_getPriceData_ezETH_vs_rETH() public {
        (uint256 ez1, bool ezOk) = _gas(abi.encodeCall(this.callGetPriceData, (EZETH)));
        (uint256 ez2,) = _gas(abi.encodeCall(this.callGetPriceData, (EZETH)));
        (uint256 re1, bool reOk) = _gas(abi.encodeCall(this.callGetPriceData, (RETH)));
        (uint256 re2,) = _gas(abi.encodeCall(this.callGetPriceData, (RETH)));

        console2.log("getPriceData(ezETH) cold", ez1);
        console2.log("getPriceData(ezETH) warm", ez2);
        console2.log("getPriceData(rETH)  cold", re1);
        console2.log("getPriceData(rETH)  warm", re2);
        console2.log("ezETH-vs-rETH warm delta", ez2 > re2 ? ez2 - re2 : 0);
        console2.log("ezETH ok / rETH ok      ", ezOk, reOk);

        // Not asserted equal or bounded against each other: whether either asset is REGISTERED on this NAV
        // is config, and an unregistered asset reverts cheaply. The log is the deliverable; a failure here
        // would only mean the fixture drifted.
        assertTrue(ez1 > 0 && re1 > 0, "both reads must consume gas (sanity, not a bound)");
    }
}
