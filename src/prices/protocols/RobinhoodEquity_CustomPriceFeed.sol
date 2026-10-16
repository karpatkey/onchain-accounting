// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {InvalidArgumentsWithContext} from "src/errors.sol";

/// @title Robinhood Tokenised-Equity Price Adapter
/// @author KPK
/// @notice A `PriceType.Custom` ({ICustomPriceFeed}, type 3) wrapper around ONE Robinhood Chain (chain id 4663)
///         tokenised-equity Chainlink aggregator. It passes through the TOKEN price the aggregator publishes
///         (docstring 1) and makes the off-hours pricing policy and the token's corporate-action pause explicit code
///         instead of an accident of feed configuration.
///
/// @dev **0. WHY THIS IS ONE CONTRACT AND NOT 26 SOURCE FILES.** `docs/howto/add-price-feed.md` says "one asset per
///      contract. Even if two assets share the same recipe, deploy two contracts", and the file naming convention is
///      `<Asset>_CustomPriceFeed`. The *deployment* rule is honoured exactly: there is one wrapper INSTANCE per
///      tokenised equity, each pinned to its own aggregator and its own ERC20, and `underlyingAssetSupported()` binds
///      each instance to the single asset the NAV will register it for. What is shared is only the SOURCE. 26 live
///      wrappers exist on 4663 (MEASURED, `config/deployed-4663.json`, 24 further first-build wrappers recorded
///      superseded and never registered) and the equity universe grows with every ticker Robinhood lists; 26
///      byte-identical files differing only in two constructor constants would be 26 places for the holdover policy
///      and the pause rule to drift apart, and the whole value of this contract is that those two decisions live in
///      ONE reviewable place. Every asset-specific input is therefore a constructor immutable, and the asset name is
///      absent from the type name on purpose: `RobinhoodEquity` is the recipe, not the asset. The sibling precedent
///      upstream is {InvertedChainlinkCustomPriceFeed}, also named for its recipe rather than for wARS.
///
/// @dev **1. THE FEED PRICE IS ALREADY THE TOKEN PRICE (corrected 2026-09-25).** Chainlink's Robinhood
///      tokenised-equity feeds publish the token's total return value, `underlying equity price x uiMultiplier`, and
///      Chainlink's documentation says consumers do not apply the multiplier themselves; Robinhood's stock-token API
///      documentation says the same (its REST `/prices` is the raw underlying, the on-chain feed the
///      multiplier-adjusted value). MEASURED on 4663 on 2026-09-25: SGOV's feed read 101.18 USD, the underlying's
///      REST mid 100.655 times its 1.005102 multiplier is 101.17, and its two Uniswap V3 pools traded at 101.09 and
///      100.97. The first build of this contract (live 2026-09-10 to 2026-09-24) read the relationship the other way
///      and multiplied the answer by `uiMultiplier` again, so the NAV overvalued every token with a non-unit
///      multiplier — MEASURED on 2026-09-25: SGOV by 51 bp, SPY by 17.2 bp, NVDA by 7.8 bp. This build returns the
///      answer as published. {effectiveMultiplier} stays as information for monitoring and as the input to one
///      staleness gate (docstring 5); no price is computed from it.
///
/// @dev **2. THE PENDING MULTIPLIER, INFORMATION ONLY.** A corporate action is staged on the token as
///      `newUIMultiplier()` together with `effectiveAt()`. The rule {effectiveMultiplier} reports: when
///      `effectiveAt != 0 && block.timestamp >= effectiveAt` the NEW multiplier is the one in force; otherwise the
///      current `uiMultiplier()` is. All three getters are read with bounded staticcalls, and a token that implements
///      NONE of them reads a multiplier of exactly {MULTIPLIER_SCALE}. The aggregator applies the switch itself and
///      pauses around it (the token's `oraclePaused()`, docstring 5), so no price here depends on this rule.
///
/// @dev **3. WHY THE OFF-HOURS HOLDOVER EXISTS.** The equity aggregators are `us_equities_24/5` feeds with a 24 h
///      (86,400 s) publication cadence. They go quiet because the US tape is shut, not because they are broken.
///      Register such an aggregator RAW (`PriceType.Chainlink`) with the honest heartbeat and the NAV's staleness
///      gate (`PriceFeedLib._selectFeedCore`: `if (block.timestamp - effectiveTime >= heartbeat) continue;`) drops
///      the feed for a large part of every night, every weekend and every US holiday — the fund becomes unpriceable
///      exactly when 25-67 % of these pools' fee income arrives. This is MEASURED, not assumed: walking
///      `getRoundData` on the SPY feed shows a legitimate 290,892 s (3.4 day) weekend gap, while the longest
///      INTRA-WEEK gap is 86,417 s, i.e. the heartbeat tick itself (MEASURED, before 2026-09-10). A flat 86,400 s
///      staleness bound therefore false-positives EVERY weekend. Widening the raw heartbeat instead would work, but
///      then ONE number expresses two different judgements — "how often does this oracle publish" and "how long may
///      we mark to a closed tape" — and the second silently disables the alarm for the first. This contract splits
///      them: {HEARTBEAT} stays the real cadence and is what {governingFeedFreshness} reports for monitoring;
///      {MAX_HOLDOVER} is the separate, deliberate policy number. The recommended {MAX_HOLDOVER} for this class is
///      432,000 s (5 days): a Friday close plus a Monday US holiday (e.g. 2026-09-07) plus margin over the observed
///      290,892 s worst case (ASSUMED, derived from that measurement). This split is
///      [ADR 0028](../../../docs/decisions/0028-session-gapped-feed-holdover.md).
///
/// @dev **4. THE RISK THIS DESIGN ACCEPTS, STATED PLAINLY.** Between {HEARTBEAT} and {MAX_HOLDOVER} this feed reports
///      `stale = false` while returning an answer that is, in the ordinary Chainlink sense, STALE. It is a
///      STALE-BUT-ACCEPTED mark, and {MAX_HOLDOVER} is the knob that sizes the exposure. The consequence is not
///      theoretical: **a subscription or a redemption settled off-hours transacts at the last regular- or
///      extended-hours close, not at a live price.** If the equity gaps overnight — an earnings print, a guidance
///      cut, an index event — the NAV used for that flow is wrong by the size of the gap and the counterparty
///      captures the difference. The alternative (refuse to price off-hours) is not neutral either: it blocks the
///      fund's NAV for most of the week and makes fee accrual unobservable. Neither branch is free. THIS CONTRACT
///      CHOOSES TO PRICE, and exists so that the choice is a reviewable line of code with a number attached rather
///      than an emergent property of a heartbeat someone widened once. Operators who do not accept the holdover must
///      gate flow on session times off-chain; the on-chain feed cannot make that distinction and does not pretend to.
///
/// @dev **5. WHAT IS NOT HELD OVER.** Four conditions are hard staleness no matter how recent the timestamp: a
///      non-positive answer, a missing timestamp (`updatedAt == 0`), an effective multiplier of zero, and an active
///      `oraclePaused()`. The last is the important one — a corporate action (split, ticker change, delisting, halt)
///      is exactly the event that stops the last print from being a fair mark. `oraclePaused()` lives on the TOKEN,
///      not on the feed: the call REVERTS on every aggregator and proxy on chain 4663, and read `false` on all 27
///      equity tokens (MEASURED, 2026-09-10). Robinhood's documentation is explicit that the flag is ADVISORY and NOT
///      enforced on-chain — a paused oracle can still return a value — so this wrapper honouring it is the only thing
///      that makes it bite anywhere in the NAV. The zero-multiplier condition survives the 2026-09-25 correction even
///      though the multiplier no longer enters the price: a token asserting that its own multiplier is zero
///      CONTRADICTS the aggregator that is supposed to apply it, and refusing to price a contradiction under-reports,
///      which is the direction this system errs in. (The 4663 build that this port is taken from dropped the check
///      from its code along with the double-multiply, while keeping it in its prose; the prose was right.)
///
/// @dev **6. OPERATIONAL COUPLING THE DEPLOY PATH MUST HONOUR.** {latestRoundData} here is a straight pass-through of
///      the aggregator's tuple, as {ICustomPriceFeed} requires, because `PriceFeedLib.selectFeed` uses that
///      `updatedAt` both for the per-feed heartbeat gate and to rank redundant feeds — and `_selectFeedCore` applies
///      `block.timestamp - updatedAt >= chainlinkHeartbeat` to Custom feeds too. **The heartbeat this feed is
///      REGISTERED with on the NAV must therefore be {MAX_HOLDOVER}**, or the NAV discards the feed off-hours
///      regardless of `stale = false` and the holdover policy is dead on arrival. {MAX_HOLDOVER} is the policy; the
///      registered heartbeat is only the gate that must be wide enough to let the policy speak, and ADR 0028 fixes it
///      at exactly the policy value so the two gates fire on the same second rather than leaving an unexplained
///      margin. {requiredRegistrationHeartbeat} and {registrationHeartbeatSatisfiesPolicy} exist so a deploy script
///      or a monitor can assert that from the wrapper itself instead of from a config file; see their docstrings for
///      the ADR 0025 tension this resolves.
///
/// @dev **7. IMMUTABLE, NO ADMIN.** No setter, no owner, no pause. Changing the policy means deploying a new wrapper
///      and re-pointing the asset's feed through the NAV's own MANAGER path, where it is visible.
///
/// @dev **8. REGISTRATION REQUIREMENTS THIS CONTRACT SATISFIES**, read off the Sourcify-verified NAVCalculator
///      implementation `0x40e4134849308d53F85A8B685324E2189b13ff7D` on 4663
///      (`PriceFeedLib._validateFeedSupportInternal`):
///      (a) `supportsInterface(type(ICustomPriceFeed).interfaceId)` must be true;
///      (b) `underlyingAssetSupported()` must equal the asset being registered, else `CustomFeedAssetMismatch`;
///      (c) `BASE_ASSET()` must be READABLE as a single 32-byte word — a MISSING selector is a REJECTION
///      (`CustomFeedBaseUnreadable`), and the value must not equal the registered asset (`CustomFeedBaseCircular`).
///      This feed prices from a Chainlink leg and never reads a base price back out of the NAV, so it answers
///      `address(0)`, which is always accepted. It does so by IMPLEMENTING {INavSourcedPriceFeed}, as
///      {InvertedChainlinkCustomPriceFeed} and `ETHPlus_CustomPriceFeed` do. (The 4663 build declared the same
///      constant without the interface, reasoning that the selector is only ever reached by raw staticcall and that
///      folding the member into {ICustomPriceFeed} would change that interface's id. The second half is true and is
///      exactly why {INavSourcedPriceFeed} is a separate interface; the first half does not follow, so this port
///      implements and overrides it.)
contract RobinhoodEquity_CustomPriceFeed is ICustomPriceFeed, INavSourcedPriceFeed {
    /// @notice Scale of the token's `uiMultiplier` (1e18 == "token price equals underlying equity price").
    uint256 public constant MULTIPLIER_SCALE = 1e18;

    /// @notice This feed reads no `base/USD` price out of the NAV, so it declares no NAV-sourced base.
    /// @dev Required by the registration-time circularity gate; see docstring 8(c). Constant, not immutable: a
    ///      Chainlink passthrough can never have a NAV dependency, whatever asset it is deployed for.
    address public constant override BASE_ASSET = address(0);

    /// @dev Probed by selector rather than declared in an inherited interface, so that a token which does not
    ///      implement them (WETH, USDG) is a normal outcome and not a revert. Derived from the signatures so they
    ///      cannot drift: `0x7706ba52`, `0xa60bf13d`, `0xdc767007`, `0x97a4064f`.
    bytes4 private constant ORACLE_PAUSED_SELECTOR = bytes4(keccak256("oraclePaused()"));
    bytes4 private constant UI_MULTIPLIER_SELECTOR = bytes4(keccak256("uiMultiplier()"));
    bytes4 private constant NEW_UI_MULTIPLIER_SELECTOR = bytes4(keccak256("newUIMultiplier()"));
    bytes4 private constant EFFECTIVE_AT_SELECTOR = bytes4(keccak256("effectiveAt()"));

    /// @notice The single Chainlink aggregator (PRIMARY proxy, never the SVR secondary) this feed wraps.
    /// @dev Both proxies share one aggregator and give the same answer, but the secondary returns phase-2 round ids,
    ///      so they are not interchangeable for round bookkeeping. The primary's `accessController()` is
    ///      `address(0)`, i.e. reads are ungated (MEASURED on 4663, 2026-09-10).
    AggregatorV3Interface public immutable AGGREGATOR;

    /// @notice The tokenised-equity ERC20 this feed prices, the only asset it may be registered for, and the source
    ///         of the `uiMultiplier` / `oraclePaused` state.
    address public immutable UNDERLYING_ASSET;

    /// @notice The aggregator's own publication cadence in seconds (86,400 for the `us_equities_24/5` feeds).
    /// @dev This is the DECLARED heartbeat in the sense of
    ///      [ADR 0025](../../../docs/decisions/0025-heartbeat-equals-declared.md) and it is reported verbatim by
    ///      {governingFeedFreshness}, so every monitor that reads the governing pair keeps seeing the provider's real
    ///      commitment. It is NOT the gate that decides `stale` — {MAX_HOLDOVER} is — and it is NOT the heartbeat to
    ///      register on the NAV; see docstring 6.
    uint256 public immutable HEARTBEAT;

    /// @notice THE POLICY CONSTANT: the longest age, in seconds, at which the last print is still accepted as the
    ///         mark. An age at or past this is stale.
    /// @dev Must be >= {HEARTBEAT}; equality means "no holdover at all", i.e. behave like a plain Chainlink feed.
    ///      Named, immutable and measured-against per [ADR 0028](../../../docs/decisions/0028-session-gapped-feed-holdover.md);
    ///      432,000 s is the recommended value for `us_equities_24/5` (docstring 3).
    /// @dev **The comparison is `>=`, not `>`.** `PriceFeedLib._selectFeedCore` refuses a feed at
    ///      `block.timestamp - effectiveTime >= heartbeat`, and every upstream Chainlink wrapper
    ///      ({InvertedChainlinkCustomPriceFeed}, {TwoFeedChainlinkPriceFeed}) uses the same inclusive bound. Matching
    ///      it is what lets ADR 0028 register the NAV-side heartbeat at exactly {MAX_HOLDOVER} and have both gates
    ///      fire on the same second; the 4663 build used `>` and would have needed `MAX_HOLDOVER + 1` registered,
    ///      which is the unexplained one-second margin ADR 0025 exists to abolish.
    uint256 public immutable MAX_HOLDOVER;

    /// @dev Pinned at deployment from `AGGREGATOR.decimals()`. Pinning rather than forwarding is deliberate: the NAV
    ///      reads `decimals()` ONCE, at registration (`PriceFeedLib._resolveFeedDecimals`), stores it in the feed
    ///      config, and scales every later answer with the STORED value. A forwarding `decimals()` could start
    ///      disagreeing with the number the NAV is actually using; an immutable cannot. The returned price is the
    ///      aggregator's answer, in these same decimals — NOT `NAV_DECIMALS`, because nothing here is rescaled.
    uint8 private immutable _decimals;

    /// @param aggregator The Chainlink PRIMARY proxy for `underlyingAsset`/USD.
    /// @param underlyingAsset The tokenised-equity ERC20 on chain 4663 this feed prices.
    /// @param heartbeat The aggregator's declared publication cadence in seconds. Must be non-zero.
    /// @param maxHoldover The off-hours holdover limit in seconds. Must be >= `heartbeat`; 432,000 recommended.
    /// @dev The constructor asserts the aggregator is WIRED CORRECTLY (callable, positive answer, real non-future
    ///      timestamp) — the same three conditions `PriceFeedLib` checks for a raw Chainlink feed at registration —
    ///      so a mistyped aggregator address fails at deploy time instead of silently pricing an equity off some
    ///      other feed. It deliberately does NOT check FRESHNESS: requiring a fresh round here would make every
    ///      off-hours deployment revert, which is precisely the failure mode this contract exists to remove, and a
    ///      wrapper for a US equity is most likely to be deployed out of hours.
    constructor(address aggregator, address underlyingAsset, uint256 heartbeat, uint256 maxHoldover) {
        AGGREGATOR = OracleArgumentChecks.assertChainlinkOracle(aggregator);
        UNDERLYING_ASSET = OracleArgumentChecks.assertERC20Address(underlyingAsset);
        HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(heartbeat);
        if (maxHoldover < heartbeat) revert InvalidArgumentsWithContext("maxHoldover: below heartbeat");
        MAX_HOLDOVER = maxHoldover;

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
            revert InvalidArgumentsWithContext("aggregator: answer unusable");
        }

        _decimals = AggregatorV3Interface(aggregator).decimals();
    }

    /// @notice Reads the aggregator leg and applies the holdover policy plus the four hard-staleness conditions.
    /// @dev `price = aggregatorAnswer`, in the aggregator's own decimals: the aggregator already publishes the token
    ///      price, multiplier included (docstring 1). Policy, in order:
    ///      - aggregator unreadable, answer <= 0, `updatedAt == 0`, or its live `decimals()` no longer matches the
    ///        pinned one => `(0, true)`; there is no mark, or no known scale for one, to hold over.
    ///      - age >= {MAX_HOLDOVER} => `(price, true)`; the print is too old to stand in for a live quote.
    ///      - {effectiveMultiplier} zero, or `oraclePaused()` true on the token => `(price, true)`.
    ///      - otherwise `(price, false)` — INCLUDING the `HEARTBEAT..MAX_HOLDOVER` holdover window, which is the
    ///        accepted risk documented in docstring 4.
    /// @dev A future `updatedAt` is clamped to age 0 rather than treated as an error: the NAV clamps the same way
    ///      (`effectiveTime = updatedAt > block.timestamp ? block.timestamp : updatedAt`), and disagreeing with it
    ///      would only add a second, different opinion about the same clock skew.
    /// @dev The price is returned ALONGSIDE `stale = true` instead of being zeroed, in every case where a print
    ///      exists and is merely refused. The NAV ignores the price whenever `stale` is set — `_selectFeedCore` skips
    ///      the feed — so this costs nothing on the read path and lets an operator see WHAT was rejected, not merely
    ///      that something was. Only the no-usable-print branches return zero.
    /// @dev **The pinned `decimals()` is re-asserted per read**, as {InvertedChainlinkCustomPriceFeed} does with its
    ///      cached feed unit. The 4663 build did not, on the reading that a shrinking `decimals()` under-reports.
    ///      That is only half the hazard: a Chainlink proxy migrating its aggregator from 8 to 10 decimals keeps
    ///      publishing the same real price as a 100x larger integer, which the NAV then scales with the 8 it stored
    ///      at registration — a 100x OVER-report with a fresh timestamp and `stale == false`, on an immutable
    ///      contract with nothing else to catch it. One bounded probe per read closes that, and lands the mismatch on
    ///      the stale path rather than on a revert.
    /// @dev `try`/`catch` on the aggregator, {StaticCallLib-probeWord} on everything else, and the split is not
    ///      arbitrary. `probeWord` returns ONE word, so it cannot carry a five-member round tuple; `try`/`catch`
    ///      covers a REVERT but not a failure to DECODE the reply, so a `success` answer with a short or dirty tuple
    ///      would revert this frame, which {ICustomPriceFeed} forbids. The residual is bounded by the constructor:
    ///      `OracleArgumentChecks.assertChainlinkOracle` proves the tuple decodes at deploy time and {AGGREGATOR} is
    ///      immutable, so reaching that state needs a proxy to migrate to an aggregator with a different return
    ///      shape, which the `AggregatorV3Interface` ABI does not permit.
    function _compute()
        private
        view
        returns (
            uint256 price,
            bool stale,
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        try AGGREGATOR.latestRoundData() returns (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) {
            (roundId, answer, startedAt, updatedAt, answeredInRound) = (r, a, s, u, air);
        } catch {
            return (0, true, 0, 0, 0, 0, 0);
        }

        if (answer <= 0 || updatedAt == 0) return (0, true, roundId, answer, startedAt, updatedAt, answeredInRound);

        (, bool hasWord, uint256 liveDecimals) =
            StaticCallLib.probeWord(address(AGGREGATOR), abi.encodeCall(AggregatorV3Interface.decimals, ()));
        if (!hasWord || liveDecimals != uint256(_decimals)) {
            return (0, true, roundId, answer, startedAt, updatedAt, answeredInRound);
        }

        // The answer is the token price as published; the multiplier is NOT applied here (docstring 1).
        // casting to 'uint256' is safe because the `answer <= 0` branch above has already returned.
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);

        // Guard against an upstream clock ahead of ours before measuring age, as the NAV itself does.
        uint256 eff = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - eff >= MAX_HOLDOVER) {
            return (price, true, roundId, answer, startedAt, updatedAt, answeredInRound);
        }

        // The two conditions that are never held over however recent the print is (docstring 5).
        if (effectiveMultiplier() == 0 || oraclePaused()) {
            return (price, true, roundId, answer, startedAt, updatedAt, answeredInRound);
        }
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    /// @dev The AGGREGATOR's decimals, pinned at construction — not `NAV_DECIMALS`. This feed rescales nothing, so
    ///      the only honest answer is the scale the returned answer is actually in. On 4663 every equity aggregator
    ///      reads 8 (MEASURED, 2026-09-10), which happens to equal `NAV_DECIMALS`, but the equality is a coincidence
    ///      this contract does not rely on.
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return UNDERLYING_ASSET;
    }

    /// @inheritdoc ICustomPriceFeed
    /// @dev Straight pass-through of the single underlying leg, as the interface requires for a one-oracle feed. The
    ///      NAV uses this `updatedAt` for the registered-heartbeat gate and for freshness ranking among redundant
    ///      feeds, so it must be the aggregator's REAL timestamp — reporting `block.timestamp` here to slip past the
    ///      gate during the holdover window would be a lie to the selection logic and would also let this feed
    ///      outrank a genuinely fresh redundant feed. The gate is instead cleared by registering {MAX_HOLDOVER} as
    ///      the heartbeat; see docstring 6.
    /// @dev NOTE the `answer` is the aggregator's own and is passed through UNCHANGED, including when this feed
    ///      reports stale — unlike {InvertedChainlinkCustomPriceFeed}, which zeroes a stale answer because its answer
    ///      is DERIVED and a stale derivation is not a round. Here the tuple is the oracle's round, which
    ///      {ICustomPriceFeed} says to "return directly"; `getLatestPrice()` returns the same number with this
    ///      contract's staleness policy applied. An unreadable aggregator yields `(0, 0, 0, 0, 0)`, the interface's
    ///      documented no-trackable-oracle value, rather than propagating the revert.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (,, roundId, answer, startedAt, updatedAt, answeredInRound) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    /// @dev One Chainlink leg, so the governing leg is that leg ([ADR 0020](../../../docs/decisions/0020-custom-feed-governing-leg-freshness.md)
    ///      reduces to the obvious answer for a single-leg feed): its `updatedAt` paired with the aggregator's real
    ///      {HEARTBEAT} — not {MAX_HOLDOVER}, and not the heartbeat the feed is registered with. This is the pair
    ///      `NAVCalculator.getPriceData` surfaces, and the one place the aggregator's true cadence stays visible
    ///      downstream: an operator can see "age 60 h against an 86,400 s heartbeat" and know the NAV is running on a
    ///      holdover mark, which is exactly the signal this policy owes them.
    /// @dev **This is the first feed whose governing pair can read STALE while `stale == false`.** ADR 0020's
    ///      advisory caveat enumerates the opposite direction (pair fresh, feed stale) and concludes that consumers
    ///      MUST gate on `stale` and never recompute staleness from the pair. That conclusion is what makes this
    ///      direction safe as well: a consumer obeying it sees a *warning* across the weekend and a priced NAV, which
    ///      is the intended operator experience. A consumer that recomputes from the pair would refuse to price every
    ///      weekend — the failure ADR 0028 exists to prevent — and is already out of contract.
    function governingFeedFreshness() external view override returns (uint256 updatedAt, uint256 heartbeat) {
        heartbeat = HEARTBEAT;
        try AGGREGATOR.latestRoundData() returns (uint80, int256, uint256, uint256 u, uint80) {
            updatedAt = u;
        } catch {} // unreadable leg: report no timestamp against the declared heartbeat
    }

    /// @notice The heartbeat this wrapper MUST be registered with on the NAV, read off the wrapper itself.
    /// @dev Deliberately a distinct selector rather than "just call `MAX_HOLDOVER()`". {MAX_HOLDOVER} is a policy
    ///      about how long a closed-tape mark may be carried; this is an instruction to the registration path about
    ///      which number to write into `priceFeeds[i].heartbeat`. They are equal by ADR 0028 and the whole point is
    ///      that the equality is asserted somewhere, by something, against a name that means the second thing.
    /// @dev **The ADR 0025 tension, stated so a reviewer can see it.** ADR 0025 requires a registered heartbeat to
    ///      EQUAL the provider's declared cadence, which for these feeds is {HEARTBEAT} (86,400 s). Registering that
    ///      would make `_selectFeedCore` discard this wrapper every weekend regardless of its `stale` flag
    ///      (docstring 3, docstring 6), so the registered value has to be {MAX_HOLDOVER} instead. ADR 0028 amends
    ///      0025 for exactly this class — a calendar-gated oracle, whose silence is a closed tape and not a fault —
    ///      by generalising the rule to "the registered heartbeat equals the declared value of whichever gate governs
    ///      the feed", which here is the wrapper's own holdover rather than the provider's cadence. What makes that
    ///      safe is that the false-fresh window ADR 0025 is protecting is still bounded by {MAX_HOLDOVER}: the
    ///      wrapper's gate fires on the same second as the NAV's, so widening the registration does not widen the
    ///      window. `script/deploy/preflight/declared_heartbeat_guard.py` should source the expected value from this
    ///      selector, so the check becomes `registered == requiredRegistrationHeartbeat()` for this class instead of
    ///      an allowlist entry that no measurement stands behind.
    function requiredRegistrationHeartbeat() external view returns (uint256) {
        return MAX_HOLDOVER;
    }

    /// @notice Whether `registeredHeartbeat` is the value this wrapper may be registered with.
    /// @dev The deploy-time / monitoring assertion of docstring 6, in one call so a script does not have to encode
    ///      the rule. Equality, not `>=`: anything wider than {MAX_HOLDOVER} re-creates the unexplained margin ADR
    ///      0025 abolishes, and anything narrower kills the holdover policy.
    /// @param registeredHeartbeat The `priceFeeds[i].heartbeat` the NAV holds, or is about to hold, for this feed.
    /// @return ok True iff the registration lets this wrapper's policy be the binding gate.
    function registrationHeartbeatSatisfiesPolicy(uint256 registeredHeartbeat) external view returns (bool ok) {
        return registeredHeartbeat == MAX_HOLDOVER;
    }

    /// @notice The `uiMultiplier` in force right now, 1e18-scaled.
    /// @dev `newUIMultiplier()` once `effectiveAt()` has arrived (`effectiveAt != 0 && block.timestamp >=
    ///      effectiveAt`), otherwise `uiMultiplier()`. A token exposing none of these (a plain ERC20 such as WETH)
    ///      yields {MULTIPLIER_SCALE}. Information only since 2026-09-25: no price is computed from it (docstring 1);
    ///      its one remaining load-bearing use is the zero-multiplier staleness gate (docstring 5).
    /// @dev If the pending value is scheduled but unreadable, the CURRENT multiplier stands: the fallback is always
    ///      the value already in force, never `1e18`, so a half-implemented token cannot silently erase a live
    ///      corporate-action adjustment.
    function effectiveMultiplier() public view returns (uint256) {
        (bool hasCurrent, uint256 current) = _readUint(UNDERLYING_ASSET, UI_MULTIPLIER_SELECTOR);
        if (!hasCurrent) return MULTIPLIER_SCALE;

        (bool hasEffectiveAt, uint256 effectiveAt) = _readUint(UNDERLYING_ASSET, EFFECTIVE_AT_SELECTOR);
        if (!hasEffectiveAt || effectiveAt == 0 || block.timestamp < effectiveAt) return current;

        (bool hasPending, uint256 pending) = _readUint(UNDERLYING_ASSET, NEW_UI_MULTIPLIER_SELECTOR);
        return hasPending ? pending : current;
    }

    /// @notice Whether a corporate-action pause is active on the tokenised-equity ERC20.
    /// @dev Probed on the TOKEN: the aggregators and proxies on chain 4663 do not implement `oraclePaused()` and
    ///      revert on the call (MEASURED, 2026-09-10). Absent, reverting or malformed replies read as NOT paused —
    ///      the probe can only ever ADD staleness, never remove it.
    function oraclePaused() public view returns (bool) {
        (bool ok, uint256 value) = _readUint(UNDERLYING_ASSET, ORACLE_PAUSED_SELECTOR);
        return ok && value != 0;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev A bounded staticcall rather than a typed `try`/`catch`: the target legitimately may not implement the
    ///      selector, and a high-level call to a missing function reverts in a way that is indistinguishable from a
    ///      real failure. {StaticCallLib-probeWord}'s `hasWord` is the "did I get a value" signal — a revert, an
    ///      empty reply and a short reply are all "absent" — and it decodes by masking rather than through
    ///      `abi.decode(..., (bool))`, which REVERTS on a bool word with dirty upper bits and would turn a malformed
    ///      third-party reply into a revert of this whole view. The word is therefore compared numerically.
    /// @dev `hasWord` accepts a reply of 32 bytes OR MORE, where the 4663 build required exactly 32. That is
    ///      {StaticCallLib}'s repo-wide convention and the looser one: an oversized reply from an
    ///      over-ABI-encoding token now yields its first word instead of reading as absent. For `oraclePaused()`
    ///      that can only add staleness; for the multipliers the first word is the value either way.
    function _readUint(address target, bytes4 selector) private view returns (bool ok, uint256 value) {
        bool hasWord;
        (, hasWord, value) = StaticCallLib.probeWord(target, abi.encodeWithSelector(selector));
        if (!hasWord) return (false, 0);
        return (true, value);
    }
}
