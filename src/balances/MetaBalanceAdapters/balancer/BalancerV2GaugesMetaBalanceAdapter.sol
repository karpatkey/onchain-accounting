// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IGaugeV3, IBalancerMinter} from "src/balances/MetaBalanceAdapters/balancer/IBalancerV3.sol";
import {BalancerGaugeLib} from "src/balances/MetaBalanceAdapters/balancer/BalancerGaugeLib.sol";
import {BalancerV2PoolLib, IBalancerV2Pool} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol";

// solhint-disable func-name-mixedcase

/// @title Balancer V2 Gauges Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **gauge-staked** Balancer V2 LP plus claimable rewards
///         across *any* gauge — the staked liquidity (valued via the Vault's pool balances) and BAL + extra gauge
///         rewards. Wallet-held (unstaked) LP is the separate BalancerV2PoolsMetaBalanceAdapter. The instance
///         coordinate is the gauge address, widened to bytes32. Emits `Staking` legs per underlying pool token and
///         `Rewards` legs per reward token. The Balancer V2 Vault and BalancerMinter are the chain-level constants
///         pinned in the constructor. See ADR 0010.
/// @dev Balancer V2 and V3 share the same liquidity-gauge + BalancerMinter design, so the BAL reward math is
///      identical to `BalancerV3GaugesMeta`; the only difference is the staked-share computation, which for V2
///      reads the Vault's pool balances (`BalancerV2PoolLib`) rather than V3's per-pool scaled data.
/// @dev Valuation = instantaneous on-chain amounts (ADR 0017): the staked LP is decomposed into the underlying
///      pool tokens and reported as the position's current pro-rata share of the pool's on-chain Vault balances,
///      as per-token `amount`s that NAVCalculator prices with external oracles — it does NOT compute a
///      manipulation-resistant "fair" value. Imbalancing the pool can transiently move the reported amounts (a
///      donation that arbitrage reverses within a block) but cannot be monetised: NAV is a read-only oracle
///      consumed by an asynchronous sub/redeem layer (no atomic on-chain consumer). See
///      docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed synchronously
///      on-chain.
contract BalancerV2GaugesMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice The Balancer V2 Vault (custodies every pool's tokens; chain-level constant).
    address public immutable VAULT;

    /// @notice Balancer Minter (mints BAL); resolves the BAL token, token admin, and minted amounts.
    IBalancerMinter public immutable BALANCER_MINTER;

    /// @param vault_ The Balancer V2 Vault address.
    /// @param balancerMinter_ Address of the Balancer Minter contract.
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vault_, address balancerMinter_, address navCalculator_) MetaBalanceAdapter(navCalculator_) {
        AddressCheckLib.requireContract(vault_, "Vault");
        AddressCheckLib.requireContract(balancerMinter_, "BalancerMinter");
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

        uint256 rewardCount = BalancerGaugeLib.rewardCount(gauge);

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
            temp[count++] = _leg(assetInfo, amounts[i], false, positionId, PositionKind.Staking);
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
        address bpt = gauge.lp_token();
        address[] memory tokens = BalancerV2PoolLib.poolTokens(VAULT, IBalancerV2Pool(bpt).getPoolId(), bpt);
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
        assembly {
            mstore(assets, n)
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Staking Gauge", "<sym0>/<sym1>/…"]` — the leaf is the staked pool's underlying token symbols
    ///      joined with "/" (e.g. "USDC/USDT/DAI"), excluding the pool's own pre-minted BPT (composable-stable).
    ///      Resolved gauge → `lp_token` (BPT) → `getPoolId` → Vault pool tokens. Per-token fail-open: a token whose
    ///      `symbol()` reverts (or has no code) contributes "?"; a revert anywhere in the resolution chain is caught
    ///      by the `try this.gaugeTokenSymbols(...)` self-call and falls open to the category-only label
    ///      (`["Staking Gauge"]`).
    function positionLabels(bytes calldata positionId) external view virtual override returns (string[] memory) {
        if (positionId.length < 32) return new string[](0);
        address gauge = abi.decode(positionId, (address));
        // External self-call so a revert anywhere in the gauge→lp_token→poolId→Vault-token chain fails open to
        // the category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.gaugeTokenSymbols(gauge) returns (string memory leaf) {
            return _labels("Staking Gauge", leaf);
        } catch {
            return _labels("Staking Gauge", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the staked pool's underlying
    ///         token symbols joined with "/" (BPT excluded for composable-stable). Reverts propagate only to the
    ///         `positionLabels` catch arm.
    function gaugeTokenSymbols(address gauge) external view returns (string memory) {
        address bpt = IGaugeV3(gauge).lp_token();
        return _joinTokenSymbols(BalancerV2PoolLib.poolTokens(VAULT, IBalancerV2Pool(bpt).getPoolId(), bpt));
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
    /// @dev Thin wrapper over {BalancerGaugeLib.calculateIntegrateFraction}; kept `public` so `claimableBal` can
    ///      `try this.calculateIntegrateFraction(...)` and fall back to the L2 model. Math is shared with V3.
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
        return ProtocolIds.BALANCER_V2;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER_V2_GAUGES;
    }
}
