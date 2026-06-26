// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IGaugeV3, IBalancerMinter, ITokenAdmin} from "src/balances/protocols/balancer/IBalancerV3.sol";
import {BalancerV2PoolLib, IBalancerV2Pool} from "src/balances/protocols/balancer/BalancerV2PoolLib.sol";

// solhint-disable func-name-mixedcase

/// @title Balancer V2 Gauges Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's **gauge-staked** Balancer V2 LP plus claimable rewards
///         across *any* gauge — the staked liquidity (valued via the Vault's pool balances) and BAL + extra gauge
///         rewards. Wallet-held (unstaked) LP is the separate BalancerV2PoolsMetaBalanceAdapter. The instance
///         coordinate is the gauge address, widened to bytes32. Emits `Staking` legs per underlying pool token and
///         `Rewards` legs per reward token. The Balancer V2 Vault and BalancerMinter are the chain-level constants
///         pinned in the constructor. See ADR 0010.
/// @dev Balancer V2 and V3 share the same liquidity-gauge + BalancerMinter design, so the BAL reward math is
///      identical to `BalancerV3GaugesMeta`; the only difference is the staked-share computation, which for V2
///      reads the Vault's pool balances (`BalancerV2PoolLib`) rather than V3's per-pool scaled data.
contract BalancerV2GaugesMetaBalanceAdapter is MetaBalanceAdapter {
    using SafeCast for uint256;
    using SafeCast for int128;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.BALANCER_V2_GAUGE;

    /// @notice One week in seconds (gauge inflation accounting boundary).
    uint256 public constant WEEK = 7 * 86_400;

    /// @notice The Balancer V2 Vault (custodies every pool's tokens; chain-level constant).
    address public immutable VAULT;

    /// @notice Balancer Minter (mints BAL); resolves the BAL token, token admin, and minted amounts.
    IBalancerMinter public immutable BALANCER_MINTER;

    /// @param vault_ The Balancer V2 Vault address.
    /// @param balancerMinter_ Address of the Balancer Minter contract.
    /// @param protocolName_ Protocol identifier (e.g. "Balancer V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vault_, address balancerMinter_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(vault_.code.length > 0, "Vault must be a contract");
        require(balancerMinter_.code.length > 0, "BalancerMinter must be a contract");
        VAULT = vault_;
        BALANCER_MINTER = IBalancerMinter(balancerMinter_);
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the gauge address. Emits a Staking leg per registered pool token (the account's staked
    ///      BPT share, via the Vault) plus a Rewards leg per registered reward token (BAL via the minter + the
    ///      gauge's extra reward tokens). Skips unregistered tokens and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IGaugeV3 gauge = IGaugeV3(_toAddress(instance));
        address bpt = gauge.lp_token();
        bytes memory positionId = _instancePositionId(instance);

        uint256 rewardCount = _rewardCount(gauge);

        // Staking legs: account's staked-BPT share of each underlying pool token (via the Vault). The poolId is only
        // needed to read the Vault balances, so resolve it lazily inside the staked branch (skips the read at 0 stake).
        uint256 staked = gauge.balanceOf(account);
        address[] memory tokens;
        uint256[] memory amounts;
        if (staked != 0) {
            bytes32 poolId = IBalancerV2Pool(bpt).getPoolId();
            (tokens, amounts) = BalancerV2PoolLib.shares(VAULT, poolId, bpt, staked);
        }

        INAVCalculator.PositionBalance[] memory temp =
            new INAVCalculator.PositionBalance[](tokens.length + rewardCount + 1);
        uint256 count;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] == 0) continue;
            if (assetFilter != address(0) && tokens[i] != assetFilter) continue;
            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(tokens[i]);
            if (!found) continue;
            temp[count++] = _row(assetInfo, amounts[i], positionId, PositionKind.Staking);
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
        address bpt = gauge.lp_token();
        address[] memory tokens = BalancerV2PoolLib.poolTokens(VAULT, IBalancerV2Pool(bpt).getPoolId(), bpt);
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
        assembly {
            mstore(assets, n)
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Staking Gauge", <gauge symbol>]`; the leaf is "" if the gauge's `symbol()` reverts.
    function positionLabels(bytes calldata positionId) external view virtual override returns (string[] memory) {
        address gauge = abi.decode(positionId, (address));
        string memory leaf;
        try IERC20Metadata(gauge).symbol() returns (string memory s) {
            leaf = s;
        } catch {
            leaf = "";
        }
        return _labels("Staking Gauge", leaf);
    }

    //
    // Reward math (identical to BalancerV3GaugesMeta — V2/V3 gauges share the BalancerMinter inflation design)
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
