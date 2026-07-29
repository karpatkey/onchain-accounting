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
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address minter_, address crvToken_, address navCalculator_) MetaBalanceAdapter(navCalculator_) {
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
        //
        // If the pool cannot be resolved, or exposes no supply/coins to decompose against, report the staked
        // LP token ITSELF rather than nothing. Every one of those exits used to drop the entire staking
        // principal silently — a real 3pool-gauge staker reported zero staking legs, because 3Crv resolves
        // through none of CurvePoolLib.getPool's heuristics (fixed there; this is the residual safety net for
        // any LP the registry also cannot resolve). Reverting instead is not an option that helps: the base's
        // per-instance catch absorbs every non-gas revert and substitutes empty legs, so it would produce the
        // same silent zero by another route. The fallback leg is what makes the failure visible to the caller.
        if (stakedLp > 0) {
            address lpToken = CurvePoolLib.gaugeLpToken(gauge);
            if (lpToken != address(0)) {
                address pool = CurvePoolLib.getPool(lpToken);
                uint256 totalSupply = pool != address(0) ? CurvePoolLib.getTotalSupply(lpToken) : 0;
                address[] memory coins = totalSupply > 0 ? CurvePoolLib.getCoins(pool) : new address[](0);

                if (coins.length > 0) {
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
                } else if (assetFilter == address(0) || assetFilter == lpToken) {
                    // Undecomposable: the staked balance is still real, so report it in LP terms.
                    // Emits ONLY if the LP token is a registered asset. Stated plainly because an earlier
                    // comment here claimed the failure was "visible either way", which is false: with the LP
                    // unregistered (the current state for 3Crv) this branch emits nothing and the principal is
                    // still silently dropped. What actually fixes 3Crv is the registry resolution in
                    // CurvePoolLib.getPool; this branch is the residual net for LPs the registry cannot resolve
                    // either, and it only pays off if the operator registers the LP. Operator note: registering it also
                    // makes ERC20Default report the account's WALLET-held LP, which `CurvePoolsMeta` already
                    // decomposes into coin legs for a governed pool - i.e. registering to light this net up
                    // double-counts the wallet LP. Prefer registering it only where the pool is NOT a governed
                    // CurvePoolsMeta instance.
                    (INAVCalculator.Asset memory lpInfo, bool lpFound) = _getAssetInfo(lpToken);
                    if (lpFound) tmp[n++] = _leg(lpInfo, stakedLp, false, pid, PositionKind.Staking);
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
        // Declare the LP token exactly when _instancePositions could emit it as a fallback leg. Without this
        // the advertised asset set contradicts what the adapter emits, and NAVRegistryLib.getAdaptersForAsset
        // routes per-asset queries by this list — so getAccountBalanceForAsset(LP) would miss a principal that
        // getAccountNav() includes.
        uint256 lpSlot = (coins.length == 0 && lpToken != address(0)) ? 1 : 0;
        address[] memory all = new address[](coins.length + crvSlot + extraN + lpSlot);
        for (uint256 i; i < coins.length; ++i) {
            all[i] = coins[i];
        }
        if (crvSlot > 0) all[coins.length] = CRV_TOKEN;
        for (uint256 i; i < extraN; ++i) {
            all[coins.length + crvSlot + i] = extraTmp[i];
        }
        if (lpSlot > 0) all[all.length - 1] = lpToken;
        return all;
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["Staking Gauge", "TOKEN0/TOKEN1/…"]`; leaf derived on-chain from coin symbols ("" on failure).
    function positionLabels(bytes calldata pid) external view virtual override returns (string[] memory) {
        (address gauge, bool ok) = _pidAddress(pid);
        if (!ok) return new string[](0);
        string memory leaf = "";
        try this.gaugeCoinSymbols{gas: LABEL_LEAF_GAS}(gauge) returns (string memory l) {
            leaf = l;
        } catch {}
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
    /// @dev The leaf is derived behind a bounded self-call rather than inline. It reads the chain through
    ///      addresses reached from the governed coordinate — pool coins, and an ERC20 `symbol()` per coin — and
    ///      unbounded that work can consume the budget of whatever called in, for a display string. The helper is
    ///      `external` only so this boundary exists; it is the same shape the pool/gauge symbol readers elsewhere
    ///      in the family already use. Exhaustion degrades to the category alone, exactly as an unreadable symbol
    ///      already does.
    function gaugeCoinSymbols(address gauge) external view returns (string memory) {
        address lpToken = CurvePoolLib.gaugeLpToken(gauge);
        if (lpToken == address(0)) return "";
        address pool = CurvePoolLib.getPool(lpToken);
        if (pool == address(0)) return "";
        address[] memory coins = CurvePoolLib.getCoins(pool);
        if (coins.length == 0) return "";
        return CurvePoolLib.coinSymbols(coins);
    }
}
