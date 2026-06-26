// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IStablePool, IGaugeV3, IBalancerMinter, ITokenAdmin} from "src/balances/protocols/balancer/IBalancerV3.sol";
import {BalancerV3PoolLib} from "./BalancerV3PoolLib.sol";

// solhint-disable func-name-mixedcase

/// @title Balancer V3 Gauges Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **gauge-staked** Balancer V3 LP plus claimable rewards
///         across *any* gauge — the staked liquidity (valued via the gauge's LP token / pool) and BAL + extra
///         gauge rewards. Wallet-held (unstaked) LP is the separate BalancerV3PoolsMetaBalanceAdapter. The instance
///         coordinate is the gauge address, widened to bytes32. Emits `Staking` legs per pool token and `Rewards`
///         legs per reward token. See ADR 0010.
contract BalancerV3GaugesMetaBalanceAdapter is MetaBalanceAdapter {
    using SafeCast for uint256;
    using SafeCast for int128;
    using BalancerV3PoolLib for IStablePool;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.BALANCER_V3_GAUGE;

    /// @notice One week in seconds (gauge inflation accounting boundary).
    uint256 public constant WEEK = 7 * 86_400;

    /// @notice Balancer Minter (mints BAL); used to resolve the BAL token, token admin, and minted amounts.
    IBalancerMinter public immutable BALANCER_MINTER;

    /// @param balancerMinter_ Address of the Balancer Minter contract.
    /// @param protocolName_ Protocol identifier (e.g. "Balancer V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address balancerMinter_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(balancerMinter_.code.length > 0, "BalancerMinter must be a contract");
        BALANCER_MINTER = IBalancerMinter(balancerMinter_);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the gauge address. Emits a Staking leg per registered pool token (the account's staked
    ///      BPT share) plus a Rewards leg per registered reward token (BAL via the minter + the gauge's extra
    ///      reward tokens). Skips unregistered tokens and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IGaugeV3 gauge = IGaugeV3(_toAddress(instance));
        IStablePool pool = IStablePool(gauge.lp_token());
        bytes memory positionId = _instancePositionId(instance);

        address[] memory tokens = pool.poolTokens();
        // Worst case: one Staking leg per pool token + one Rewards leg per (pool token also a reward) + BAL +
        // extras. Size generously; trim at the end.
        uint256 rewardCount = _rewardCount(gauge);
        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](tokens.length + rewardCount + 1);
        uint256 count;

        // Staking legs: account's staked-BPT share of each pool token.
        uint256 staked = gauge.balanceOf(account);
        if (staked != 0) {
            for (uint256 i = 0; i < tokens.length; i++) {
                address token = tokens[i];
                if (assetFilter != address(0) && token != assetFilter) continue;
                (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(token);
                if (!found) continue;
                uint256 amount = pool.poolBalanceOfIndexed(staked, i);
                if (amount == 0) continue;
                temp[count++] = _row(assetInfo, amount, positionId, PositionKind.Staking);
            }
        }

        // Rewards legs: BAL (minted via the minter) + the gauge's extra reward tokens.
        address balToken = BALANCER_MINTER.getBalancerToken();
        count = _addReward(temp, count, balToken, claimableBal(gauge, account), positionId, assetFilter);
        for (uint256 i = 0; i < rewardCount; i++) {
            address rt = _rewardToken(gauge, i);
            if (rt == address(0) || rt == balToken) continue;
            count = _addReward(temp, count, rt, gaugeRewards(gauge, account, rt), positionId, assetFilter);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Pool tokens (the staked LP's underlyings) plus the gauge's reward tokens and BAL.
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory assets) {
        IGaugeV3 gauge = IGaugeV3(_toAddress(instance));
        address[] memory tokens = IStablePool(gauge.lp_token()).poolTokens();
        uint256 rewardCount = _rewardCount(gauge);

        assets = new address[](tokens.length + rewardCount + 1);
        uint256 n;
        for (uint256 i = 0; i < tokens.length; i++) {
            assets[n++] = tokens[i];
        }
        for (uint256 i = 0; i < rewardCount; i++) {
            address rt = _rewardToken(gauge, i);
            if (rt != address(0)) assets[n++] = rt;
        }
        assets[n++] = BALANCER_MINTER.getBalancerToken();
        // Trim
        assembly {
            mstore(assets, n)
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    function describePosition(bytes calldata positionId) external view override returns (string memory) {
        address gauge = abi.decode(positionId, (address));
        try IERC20Metadata(gauge).symbol() returns (string memory s) {
            return s;
        } catch {
            return "";
        }
    }

    //
    // Reward math (ported from the combined BalancerV3 adapter; operate on a passed-in gauge)
    //

    /// @notice Claimable extra-reward-token amount for `account` on `gauge` (0 if unsupported/failed).
    function gaugeRewards(IGaugeV3 gauge, address account, address token) public view returns (uint256) {
        try gauge.claimable_reward(account, token) returns (uint256 claimable) {
            return claimable;
        } catch {
            return 0;
        }
    }

    /// @notice Claimable BAL for `account` on `gauge` (mainnet inflation model, falling back to the L2 model).
    function claimableBal(IGaugeV3 gauge, address account) public view returns (uint256) {
        uint256 minted = BALANCER_MINTER.minted(account, address(gauge));
        try this.calculateIntegrateFraction(account, gauge) returns (uint256 frac) {
            return frac > minted ? frac - minted : 0;
        } catch {
            try this.calculateIntegrateFractionL2(account, gauge) returns (uint256 frac) {
                return frac > minted ? frac - minted : 0;
            } catch {
                return 0;
            }
        }
    }

    /// @notice Emulates the gauge `_checkpoint` integrate_fraction update for `user` (mainnet inflation model).
    /// @dev External so claimableBal can isolate a revert via try/catch. View-only (no state changes).
    function calculateIntegrateFraction(address user, IGaugeV3 gauge) public view returns (uint256) {
        uint256 period = gauge.period().toUint256();
        uint128 period128 = period.toUint128();
        uint256 periodTime = gauge.period_timestamp(uint256(period128));
        uint256 integrateInvSup = gauge.integrate_inv_supply(uint256(period128));
        uint256 rate = gauge.inflation_rate();
        uint256 prevFutureEpoch = gauge.future_epoch_time();
        uint256 newRate = rate;

        if (prevFutureEpoch >= periodTime) {
            ITokenAdmin tokenAdmin = ITokenAdmin(BALANCER_MINTER.getBalancerTokenAdmin());
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
    /// @dev External so claimableBal can isolate a revert via try/catch. View-only.
    function calculateIntegrateFractionL2(address user, IGaugeV3 gauge) public view returns (uint256) {
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

    //
    // Internal helpers
    //

    /// @notice Appends a Rewards leg for `token` if non-zero, registered, and passing the asset filter.
    function _addReward(
        INAVCalculator.PositionBalance[] memory temp,
        uint256 count,
        address token,
        uint256 amount,
        bytes memory positionId,
        address assetFilter
    ) private view returns (uint256) {
        if (amount == 0) return count;
        if (assetFilter != address(0) && token != assetFilter) return count;
        (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(token);
        if (!found) return count;
        temp[count] = _row(assetInfo, amount, positionId, PositionKind.Rewards);
        return count + 1;
    }

    function _row(INAVCalculator.Asset memory asset, uint256 amount, bytes memory positionId, PositionKind kind)
        private
        view
        returns (INAVCalculator.PositionBalance memory)
    {
        return INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: amount,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: positionId,
            positionKind: kind
        });
    }

    function _rewardCount(IGaugeV3 gauge) private view returns (uint256) {
        try gauge.reward_count() returns (uint256 c) {
            return c;
        } catch {
            return 0;
        }
    }

    function _rewardToken(IGaugeV3 gauge, uint256 i) private view returns (address) {
        try gauge.reward_tokens(i) returns (address rt) {
            return rt;
        } catch {
            return address(0);
        }
    }
}
