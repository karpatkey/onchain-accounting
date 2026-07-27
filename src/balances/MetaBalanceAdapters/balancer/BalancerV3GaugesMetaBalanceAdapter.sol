// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IStablePool, IGaugeV3, IBalancerMinter} from "src/balances/MetaBalanceAdapters/balancer/IBalancerV3.sol";
import {BalancerGaugeLib} from "src/balances/MetaBalanceAdapters/balancer/BalancerGaugeLib.sol";
import {BalancerV3PoolLib} from "./BalancerV3PoolLib.sol";

// solhint-disable func-name-mixedcase

/// @title Balancer V3 Gauges Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **gauge-staked** Balancer V3 LP plus claimable rewards
///         across *any* gauge — the staked liquidity (valued via the gauge's LP token / pool) and BAL + extra
///         gauge rewards. Wallet-held (unstaked) LP is the separate BalancerV3PoolsMetaBalanceAdapter. The instance
///         coordinate is the gauge address, widened to bytes32. Emits `Staking` legs per pool token and `Rewards`
///         legs per reward token. See ADR 0010.
/// @dev Valuation = instantaneous on-chain amounts (ADR 0017): the staked LP is decomposed into the underlying
///      pool tokens and reported as the position's current pro-rata share of the pool's on-chain balances, as
///      per-token `amount`s that NAVCalculator prices with external oracles — it does NOT compute a
///      manipulation-resistant "fair" value. Imbalancing the pool can transiently move the reported amounts (a
///      donation that arbitrage reverses within a block) but cannot be monetised: NAV is a read-only oracle
///      consumed by an asynchronous sub/redeem layer (no atomic on-chain consumer). See
///      docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed synchronously
///      on-chain.
contract BalancerV3GaugesMetaBalanceAdapter is MetaBalanceAdapter {
    using BalancerV3PoolLib for IStablePool;

    /// @notice Balancer Minter (mints BAL); used to resolve the BAL token, token admin, and minted amounts.
    IBalancerMinter public immutable BALANCER_MINTER;

    /// @param balancerMinter_ Address of the Balancer Minter contract.
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address balancerMinter_, address navCalculator_) MetaBalanceAdapter(navCalculator_) {
        AddressCheckLib.requireContract(balancerMinter_, "BalancerMinter");
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
        uint256 rewardCount = BalancerGaugeLib.rewardCount(gauge);
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
                temp[count++] = _leg(assetInfo, amount, false, positionId, PositionKind.Staking);
            }
        }

        // Rewards legs: BAL (minted via the minter) + the gauge's extra reward tokens.
        address balToken = BALANCER_MINTER.getBalancerToken();
        count = _addReward(temp, count, balToken, claimableBal(gauge, account), positionId, assetFilter);
        for (uint256 i = 0; i < rewardCount; i++) {
            address rt = BalancerGaugeLib.rewardToken(gauge, i);
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
        uint256 rewardCount = BalancerGaugeLib.rewardCount(gauge);

        assets = new address[](tokens.length + rewardCount + 1);
        uint256 n;
        for (uint256 i = 0; i < tokens.length; i++) {
            assets[n++] = tokens[i];
        }
        for (uint256 i = 0; i < rewardCount; i++) {
            address rt = BalancerGaugeLib.rewardToken(gauge, i);
            if (rt != address(0)) assets[n++] = rt;
        }
        assets[n++] = BALANCER_MINTER.getBalancerToken();
        // Trim
        assembly {
            mstore(assets, n)
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Staking Gauge", "<sym0>/<sym1>/…"]` — the leaf is the staked pool's underlying token symbols
    ///      joined with "/" (e.g. "WETH/wstETH"). Resolved gauge → `lp_token` (pool) → pool tokens. Per-token
    ///      fail-open: a token whose `symbol()` reverts (or has no code) contributes "?"; a revert anywhere in the
    ///      resolution chain is caught by the `try this.gaugeTokenSymbols(...)` self-call and falls open to the
    ///      category-only label `["Staking Gauge"]`.
    function positionLabels(bytes calldata positionId) external view virtual override returns (string[] memory) {
        if (positionId.length < 32) return new string[](0);
        address gauge = abi.decode(positionId, (address));
        // External self-call so a revert anywhere in the gauge→lp_token→pool-token chain fails open to the
        // category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.gaugeTokenSymbols(gauge) returns (string memory leaf) {
            return _labels("Staking Gauge", leaf);
        } catch {
            return _labels("Staking Gauge", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the staked pool's underlying
    ///         token symbols joined with "/". Reverts only propagate to the `positionLabels` catch arm.
    function gaugeTokenSymbols(address gauge) external view returns (string memory) {
        return _joinTokenSymbols(IStablePool(IGaugeV3(gauge).lp_token()).poolTokens());
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
    /// @dev Thin wrapper over {BalancerGaugeLib.calculateIntegrateFraction}; kept `public` so `claimableBal` can
    ///      `try this.calculateIntegrateFraction(...)` and fall back to the L2 model. Math is shared with V2.
    function calculateIntegrateFraction(address user, IGaugeV3 gauge) public view returns (uint256) {
        return BalancerGaugeLib.calculateIntegrateFraction(user, gauge, BALANCER_MINTER);
    }

    /// @notice Emulates the gauge integrate_fraction update for `user` (L2 inflation model: per-week rate mapping).
    /// @dev Thin wrapper over {BalancerGaugeLib.calculateIntegrateFractionL2}; kept `public` for the `this.`-call
    ///      fallback in `claimableBal`.
    function calculateIntegrateFractionL2(address user, IGaugeV3 gauge) public view returns (uint256) {
        return BalancerGaugeLib.calculateIntegrateFractionL2(user, gauge);
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
        temp[count] = _leg(assetInfo, amount, false, positionId, PositionKind.Rewards);
        return count + 1;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER_V3;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER_V3_GAUGES;
    }
}
