// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {CurvePoolLib} from "./CurvePoolLib.sol";

/// @title CurveGaugesMetaBalanceAdapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **gauge-staked** LP position across any
///         configured Curve gauge, plus all claimable rewards (CRV and extra tokens).
///
/// @dev Instance coordinate: `bytes32(uint256(uint160(gauge)))` — the gauge address widened to bytes32.
///
///      Per-gauge positions emitted:
///        1. **Staking** legs — one per registered pool coin, pro-rata from the staked LP balance.
///           Uses the same LP decomposition logic as CurvePoolsMetaBalanceAdapter.
///        2. **Rewards** leg for CRV — lower-bound estimate via `integrate_fraction − minter.minted`.
///           Only emitted when CURVE_MINTER is set (see below) and the gauge exposes
///           `integrate_fraction()`. This is a LOWER BOUND — it is stale between checkpoints
///           (deposit/withdraw/claim) and may read 0 for recently-transferred gauge tokens.
///           For accurate CRV, call `gauge.claimable_tokens(account)` via eth_call (state mutation).
///        3. **Rewards** legs — one per registered extra reward token (V2+ gauges).
///           Read via `reward_tokens(i)` + `claimable_reward(account, token)`.
///           V3 gauges update rewards at most hourly; values may be stale between checkpoints.
///
///      Supported gauge types (see CurvePoolLib for full gauge-type taxonomy):
///        - LiquidityGaugeV1: CRV via Minter, no extra rewards
///        - LiquidityGaugeV2/V3/V4/V5: CRV + up to 8 extra rewards
///        - RewardsOnlyGauge (L2): extra rewards only, no CRV (CURVE_MINTER = address(0))
///        - ChildGauge (L2 xchain): extra rewards only (CRV bridged via ChildGaugeFactory, not
///          directly claimable in a view — pass CURVE_MINTER = address(0) for L2 deployments)
///
///      CURVE_MINTER: the Curve Minter on Ethereum mainnet is 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0.
///      On L2 chains (Arbitrum, Optimism, Base, Polygon) pass address(0) to disable CRV tracking.
///      The LP decomposition into underlying tokens is always attempted regardless of the minter.
///
///      positionId = abi.encode(address gauge)
///
///      Wallet-held (unstaked) LP positions are handled separately by CurvePoolsMetaBalanceAdapter.
///
///      Valuation = instantaneous on-chain amounts (ADR 0017): the staked LP is decomposed into the underlying
///      pool tokens and reported as the position's current pro-rata share of the pool's on-chain balances, as
///      per-token `amount`s that NAVCalculator prices with external oracles — it does NOT compute a
///      manipulation-resistant "fair" value. Imbalancing the pool can transiently move the reported amounts (a
///      donation that arbitrage reverses within a block) but cannot be monetised: NAV is a read-only oracle
///      consumed by an asynchronous sub/redeem layer (no atomic on-chain consumer). See
///      docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed synchronously
///      on-chain.
contract CurveGaugesMetaBalanceAdapter is MetaBalanceAdapter {
    /// @notice Curve Minter for CRV emission. address(0) disables CRV tracking (use on L2).
    address public immutable CURVE_MINTER;

    /// @notice CRV token address. On Ethereum mainnet: 0xD533a949740bb3306d119CC777fa900bA034cd52.
    ///         Provided at construction so unit tests can substitute a mock and L2 deployments
    ///         can pass address(0) when CRV is not bridged.
    address public immutable CRV_TOKEN;

    /// @param minter_        Curve Minter (0xd061D61a4d941c39E5453435B6345Dc261C2fcE0 on mainnet,
    ///                       address(0) on L2 to disable CRV tracking).
    /// @param crvToken_      CRV token address (0xD533...034cd52 on mainnet, address(0) to skip).
    /// @param protocolName_  Human-readable name (e.g. "Curve").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address minter_, address crvToken_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        CURVE_MINTER = minter_;
        CRV_TOKEN = crvToken_;
    }

    // ─── MetaBalanceAdapter hooks ──────────────────────────────────────────────

    /// @inheritdoc MetaBalanceAdapter
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address gauge = _toAddress(instance);
        bytes memory pid = _instancePositionId(instance);

        uint256 stakedLp = CurvePoolLib.gaugeStaked(gauge, account);

        // Pre-allocate generously: up to MAX_COINS Staking + 1 CRV Rewards + MAX_COINS extra Rewards
        uint256 maxLegs = CurvePoolLib.MAX_COINS * 2 + 1;
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](maxLegs);
        uint256 n;

        // ── 1. Staking legs: staked LP decomposed into underlying tokens ───────
        if (stakedLp > 0) {
            address lpToken = CurvePoolLib.gaugeLpToken(gauge);
            if (lpToken != address(0)) {
                address pool = CurvePoolLib.getPool(lpToken);
                if (pool != address(0)) {
                    uint256 totalSupply = CurvePoolLib.getTotalSupply(lpToken);
                    if (totalSupply > 0) {
                        address[] memory coins = CurvePoolLib.getCoins(pool);

                        for (uint256 i; i < coins.length; ++i) {
                            address coin = coins[i];
                            if (assetFilter != address(0) && coin != assetFilter) continue;

                            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(coin);
                            if (!found) continue;

                            uint256 poolBal = CurvePoolLib.getPoolBalance(pool, i);
                            uint256 amount = CurvePoolLib.proRataAmount(poolBal, stakedLp, totalSupply);
                            if (amount == 0) continue;

                            tmp[n++] = _leg(assetInfo, amount, false, pid, PositionKind.Staking);
                        }
                    }
                }
            }
        }

        // ── 2. Rewards leg: CRV lower-bound (stale between checkpoints) ─────────
        // Skip if assetFilter is set and is not CRV
        if (assetFilter == address(0) || assetFilter == CRV_TOKEN) {
            uint256 crvLb = CurvePoolLib.crvClaimableLb(gauge, CURVE_MINTER, account);
            if (crvLb > 0) {
                (INAVCalculator.Asset memory crvInfo, bool found) = _getAssetInfo(CRV_TOKEN);
                if (found) {
                    tmp[n++] = _leg(crvInfo, crvLb, false, pid, PositionKind.Rewards);
                }
            }
        }

        // ── 3. Rewards legs: extra reward tokens (V2+ gauges) ──────────────────
        for (uint256 i; i < CurvePoolLib.MAX_COINS; ++i) {
            address rewardTok = CurvePoolLib.rewardToken(gauge, i);
            if (rewardTok == address(0)) break;
            if (rewardTok == CRV_TOKEN) continue; // already accounted for via Minter
            if (assetFilter != address(0) && rewardTok != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(rewardTok);
            if (!found) continue;

            uint256 amount = CurvePoolLib.claimableReward(gauge, account, rewardTok);
            if (amount == 0) continue;

            tmp[n++] = _leg(assetInfo, amount, false, pid, PositionKind.Rewards);
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        address gauge = _toAddress(instance);
        address lpToken = CurvePoolLib.gaugeLpToken(gauge);
        if (lpToken == address(0)) return new address[](0);
        address pool = CurvePoolLib.getPool(lpToken);

        address[] memory coins = pool != address(0) ? CurvePoolLib.getCoins(pool) : new address[](0);

        // Collect extra reward tokens
        address[] memory extraTmp = new address[](CurvePoolLib.MAX_COINS);
        uint256 extraN;
        for (uint256 i; i < CurvePoolLib.MAX_COINS; ++i) {
            address tok = CurvePoolLib.rewardToken(gauge, i);
            if (tok == address(0)) break;
            extraTmp[extraN++] = tok;
        }

        // Merge: coins + CRV (if Minter set) + extra rewards
        uint256 crvSlot = CURVE_MINTER != address(0) ? 1 : 0;
        address[] memory all = new address[](coins.length + crvSlot + extraN);
        for (uint256 i; i < coins.length; ++i) {
            all[i] = coins[i];
        }
        if (crvSlot > 0) all[coins.length] = CRV_TOKEN;
        for (uint256 i; i < extraN; ++i) {
            all[coins.length + crvSlot + i] = extraTmp[i];
        }
        return all;
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Staking Gauge", "TOKEN0/TOKEN1/…"]`; leaf derived on-chain from coin symbols ("" on failure).
    function positionLabels(bytes calldata pid) external view virtual override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        string memory leaf = _leaf(pid);
        return _labels("Staking Gauge", leaf);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.CURVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.CURVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.CURVE_GAUGES;
    }

    /// @notice Derives the "TOKEN0/TOKEN1/…" leaf from the gauge's pool coins ("" on failure).
    function _leaf(bytes calldata pid) private view returns (string memory) {
        address gauge = abi.decode(pid, (address));
        address lpToken = CurvePoolLib.gaugeLpToken(gauge);
        if (lpToken == address(0)) return "";
        address pool = CurvePoolLib.getPool(lpToken);
        if (pool == address(0)) return "";
        address[] memory coins = CurvePoolLib.getCoins(pool);
        if (coins.length == 0) return "";
        return CurvePoolLib.coinSymbols(coins);
    }
}
