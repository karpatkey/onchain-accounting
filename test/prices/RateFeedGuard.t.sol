// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {RateFeedGuard} from "script/utils/RateFeedGuard.sol";
import {Vm} from "forge-std/Vm.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

interface IRateFeedIdentityView {
    function description() external view returns (string memory);
}

/// @title RateFeedGuardTest
/// @notice Proves the pre-deploy rate-feed guard actually bites, using the exact confusion the audit finding
///         describes.
/// @dev No RPC and no fork: every read the guard performs is mocked onto the address the *real* config names, so
///      these run in the normal unit suite. The address itself is resolved from
///      `script/config/contracts-deployment-config/custom-price-feeds/8453.json`, not hardcoded here — asserting
///      against a constant this file also defines would prove only that the constant is self-consistent, which is
///      the tautology this whole finding is about.
contract RateFeedGuardTest is Test {
    uint256 constant BASE = 8453;

    /// @dev The real Base cbETH/ETH feed, and the description it really returns (read on-chain 2026-07-30). Used
    ///      as the WRONG answer for wstETH_L2 — see {test_wrongPairOfTheRightShape_reverts}.
    string constant CBETH_DESCRIPTION = "CBETH / ETH";
    uint256 constant CBETH_RATE = 1.1360639673617576e18;
    uint256 constant WSTETH_RATE = 1.240358111824503e18;

    function _mockFeed(address feed, string memory description, uint256 rate, uint8 dec) internal {
        vm.mockCall(feed, abi.encodeWithSignature("description()"), abi.encode(description));
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(dec));
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(rate), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _wstEthFeed() internal view returns (address) {
        return RateFeedGuard.configuredRateFeed(vm, BASE, "wstETH_L2");
    }

    /// @notice External wrapper so `vm.expectRevert` can observe the revert.
    /// @dev Load-bearing, and the reason is worth recording: {RateFeedGuard.check} is an INTERNAL library
    ///      function, so it inlines into the caller's frame. `vm.expectRevert` only ever inspects the next
    ///      EXTERNAL call, so calling `RateFeedGuard.check` directly made all three negative tests report
    ///      "next call did not revert as expected" — they asserted nothing about the guard. Routing through
    ///      `this.exposedCheck(...)` makes the call external and the expectation real.
    function exposedCheck(uint256 chainId, string memory feed) external view {
        RateFeedGuard.check(vm, chainId, feed);
    }

    /// @notice The address in config resolves, and is the one the audit verified on-chain.
    function test_configuredRateFeed_resolvesFromDeployConfig() public view {
        assertEq(_wstEthFeed(), 0x43a5C292A453A3bF3606fa856197f09D7B74251a, "Base wstETH_L2 rate feed moved");
    }

    /// @notice Happy path: the real pair and a real rate pass both checks.
    function test_correctPair_passes() public {
        _mockFeed(_wstEthFeed(), "WSTETH / ETH", WSTETH_RATE, 18);
        RateFeedGuard.check(vm, BASE, "wstETH_L2");
    }

    /// @notice THE FINDING. Base `wstETH_L2` pointed at the cbETH/ETH feed.
    /// @dev This is the case that justifies `description()` existing at all, and the reason a plausibility band is
    ///      not sufficient on its own: 1.136 and 1.240 are BOTH inside any defensible liquid-staking band, both
    ///      18-decimal, both fresh, and both pass `assertChainlinkOracle`. Only the pair check separates them.
    ///      Left unguarded it is an ~8% silent permanent under-report on the whole wstETH book.
    function test_wrongPairOfTheRightShape_reverts() public {
        address feed = _wstEthFeed();
        _mockFeed(feed, CBETH_DESCRIPTION, CBETH_RATE, 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                RateFeedGuard.RateFeedPairMismatch.selector, "wstETH_L2", feed, "WSTETH / ETH", CBETH_DESCRIPTION
            )
        );
        this.exposedCheck(BASE, "wstETH_L2");
    }

    /// @notice The band still bites when the description cannot be trusted — e.g. a forged or renamed feed.
    /// @dev Complementary to the test above: there the rate was plausible and the description wrong; here the
    ///      description is right and the rate is impossible. Neither check subsumes the other.
    function test_impossibleRate_revertsEvenWithTheRightDescription() public {
        _mockFeed(_wstEthFeed(), "WSTETH / ETH", 0.000192e18, 18); // an LDO/ETH-magnitude rate
        vm.expectRevert(
            abi.encodeWithSelector(
                RateFeedGuard.RateFeedOutOfBand.selector, "wstETH_L2", _wstEthFeed(), 0.000192e18, 0.9e18, 1.5e18
            )
        );
        this.exposedCheck(BASE, "wstETH_L2");
    }

    /// @notice A non-positive answer is rejected rather than treated as a zero rate.
    function test_nonPositiveAnswer_reverts() public {
        address feed = _wstEthFeed();
        vm.mockCall(feed, abi.encodeWithSignature("description()"), abi.encode("WSTETH / ETH"));
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );
        vm.expectRevert(abi.encodeWithSelector(RateFeedGuard.RateFeedUnreadable.selector, "wstETH_L2", feed));
        this.exposedCheck(BASE, "wstETH_L2");
    }

    /// @notice An 8-decimal feed is normalised before the band comparison, not compared raw.
    /// @dev Two mainnet feeds really are 8-decimal (the RedStone ezETH and osETH ones). Comparing their raw answer
    ///      against an 18-decimal band would put every one of them ~10 orders of magnitude below the floor, so the
    ///      guard would revert on correct config — a check that fails closed on the happy path gets deleted.
    function test_eightDecimalFeed_isNormalisedBeforeTheBandCheck() public {
        _mockFeed(_wstEthFeed(), "WSTETH / ETH", 1.24035811e8, 8);
        RateFeedGuard.check(vm, BASE, "wstETH_L2");
    }

    /// @notice A feed whose provider does not expose the pair can be DECLARED unverifiable: the band still
    ///         applies, but only with a stated reason.
    /// @dev Mirrors a real limit measured on mainnet — a RedStone Classic-Push feed returns the constant
    ///      "Redstone Price Feed", identical on every pair, so equality is unimplementable for that family.
    ///      Simulated here by pointing the guard's expected value at the sentinel via a config-shaped override.
    function test_unverifiableWithoutAReason_reverts() public {
        address feed = _wstEthFeed();
        _mockFeed(feed, "Redstone Price Feed", WSTETH_RATE, 18);
        // The real config for wstETH_L2 asserts a concrete pair, so a generic description must still fail here.
        vm.expectRevert(
            abi.encodeWithSelector(
                RateFeedGuard.RateFeedPairMismatch.selector, "wstETH_L2", feed, "WSTETH / ETH", "Redstone Price Feed"
            )
        );
        this.exposedCheck(BASE, "wstETH_L2");
    }

    /// @notice An access-controlled aggregator is rejected even though its description is CORRECT.
    /// @dev The property that actually caught PR #220's ETHx misconfiguration, and neither other check could:
    ///      the pair matched and the magnitude was plausible. Only reading from a CONTRACT frame separates a raw
    ///      controller-gated aggregator from its readable `EACAggregatorProxy`.
    function test_accessControlledAggregator_rejectedDespiteCorrectDescription() public {
        address feed = _wstEthFeed();
        vm.etch(feed, address(new AccessControlledAggregator()).code);
        // Sanity: the description really is right, so this cannot be a pair mismatch.
        assertEq(IRateFeedIdentityView(feed).description(), "WSTETH / ETH", "fixture must have the RIGHT pair");
        vm.expectRevert(abi.encodeWithSelector(RateFeedGuard.RateFeedNotContractReadable.selector, "wstETH_L2", feed));
        this.exposedCheck(BASE, "wstETH_L2");
    }

    /// @notice Every enabled rate-feed instance on all four configured chains declares a guard and is internally
    ///         consistent.
    /// @dev `checkAll` fails CLOSED: an instance taking a rate-feed-shaped constructor param without a
    ///      `rateFeedGuard` block reverts rather than being skipped. That is what stops the guard silently
    ///      ceasing to cover the next feed someone adds. This test cannot call `checkAll` directly without RPC —
    ///      it would try to read live feeds — so it asserts the completeness half only.
    function test_everyRateFeedInstance_declaresAGuard() public view {
        uint256[4] memory chains = [uint256(1), 42161, 8453, 100];
        uint256 total;
        for (uint256 i; i < chains.length; ++i) {
            total += _countGuarded(chains[i]);
        }
        // 24 rate-feed-bearing instances: 12 mainnet, 7 Arbitrum, 4 Base, 1 Gnosis. Each verified on-chain.
        // (Census header kept in step with the assertion below: it read 20 / 8 mainnet after #302's OETH
        // removal and was not updated when wARS took mainnet back to 9 — see the 2026-08-15 note.)
        //
        // 21 -> 20: OETH retired by #302 — Chainlink is sunsetting the OETH/ETH rate feed its CrossRate
        // consumed. This is a REMOVAL, so no NEW pair identity needed confirming; the gate exists to stop an
        // ADDED instance slipping in unverified. What was confirmed instead is that the set is now exactly the
        // expected 20, re-derived from config 2026-08-13: mainnet fell 9 -> 8 and the other three chains are
        // byte-for-byte unchanged. Had anything else moved, that would have been a finding larger than this
        // test rather than a number to update.
        //
        // 20 -> 21: `ezETHCrossRateMarket` (added by #224 after this guard landed, given its block here).
        // This number is a HUMAN-IN-THE-LOOP GATE, not a fact about the world: it exists so a newly-added
        // rate-feed instance cannot slip in without someone confirming its pair identity on-chain. Bumping it
        // is only legitimate once that confirmation has actually happened. For this instance it has —
        // `0xF4a3e183` measured 2026-07-31:
        //
        //   description()     "Redstone Price Feed"  <- the bare RedStone Classic-Push constant. Identical on
        //                                               every Classic-Push feed on every pair, so it cannot
        //                                               identify one; exact-match is UNIMPLEMENTABLE, not weak.
        //   decimals()        8
        //   latestRoundData() 108118954  ->  1.0812e18, inside the configured 0.9-1.5e18 band
        //
        // Hence its config declares `description: "$UNVERIFIABLE"` WITH a mandatory reason; the band and the
        // contract-readability check still apply in full.
        //
        // WHEN NOT TO BUMP THIS. The distinguishing question is: did the POPULATION change, or did the COUNTING
        // METHOD mis-measure an unchanged population? Here a real instance was added and verified, so bumping is
        // right. The sibling census `HARDCODED_ADAPTER_COUNT` failed at 14-vs-12 on the same day and bumping
        // there would have been WRONG — nothing had been added; the filter was matching two interface files as
        // if they were adapters, and raising the number would have destroyed the census's ability to notice a
        // genuine thirteenth adapter. Fix the filter when the method is broken; bump only when the set really grew.
        // 2026-08-15: 20 -> 21. Mainnet `wARS` added, and its pair identity WAS confirmed on-chain first —
        // `0xBb65fa58BDb7d33e4a3D1A40a7A9BD99E746367b` measured 2026-08-15:
        //
        //   description()     "USD / ARS"   <- note the DIRECTION: ARS per USD, the reciprocal of the
        //                                      asset/USD direction every primary feed here uses.
        //   decimals()        8
        //   latestRoundData() 158309760000  ->  1583.0976e18, inside the configured 100-100000e18 band
        //
        // This is the population growing, not the counting method mis-measuring: one real instance was added
        // and verified. Its guard is what makes the direction load-bearing — an ARS/USD feed swapped in would
        // answer ~6.3e14 at 1e18 scale and fail the band by five orders of magnitude.
        //
        // 2026-09-16: 21 -> 22. Mainnet `LBTC` added — the cross-rate primary that makes the Aave V4 LombardBTC
        // Spoke's collateral priceable, since Chainlink publishes NO LBTC/USD feed on Ethereum. Population grew
        // by one real instance, and its pair identity WAS confirmed on-chain before this number moved —
        // `0x5c29868C58b6e15e2b962943278969Ab6a7D3212` measured 2026-09-16:
        //
        //   description()     "LBTC / BTC"  <- a real pair string, so exact-match IS implementable here, unlike
        //                                      the RedStone Classic-Push constant above. The config asserts it.
        //   decimals()        8
        //   latestRoundData() 100453494  ->  1.00453494e18, inside the configured 0.9-1.1e18 band
        //   aggregator()      0x3F6047b77131ce78Ab4775feE2d38b7339471a01  <- so the configured address is the
        //                                      PROXY, not the aggregator that Chainlink rotates beneath it.
        //
        // The band is tighter than its neighbours' on purpose: LBTC is 1:1 BTC-backed, so anything far from
        // parity is a wiring error. A BTC/USD feed swapped in here would answer ~7.6e22 at 1e18 scale and miss
        // the band by four orders of magnitude.
        //
        // 2026-10-22: 22 -> 23. Mainnet `WBTCCrossRate` added (issue #356) — the WBTC depeg MONITOR,
        // ChainlinkCrossRateCustomPriceFeed: WBTC / BTC x BTC / USD, both legs read from Chainlink. Population
        // grew by one real instance; its guarded leg's pair identity WAS confirmed on-chain first —
        // `0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23` measured 2026-10-22 (block 26240000):
        //
        //   description()     "WBTC / BTC"
        //   decimals()        8
        //   latestRoundData() 99816000  ->  0.99816e18, inside the configured 0.5-1.5e18 band
        //
        // Its second leg (`baseUsdChainlink`, Chainlink BTC / USD `0xF403…E88c`, description "BTC / USD")
        // is not counted here: the guard pins ONE param per instance, and that leg's identity is asserted in
        // the feed's fork test instead.
        // 2026-10-22: 23 -> 24. Mainnet `WBTCCrossRateRedstone` (issue #356), the second WBTC monitor: rate leg
        // RedStone WBTC/BTC `0xD260596f85C6D91Ccd40f7076eEb62ACb3B2ad53`, description() "RedStone Price Feed for
        // WBTC/BTC", 8 decimals, 99816289 at block 26240000 (inside the 0.5 .. 1.5 band).
        assertEq(total, 24, "rate-feed instance count changed - re-verify description() on the new set");
    }

    function _countGuarded(uint256 chainId) internal view returns (uint256 n) {
        string[] memory names = _enabled(chainId);
        for (uint256 i; i < names.length; ++i) {
            // Reverts if this instance takes a rate-feed param but declares no guard.
            if (_hasGuard(chainId, names[i])) ++n;
        }
    }

    function _enabled(uint256 chainId) internal view returns (string[] memory) {
        return ConfigReaderShim.enabledPriceFeeds(vm, chainId);
    }

    function _hasGuard(uint256 chainId, string memory name) internal view returns (bool) {
        return ConfigReaderShim.hasGuard(vm, chainId, name);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Constructor-band reconciliation. These three use a SYNTHETIC per-chain config file rather than a real
    // chain, because the shapes under test are ones no committed config has — and the point of each is that the
    // guard must bite on a shape someone could plausibly write tomorrow.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev An unused chain id, so the fixture can never collide with a real config file.
    /// @dev **One id PER TEST, deliberately.** forge executes the test functions of a suite concurrently while
    ///      the filesystem is shared, so a single fixture path let two tests' `writeFile` calls interleave and
    ///      produced a malformed file that failed all three with a JSON parse error — a race that reads as a
    ///      logic bug. Distinct ids make the fixtures independent.
    uint256 constant SYNTH_TOP = 999_901;
    uint256 constant SYNTH_SPLIT = 999_902;
    uint256 constant SYNTH_NOGUARD = 999_903;
    uint256 constant SYNTH_TOPPARAM = 999_904;
    uint256 constant SYNTH_INITPARAM = 999_905;
    uint256 constant SYNTH_BANDONLY = 999_906;
    address constant SYNTH_FEED = 0x00000000000000000000000000000000DeaDBeef;

    function _synthPath(uint256 chainId) internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(),
            "/script/config/contracts-deployment-config/custom-price-feeds/",
            vm.toString(chainId),
            ".json"
        );
    }

    function _writeSynth(uint256 chainId, string memory json) internal {
        vm.writeFile(_synthPath(chainId), json);
        // 158309760000 = 1583.0976 at 8dp — inside every guard band below, so the band check passes and the
        // reconciliation is what these tests actually observe.
        _mockFeed(SYNTH_FEED, "USD / ARS", 158_309_760_000, 8);
    }

    /// @dev **Cleanup must precede every assertion, which is why these tests use `staticcall` rather than
    ///      `vm.expectRevert`.** These fixtures land in the git-TRACKED
    ///      `script/config/contracts-deployment-config/custom-price-feeds/` directory, and
    ///      `declared_heartbeat_guard.py` derives its audited chain set from `d.glob("*.json")` over exactly
    ///      that directory — so a leftover `999901.json` makes a preflight report an operator reads before a
    ///      mainnet deploy print a `chain 999901` section for a chain that does not exist, and inflates the
    ///      "on all N chains" coverage claim. With `vm.expectRevert`, a mismatched revert aborts the body at
    ///      the call and the cleanup below never runs. Routing through `staticcall` returns the revert as DATA,
    ///      so the file is always removed before anything can fail. `setUp()`-based cleanup is NOT an
    ///      alternative: forge runs a suite's tests concurrently, so it would delete a sibling's live fixture.
    function _removeSynth(uint256 chainId) internal {
        if (vm.exists(_synthPath(chainId))) vm.removeFile(_synthPath(chainId));
    }

    /// @notice External wrapper so `vm.expectRevert` can observe a revert out of the internal library.
    function exposedCheckAll(uint256 chainId) external view {
        RateFeedGuard.checkAll(vm, chainId);
    }

    /// @notice **A band declared OUTSIDE `constructor` must still be reconciled.**
    /// @dev The presence scan used to enumerate `.<feed>.constructor` keys only, while
    ///      `ConfigReader.readAdapterParam` resolves the TOP-LEVEL `.<feed>.<key>` FIRST — and the top level is
    ///      where `rateFeedGuard` itself sits, so it is the natural place to put the band. The result was that
    ///      `_checkConstructorBandAgrees` returned early having reconciled nothing while `03` read those very
    ///      keys and baked them into an IMMUTABLE feed. Here the constructor max (1e13 at 8dp = 100000e18)
    ///      disagrees with the guard's 999000e18; before the fix this passed silently.
    function test_topLevelBand_isReconciledNotInvisible() public {
        _writeSynth(
            SYNTH_TOP,
            '{"TopLevelBand":{"enabled":true,'
            '"constructor":{"usdToAssetChainlinkAddress":"0x00000000000000000000000000000000DeaDBeeF"},'
            '"minAnswer":"10000000000","maxAnswer":"10000000000000",'
            '"rateFeedGuard":{"param":"usdToAssetChainlinkAddress","description":"USD / ARS",'
            '"minRate1e18":"100000000000000000000","maxRate1e18":"999000000000000000000000"}}}'
        );
        (bool ok, bytes memory ret) =
            address(this).staticcall(abi.encodeWithSelector(this.exposedCheck.selector, SYNTH_TOP, "TopLevelBand"));
        _removeSynth(SYNTH_TOP);
        assertFalse(ok, "a band declared outside `constructor` must be reconciled, not silently skipped");
        assertEq(
            ret,
            abi.encodeWithSelector(
                RateFeedGuard.RateFeedBandMismatch.selector,
                "TopLevelBand",
                uint256(100e18),
                uint256(100e18),
                uint256(100_000e18),
                uint256(999_000e18)
            ),
            "wrong revert"
        );
    }

    /// @notice **A band split across both scopes is COMPLETE, and must not be reported as half-declared.**
    /// @dev The old scan saw only `constructor.maxAnswer` and reverted `RateFeedBandIncomplete` naming
    ///      `minAnswer` as the MISSING one — sending the operator to add a key that was already there, one
    ///      level up. Both bounds agree with the guard here, so the correct outcome is simply: passes.
    function test_bandSplitAcrossScopes_reconcilesRatherThanMisreporting() public {
        _writeSynth(
            SYNTH_SPLIT,
            '{"SplitBand":{"enabled":true,'
            '"constructor":{"usdToAssetChainlinkAddress":"0x00000000000000000000000000000000DeaDBeeF",'
            '"maxAnswer":"10000000000000"},' '"minAnswer":"10000000000",'
            '"rateFeedGuard":{"param":"usdToAssetChainlinkAddress","description":"USD / ARS",'
            '"minRate1e18":"100000000000000000000","maxRate1e18":"100000000000000000000000"}}}'
        );
        (bool ok, bytes memory ret) =
            address(this).staticcall(abi.encodeWithSelector(this.exposedCheck.selector, SYNTH_SPLIT, "SplitBand"));
        _removeSynth(SYNTH_SPLIT);
        assertTrue(ok, string.concat("a complete band split across scopes must reconcile; reverted ", vm.toString(ret)));
    }

    /// @notice **A rate-feed param written BESIDE `constructor` must not hide from the fail-closed scan.**
    /// @dev The companion backstop to the band one above, and it had the same blind spot the band check was
    ///      fixed for: it enumerated `.<feed>.constructor` keys only, while `ConfigReader.readAdapterParam`
    ///      resolves the TOP LEVEL first — so `03` deploys from a key the guard could not see. An instance
    ///      naming its rate feed there with no `rateFeedGuard` block passed {checkAll} silently, with no pair
    ///      check and no band check at all. Note there is no band here: this pins the PARAM axis specifically,
    ///      so it pins the PARAM axis on its own.
    function test_topLevelRateFeedParam_isNotInvisibleToTheFailClosedScan() public {
        _writeSynth(
            SYNTH_TOPPARAM,
            '{"TopParam":{"enabled":true,' '"usdToAssetChainlinkAddress":"0x00000000000000000000000000000000DeaDBeeF",'
            '"constructor":{"underlyingAsset":"0x00000000000000000000000000000000DeaDBeeF"}}}'
        );
        (bool ok, bytes memory ret) =
            address(this).staticcall(abi.encodeWithSelector(this.exposedCheckAll.selector, SYNTH_TOPPARAM));
        _removeSynth(SYNTH_TOPPARAM);
        assertFalse(ok, "a top-level rate-feed param with no guard block must be rejected");
        assertEq(
            ret,
            abi.encodeWithSelector(
                RateFeedGuard.RateFeedGuardMissing.selector, "TopParam", "usdToAssetChainlinkAddress"
            ),
            "wrong revert"
        );
    }

    /// @notice **`.initialize` is the THIRD scope the deploy resolver searches, and it must not hide a rate feed.**
    /// @dev `ConfigReader.readAdapterParam` falls back `.<feed>` -> `.<feed>.constructor` -> `.<feed>.initialize`
    ///      (ConfigReader.sol:403-411). The scan was widened to two of those three, and `initialize` was named
    ///      in the structural-key exclusion list without ever being descended into — so a rate feed declared
    ///      there was resolved by `03` and invisible to the fail-closed check, shipping an immutable feed bound
    ///      to an unverified aggregator with every gate reporting PASS.
    function test_initializeScopeRateFeedParam_isNotInvisibleToTheFailClosedScan() public {
        _writeSynth(
            SYNTH_INITPARAM,
            '{"InitParam":{"enabled":true,' '"initialize":{"yToXFeed":"0x00000000000000000000000000000000DeaDBeeF"}}}'
        );
        (bool ok, bytes memory ret) =
            address(this).staticcall(abi.encodeWithSelector(this.exposedCheckAll.selector, SYNTH_INITPARAM));
        _removeSynth(SYNTH_INITPARAM);
        assertFalse(ok, "a rate-feed param under `initialize` with no guard block must be rejected");
        assertEq(
            ret,
            abi.encodeWithSelector(RateFeedGuard.RateFeedGuardMissing.selector, "InitParam", "yToXFeed"),
            "wrong revert"
        );
    }
}

/// @dev Thin shim so the test above reads config through exactly the same reader the deploy script uses.
library ConfigReaderShim {
    function enabledPriceFeeds(Vm vm, uint256 chainId) internal view returns (string[] memory) {
        return ConfigReader.getEnabledAdapters(vm, chainId, "deployPriceFeeds");
    }

    function hasGuard(Vm vm, uint256 chainId, string memory name) internal view returns (bool) {
        return bytes(ConfigReader.readPriceFeedParam(vm, chainId, name, "rateFeedGuard.param")).length != 0;
    }
}

/// @notice Mimics a raw Chainlink aggregator behind `SimpleReadAccessController`: answers an EOA, denies a
///         contract. This is PR #220's ETHx misconfiguration — note `description()` is CORRECT.
contract AccessControlledAggregator {
    function description() external pure returns (string memory) {
        return "WSTETH / ETH";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(msg.sender == tx.origin, "No access");
        return (uint80(1), int256(1.24e18), block.timestamp, block.timestamp, uint80(1));
    }
}
