// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Vm} from "forge-std/Vm.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @notice The two reads this guard needs from a Chainlink-shaped rate feed.
interface IRateFeedIdentity {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title RateFeedGuard
/// @author KPK
/// @notice Asserts that a configured rate-feed address really is the PAIR it is supposed to be, before anything
///         is deployed against it.
/// @dev **The hole this closes.** `TwoFeedChainlinkPriceFeed`'s constructor calls
///      `OracleArgumentChecks.assertChainlinkOracle`, which only probes `latestRoundData()`. That establishes the
///      address is *an* aggregator; it never establishes WHICH pair. `description()` was called nowhere in
///      `test/` or `script/` — only in a mock and in JSON `$comment` prose — so a hand-entered address pointing
///      at the wrong feed of the right shape was accepted silently, and stayed silent: the resulting price is
///      wrong by the ratio between two real rates, with `stale = false` and `irregular = false`.
///
///      Worked example, which is why this runs pre-deploy rather than only in CI. Wiring Base `wstETH_L2` to the
///      cbETH/ETH feed instead of wstETH/ETH gives 1.136 x ETH/USD instead of 1.240 x ETH/USD — an ~8% silent,
///      permanent under-report on the whole wstETH book. Both feeds are 18-decimal, both fresh, both pass
///      `assertChainlinkOracle`, and `_rateUnit` adapts to either. The imminent 39-instance redeploy re-enters
///      every one of these addresses by hand, and three of them were already hand-swapped in a single week when
///      RedStone sunset two feeds, with nothing observing any of it.
///
///      **Why BOTH checks, and what each one cannot do.** They fail differently and neither subsumes the other:
///
///        - `description()` pins the exact pair. It is the only check that catches WITHIN-CLASS confusion, and
///          that is the case that actually matters here: in the worked example above both rates sit inside any
///          sane liquid-staking band (1.240 vs 1.136), so a plausibility band cannot separate them. Measured, not
///          argued — every live rate on all four chains was read on 2026-07-30 while writing this.
///        - The band catches what `description()` cannot: a feed with no description, a renamed one, or one whose
///          description is itself wrong. It also catches CROSS-CLASS confusion outright — LDO/ETH trades at
///          0.000192, so pointing an LST feed at it fails the band by four orders of magnitude even if the
///          description were forged.
///
///      Bounds are therefore per-instance in config rather than one global constant, and there are two defensible
///      classes today. `0.9e18 – 1.5e18` for a liquid-staking or yield-bearing wrapper quoted in its own base
///      (observed 0.99976 for OETH/ETH through 1.2405 for wstETH/ETH — the floor allows a severe depeg to still
///      report, the ceiling is roughly seven years of accrual at current rates). `1e13 – 1e16` for a governance
///      token quoted in ETH (LDO/ETH at 0.000192 would have to 50x or fall 20x against ETH to breach).
///
///      **This guard fails closed on absence.** {checkAll} does not merely skip an instance that has no
///      `rateFeedGuard` block: it inspects the constructor keys and reverts if an instance takes a rate-feed-shaped
///      parameter without declaring a guard for it. Without that, the guard would silently stop covering the next
///      feed anyone adds, which is the failure mode of every check that is opt-in by omission.
library RateFeedGuard {
    /// @notice The configured address is an aggregator, but for the wrong pair.
    error RateFeedPairMismatch(string feed, address rateFeed, string expected, string actual);
    /// @notice The rate is outside the band configured for this instance.
    error RateFeedOutOfBand(string feed, address rateFeed, uint256 rate1e18, uint256 minRate, uint256 maxRate);
    /// @notice The feed did not answer, or answered non-positively.
    error RateFeedUnreadable(string feed, address rateFeed);
    /// @notice An instance takes a rate-feed parameter but declares no `rateFeedGuard`. Fail closed, never skip.
    error RateFeedGuardMissing(string feed, string param);
    /// @notice The `rateFeedGuard` block names a constructor parameter the instance does not have.
    error RateFeedGuardParamUnknown(string feed, string param);

    /// @notice Validates every enabled rate-feed instance configured for `chainId`. Returns how many were checked.
    /// @dev Call this BEFORE deploying. It is view-only and costs four RPC reads per instance.
    function checkAll(Vm vm, uint256 chainId) internal view returns (uint256 checked) {
        string[] memory names = ConfigReader.getEnabledAdapters(vm, chainId, "deployPriceFeeds");
        for (uint256 i; i < names.length; ++i) {
            string memory param = _guardField(vm, chainId, names[i], "param");
            if (bytes(param).length == 0) {
                // No guard declared. Only legitimate if this instance takes no rate feed at all.
                _assertNoUnguardedRateFeedParam(vm, chainId, names[i]);
                continue;
            }
            check(vm, chainId, names[i]);
            ++checked;
        }
    }

    /// @notice Validates one instance's rate feed: exact pair identity, then plausibility band.
    function check(Vm vm, uint256 chainId, string memory feed) internal view {
        string memory param = _guardField(vm, chainId, feed, "param");
        string memory addrStr = ConfigReader.readPriceFeedParam(vm, chainId, feed, param);
        if (bytes(addrStr).length == 0) revert RateFeedGuardParamUnknown(feed, param);
        address rateFeed = vm.parseAddress(addrStr);

        // 1. Pair identity. The only check that separates two feeds of the same shape and similar magnitude.
        string memory expected = _guardField(vm, chainId, feed, "description");
        string memory actual = IRateFeedIdentity(rateFeed).description();
        if (keccak256(bytes(actual)) != keccak256(bytes(expected))) {
            revert RateFeedPairMismatch(feed, rateFeed, expected, actual);
        }

        // 2. Plausibility band, which still bites if the description is absent, renamed, or itself wrong.
        (, int256 answer,,,) = IRateFeedIdentity(rateFeed).latestRoundData();
        if (answer <= 0) revert RateFeedUnreadable(feed, rateFeed);
        uint256 rate1e18 = _to1e18(uint256(answer), IRateFeedIdentity(rateFeed).decimals());
        uint256 lo = vm.parseUint(_guardField(vm, chainId, feed, "minRate1e18"));
        uint256 hi = vm.parseUint(_guardField(vm, chainId, feed, "maxRate1e18"));
        if (rate1e18 < lo || rate1e18 > hi) revert RateFeedOutOfBand(feed, rateFeed, rate1e18, lo, hi);
    }

    /// @notice The rate-feed address this instance is configured with, resolved from the SAME config the deploy
    ///         script reads.
    /// @dev Exists so a fork test can stop hardcoding the address. A test that hardcodes it and then asserts
    ///      `description()` against that constant only proves the constant is self-consistent — the tautology in a
    ///      new costume. Resolving here means a config change propagates into the test.
    function configuredRateFeed(Vm vm, uint256 chainId, string memory feed) internal view returns (address) {
        string memory param = _guardField(vm, chainId, feed, "param");
        if (bytes(param).length == 0) revert RateFeedGuardMissing(feed, "");
        return vm.parseAddress(ConfigReader.readPriceFeedParam(vm, chainId, feed, param));
    }

    function _guardField(Vm vm, uint256 chainId, string memory feed, string memory field)
        private
        view
        returns (string memory)
    {
        return ConfigReader.readPriceFeedParam(vm, chainId, feed, string(abi.encodePacked("rateFeedGuard.", field)));
    }

    /// @dev Fail-closed completeness check. An instance with no `rateFeedGuard` must also have no rate-feed-shaped
    ///      constructor parameter. The two shapes in use are the CrossRate `yToXFeed` and the per-asset
    ///      `<x>To<y>Chainlink[Address]`; both are matched here so a newly-added feed cannot quietly escape the
    ///      guard by simply omitting the block.
    function _assertNoUnguardedRateFeedParam(Vm vm, uint256 chainId, string memory feed) private view {
        string[] memory keys = ConfigReader.priceFeedConstructorKeys(vm, chainId, feed);
        for (uint256 i; i < keys.length; ++i) {
            if (_isRateFeedParam(keys[i])) revert RateFeedGuardMissing(feed, keys[i]);
        }
    }

    function _isRateFeedParam(string memory key) private pure returns (bool) {
        if (keccak256(bytes(key)) == keccak256("yToXFeed")) return true;
        return _endsWith(key, "Chainlink") || _endsWith(key, "ChainlinkAddress");
    }

    function _endsWith(string memory s, string memory suffix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory x = bytes(suffix);
        if (b.length < x.length) return false;
        uint256 off = b.length - x.length;
        for (uint256 i; i < x.length; ++i) {
            if (b[off + i] != x[i]) return false;
        }
        return true;
    }

    /// @dev Chainlink rate feeds in use here are 8- or 18-decimal; both directions are handled so a future feed
    ///      cannot silently skew the band comparison.
    function _to1e18(uint256 answer, uint8 dec) private pure returns (uint256) {
        if (dec == 18) return answer;
        if (dec < 18) return answer * (10 ** (18 - dec));
        return answer / (10 ** (dec - 18));
    }
}
