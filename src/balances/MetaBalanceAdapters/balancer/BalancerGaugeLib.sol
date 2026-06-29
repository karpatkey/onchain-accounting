// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IGaugeV3, IBalancerMinter, ITokenAdmin} from "src/balances/MetaBalanceAdapters/balancer/IBalancerV3.sol";

/// @title BalancerGaugeLib
/// @author KPK
/// @notice Shared BAL-inflation + reward-enumeration reads for the Balancer V2 and V3 gauge meta-adapters. The
///         {calculateIntegrateFraction} / {calculateIntegrateFractionL2} functions emulate the gauge's on-chain
///         `_checkpoint` to derive an account's accrued (un-minted) BAL — identical math across V2 and V3, hoisted
///         here so it lives in exactly one place. The reward-token enumeration helpers ({rewardCount} / {rewardToken})
///         are the same fail-open gauge reads.
/// @dev `internal` functions only — inlined into each adapter's bytecode (NOT a linked/pinned external library, no
///      effect on the PriceFeedLib / NAVRegistryLib pins). The adapters keep thin `public` wrappers around
///      {calculateIntegrateFraction(L2)} so `claimableBal` can `try this.calculateIntegrateFraction(...)` for its
///      mainnet→L2 fallback; this library holds the math those wrappers delegate to.
library BalancerGaugeLib {
    using SafeCast for uint256;
    using SafeCast for int128;

    /// @notice One gauge "week" (seconds), the rate-checkpoint granularity.
    uint256 internal constant WEEK = 7 * 86_400;

    /// @notice Emulates the gauge `_checkpoint` integrate_fraction update for `user` (mainnet inflation model).
    /// @param minter The BalancerMinter, used to resolve the BalancerTokenAdmin rate across a future-epoch boundary.
    function calculateIntegrateFraction(address user, IGaugeV3 gauge, IBalancerMinter minter)
        internal
        view
        returns (uint256)
    {
        uint256 period = gauge.period().toUint256();
        uint128 period128 = period.toUint128();
        uint256 periodTime = gauge.period_timestamp(uint256(period128));
        uint256 integrateInvSup = gauge.integrate_inv_supply(uint256(period128));
        uint256 rate = gauge.inflation_rate();
        uint256 prevFutureEpoch = gauge.future_epoch_time();
        uint256 newRate = rate;

        if (prevFutureEpoch >= periodTime) {
            ITokenAdmin tokenAdmin = ITokenAdmin(minter.getBalancerTokenAdmin());
            newRate = tokenAdmin.rate();
        }
        if (gauge.is_killed()) {
            rate = 0;
            newRate = 0;
        }

        if (block.timestamp > periodTime) {
            uint256 ws = gauge.working_supply();
            uint256 prevWeek = periodTime;
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 weekTime = ((periodTime + WEEK) / WEEK) * WEEK;
            if (weekTime > block.timestamp) weekTime = block.timestamp;

            for (uint256 i = 0; i < 500; i++) {
                uint256 dt = weekTime - prevWeek;
                // forge-lint: disable-next-line(divide-before-multiply)
                uint256 w = gauge.getCappedRelativeWeight((prevWeek / WEEK) * WEEK);
                if (ws > 0) {
                    if (prevFutureEpoch >= prevWeek && prevFutureEpoch < weekTime) {
                        integrateInvSup += rate * w * (prevFutureEpoch - prevWeek) / ws;
                        rate = newRate;
                        integrateInvSup += rate * w * (weekTime - prevFutureEpoch) / ws;
                    } else {
                        integrateInvSup += rate * w * dt / ws;
                    }
                }
                if (weekTime == block.timestamp) break;
                prevWeek = weekTime;
                weekTime = prevWeek + WEEK;
                if (weekTime > block.timestamp) weekTime = block.timestamp;
            }
        }

        uint256 balFrac = gauge.integrate_fraction(user);
        uint256 balInvPrev = gauge.integrate_inv_supply_of(user);
        uint256 wb = gauge.working_balances(user);
        return balFrac + (wb * (integrateInvSup - balInvPrev)) / 1e18;
    }

    /// @notice Emulates the gauge integrate_fraction update for `user` (L2 inflation model: per-week rate mapping).
    function calculateIntegrateFractionL2(address user, IGaugeV3 gauge) internal view returns (uint256) {
        uint256 period = gauge.period().toUint256();
        uint128 period128 = period.toUint128();
        uint256 periodTime = gauge.period_timestamp(uint256(period128));
        uint256 integrateInvSup = gauge.integrate_inv_supply(uint256(period128));

        if (block.timestamp > periodTime && !gauge.is_killed()) {
            uint256 ws = gauge.working_supply();
            uint256 prevWeek = periodTime;
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 weekTime = ((periodTime + WEEK) / WEEK) * WEEK;
            if (weekTime > block.timestamp) weekTime = block.timestamp;

            for (uint256 i = 0; i < 256; i++) {
                uint256 dt = weekTime - prevWeek;
                if (ws != 0) {
                    // forge-lint: disable-next-line(divide-before-multiply)
                    uint256 weekNumber = prevWeek / WEEK;
                    uint256 rate = gauge.inflation_rate(weekNumber);
                    integrateInvSup += rate * 1e18 * dt / ws;
                }
                if (weekTime == block.timestamp) break;
                prevWeek = weekTime;
                weekTime = prevWeek + WEEK;
                if (weekTime > block.timestamp) weekTime = block.timestamp;
            }
        }

        uint256 balFrac = gauge.integrate_fraction(user);
        uint256 balInvPrev = gauge.integrate_inv_supply_of(user);
        uint256 wb = gauge.working_balances(user);
        return balFrac + (wb * (integrateInvSup - balInvPrev)) / 1e18;
    }

    /// @notice The gauge's extra-reward-token count, fail-open to 0 (gauges without `reward_count`).
    function rewardCount(IGaugeV3 gauge) internal view returns (uint256) {
        try gauge.reward_count() returns (uint256 c) {
            return c;
        } catch {
            return 0;
        }
    }

    /// @notice The gauge's `i`-th extra reward token, fail-open to address(0).
    function rewardToken(IGaugeV3 gauge, uint256 i) internal view returns (address) {
        try gauge.reward_tokens(i) returns (address rt) {
            return rt;
        } catch {
            return address(0);
        }
    }
}
