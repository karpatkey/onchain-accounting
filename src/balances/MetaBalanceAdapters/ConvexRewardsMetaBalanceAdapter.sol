// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CurvePoolLib} from "./curve/CurvePoolLib.sol";

/// @title ConvexRewardsMetaBalanceAdapter
/// @author KPK
/// @notice One immutable adapter that reports an account's Convex-staked Curve LP positions across
///         any configured Convex pool, plus all claimable rewards (CRV, CVX, and extra tokens).
///
/// @dev Instance coordinate: `bytes32(uint256(uint160(rewarder)))` — the Convex BaseRewardPool address
///      widened to bytes32. The underlying Curve LP token is resolved on-chain via:
///        1. `rewarder.pid()` → pool ID in the Booster
///        2. `Booster.poolInfo(pid).lptoken` → the Curve LP token
///        3. `CurvePoolLib.getPool(lpToken)` → the Curve pool (for coin/balance enumeration)
///      This eliminates the need to pass lpToken as a constructor arg (as the per-instance adapter did).
///
///      Per-rewarder positions emitted:
///        1. **Staking** legs — one per registered Curve pool coin, pro-rata from staked LP.
///           `stakedLp = rewarder.balanceOf(account)`; decomposition via CurvePoolLib.
///        2. **Rewards** leg for CRV — `rewarder.earned(account)` (view-safe; exact, not a lower bound
///           like the Curve Minter approach — Convex accounts for all pending CRV in earned()).
///        3. **Rewards** leg for CVX — derived from CRV earned via the Convex cliff emission schedule
///           (standard: cvxAmount = crvEarned × remainingCliffs / TOTAL_CLIFFS, capped at max supply).
///           CVX_TOKEN is passed at construction so L2 deployments without CVX pass address(0).
///        4. **Rewards** legs for extra rewards — up to 8 extra rewarders; stash token wrappers are
///           transparently unwrapped (stash.token() → underlying) to return the real reward address.
///           CVX rewarded through a stash wrapper is derived from CRV, not from stash.earned().
///
///      positionId = abi.encode(address rewarder)
///
///      Compatible with all Convex pools whose BaseRewardPool exposes pid() and the standard
///      extraRewards/extraRewardsLength interface. CRV is the main reward token on all mainnet
///      Convex pools; CVX is derived independently.
contract ConvexRewardsMetaBalanceAdapter is MetaBalanceAdapter {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.CONVEX;

    uint256 private constant _MAX_EXTRA = 8;
    uint256 private constant _CVX_TOTAL_CLIFFS = 1_000;
    uint256 private constant _CVX_REDUCTION_PER_CLIFF = 100_000e18;
    uint256 private constant _CVX_MAX_SUPPLY = 100_000_000e18;

    /// @notice Convex Booster — resolves lptoken from pool ID.
    ///         Mainnet: 0xF403C135812408BFbE8713b5A23a04b3D48AAE31
    IConvexBooster public immutable BOOSTER;

    /// @notice CVX token address. Pass address(0) to skip CVX computation (non-mainnet deployments).
    ///         Mainnet: 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B
    address public immutable CVX_TOKEN;

    /// @param booster_       Convex Booster contract (0xF403C135812408BFbE8713b5A23a04b3D48AAE31 on mainnet).
    /// @param cvxToken_      CVX token address (0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B on mainnet,
    ///                       address(0) to skip CVX computation).
    /// @param protocolName_  Human-readable name (e.g. "Convex").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address booster_, address cvxToken_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(booster_ == address(0) || booster_.code.length > 0, "Booster must be a contract");
        BOOSTER = IConvexBooster(booster_);
        CVX_TOKEN = cvxToken_;
    }

    // ─── MetaBalanceAdapter hooks ──────────────────────────────────────────────

    /// @inheritdoc MetaBalanceAdapter
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address rewarder = _toAddress(instance);
        uint256 stakedLp = IConvexRewarder(rewarder).balanceOf(account);

        // Pre-allocate: MAX_COINS Staking + CRV Rewards + CVX Rewards + MAX_EXTRA Rewards
        INAVCalculator.PositionBalance[] memory tmp =
            new INAVCalculator.PositionBalance[](CurvePoolLib.MAX_COINS + 2 + _MAX_EXTRA);
        uint256 n;

        bytes memory pid = _instancePositionId(instance);

        // ── 1. Staking legs: staked LP → underlying Curve pool tokens ─────────
        if (stakedLp > 0) {
            address lpToken = _lpTokenOf(rewarder);
            if (lpToken != address(0)) {
                address pool = CurvePoolLib.getPool(lpToken);
                if (pool != address(0)) {
                    uint256 totalSupply = CurvePoolLib.getTotalSupply(lpToken);
                    if (totalSupply > 0) {
                        address[] memory coins = CurvePoolLib.getCoins(pool);
                        for (uint256 i; i < coins.length; ++i) {
                            address coin = coins[i];
                            if (assetFilter != address(0) && coin != assetFilter) continue;
                            (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(coin);
                            if (!found) continue;
                            uint256 poolBal = CurvePoolLib.getPoolBalance(pool, i);
                            uint256 amount = CurvePoolLib.proRataAmount(poolBal, stakedLp, totalSupply);
                            if (amount == 0) continue;
                            tmp[n++] = INAVCalculator.PositionBalance({
                                balanceAsset: info,
                                balanceAdapter: address(this),
                                amount: amount,
                                isDebt: false,
                                protocolId: PROTOCOL_ID,
                                positionId: pid,
                                positionKind: PositionKind.Staking,
                                isLocked: false,
                                labels: _legLabels(pid)
                            });
                        }
                    }
                }
            }
        }

        // ── 2. Rewards leg: CRV (main reward, exact view-safe amount) ─────────
        address crvToken = _mainRewardToken(rewarder);
        uint256 crvEarned;
        if (crvToken != address(0)) {
            crvEarned = _earned(rewarder, account);
            if (crvEarned > 0 && (assetFilter == address(0) || assetFilter == crvToken)) {
                (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(crvToken);
                if (found) {
                    tmp[n++] = INAVCalculator.PositionBalance({
                        balanceAsset: info,
                        balanceAdapter: address(this),
                        amount: crvEarned,
                        isDebt: false,
                        protocolId: PROTOCOL_ID,
                        positionId: pid,
                        positionKind: PositionKind.Rewards,
                        isLocked: false,
                        labels: _legLabels(pid)
                    });
                }
            }
        }

        // ── 3. Rewards leg: CVX derived from CRV earned ───────────────────────
        if (CVX_TOKEN != address(0) && crvEarned > 0 && (assetFilter == address(0) || assetFilter == CVX_TOKEN)) {
            uint256 cvxAmount = _cvxMintAmount(crvEarned);
            if (cvxAmount > 0) {
                (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(CVX_TOKEN);
                if (found) {
                    tmp[n++] = INAVCalculator.PositionBalance({
                        balanceAsset: info,
                        balanceAdapter: address(this),
                        amount: cvxAmount,
                        isDebt: false,
                        protocolId: PROTOCOL_ID,
                        positionId: pid,
                        positionKind: PositionKind.Rewards,
                        isLocked: false,
                        labels: _legLabels(pid)
                    });
                }
            }
        }

        // ── 4. Rewards legs: extra reward tokens ───────────────────────────────
        (bool lenOk, uint256 extraLen) = _safeUint(rewarder, abi.encodeWithSignature("extraRewardsLength()"));
        if (lenOk) {
            uint256 cap = extraLen > _MAX_EXTRA ? _MAX_EXTRA : extraLen;
            for (uint256 i; i < cap; ++i) {
                (bool eOk, address extraAddr) = _safeAddr(rewarder, abi.encodeWithSignature("extraRewards(uint256)", i));
                if (!eOk || extraAddr == address(0)) continue;

                (bool tOk, address rawToken) = _safeAddr(extraAddr, abi.encodeWithSignature("rewardToken()"));
                if (!tOk || rawToken == address(0)) continue;

                // Unwrap stash wrapper → actual token
                (bool wOk, address underlying) = _safeAddr(rawToken, abi.encodeWithSignature("token()"));
                address rewardToken = (wOk && underlying != address(0)) ? underlying : rawToken;

                if (rewardToken == crvToken) continue; // already reported as CRV

                // CVX via stash wrapper uses cliff derivation, not stash.earned()
                if (rewardToken == CVX_TOKEN) {
                    if (assetFilter != address(0) && assetFilter != CVX_TOKEN) continue;
                    if (crvEarned > 0) {
                        // CVX already reported in step 3; skip duplicate
                    }
                    continue;
                }

                if (assetFilter != address(0) && rewardToken != assetFilter) continue;
                (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(rewardToken);
                if (!found) continue;

                (bool aOk, uint256 amount) = _safeUint(extraAddr, abi.encodeWithSignature("earned(address)", account));
                if (!aOk || amount == 0) continue;

                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: info,
                    balanceAdapter: address(this),
                    amount: amount,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: pid,
                    positionKind: PositionKind.Rewards,
                    isLocked: false,
                    labels: _legLabels(pid)
                });
            }
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        address rewarder = _toAddress(instance);
        address lpToken = _lpTokenOf(rewarder);

        address[] memory coins;
        if (lpToken != address(0)) {
            address pool = CurvePoolLib.getPool(lpToken);
            if (pool != address(0)) coins = CurvePoolLib.getCoins(pool);
        }
        if (coins.length == 0) coins = new address[](0);

        // Collect reward tokens (CRV + CVX + extras, deduped)
        address[] memory rewards = new address[](_MAX_EXTRA + 2);
        uint256 rn;
        address crv = _mainRewardToken(rewarder);
        if (crv != address(0)) rewards[rn++] = crv;
        if (CVX_TOKEN != address(0)) rewards[rn++] = CVX_TOKEN;

        (bool lenOk, uint256 extraLen) = _safeUint(rewarder, abi.encodeWithSignature("extraRewardsLength()"));
        if (lenOk) {
            uint256 cap = extraLen > _MAX_EXTRA ? _MAX_EXTRA : extraLen;
            for (uint256 i; i < cap; ++i) {
                (bool eOk, address ea) = _safeAddr(rewarder, abi.encodeWithSignature("extraRewards(uint256)", i));
                if (!eOk) continue;
                (bool tOk, address raw) = _safeAddr(ea, abi.encodeWithSignature("rewardToken()"));
                if (!tOk) continue;
                (bool wOk, address ul) = _safeAddr(raw, abi.encodeWithSignature("token()"));
                address tok = (wOk && ul != address(0)) ? ul : raw;
                bool dup;
                for (uint256 j; j < rn; ++j) {
                    if (rewards[j] == tok) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) rewards[rn++] = tok;
            }
        }

        address[] memory all = new address[](coins.length + rn);
        for (uint256 i; i < coins.length; ++i) {
            all[i] = coins[i];
        }
        for (uint256 i; i < rn; ++i) {
            all[coins.length + i] = rewards[i];
        }
        return all;
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @dev Per-leg display labels, filled on every emitted PositionBalance.labels.
    /// @dev Returns `["Curve LP", "TOKEN0/TOKEN1/… Convex"]`; leaf derived on-chain from coin symbols ("" on failure).
    function _legLabels(bytes memory positionId) private view returns (string[] memory) {
        if (positionId.length < 32) return new string[](0);
        string memory leaf = _leaf(positionId);
        return _labels("Curve LP", leaf);
    }

    /// @notice Derives the "TOKEN0/TOKEN1/… Convex" leaf from the rewarder's Curve pool coins ("" on failure).
    function _leaf(bytes memory pid) private view returns (string memory) {
        address rewarder = abi.decode(pid, (address));
        if (rewarder.code.length == 0) return "";
        address lpToken = _lpTokenOf(rewarder);
        if (lpToken == address(0)) return "";
        address pool = CurvePoolLib.getPool(lpToken);
        if (pool == address(0)) return "";
        address[] memory coins = CurvePoolLib.getCoins(pool);
        if (coins.length == 0) return "";
        string memory syms;
        for (uint256 i; i < coins.length; ++i) {
            string memory s;
            if (coins[i].code.length == 0) {
                s = "?";
            } else {
                try IERC20Metadata(coins[i]).symbol() returns (string memory sym) {
                    s = sym;
                } catch {
                    s = "?";
                }
            }
            syms = i == 0 ? s : string.concat(syms, "/", s);
        }
        return string.concat(syms, " Convex");
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @notice Resolves the underlying Curve LP token for a Convex rewarder.
    ///         Uses rewarder.pid() → Booster.poolInfo(pid).lptoken.
    function _lpTokenOf(address rewarder) internal view returns (address) {
        if (address(BOOSTER) == address(0)) return address(0);
        // Require a FULL 32-byte pid() word: a short/empty return (malformed rewarder) would otherwise decode as
        // pid == 0 and silently resolve to Booster pool 0's LP token. (`_safeUint`'s ok flag does not distinguish
        // a short return, which leaves result == 0 — indistinguishable from a genuine pid 0.)
        (bool pidOk, bytes memory ret) = rewarder.staticcall(abi.encodeWithSignature("pid()"));
        if (!pidOk || ret.length < 32) return address(0);
        // Read the first word directly: abi.decode(ret, (uint256)) can revert on a non-32-multiple length
        // (e.g. 33 bytes), which would defeat the fail-open intent for a malformed rewarder.
        uint256 pid;
        assembly {
            pid := mload(add(ret, 0x20))
        }
        try BOOSTER.poolInfo(pid) returns (address lptoken, address, address, address, address, bool) {
            return lptoken;
        } catch {
            return address(0);
        }
    }

    function _mainRewardToken(address rewarder) internal view returns (address) {
        (bool ok, address tok) = _safeAddr(rewarder, abi.encodeWithSignature("rewardToken()"));
        return ok ? tok : address(0);
    }

    function _earned(address rewarder, address account) internal view returns (uint256) {
        (bool ok, uint256 amt) = _safeUint(rewarder, abi.encodeWithSignature("earned(address)", account));
        return ok ? amt : 0;
    }

    /// @notice Derives CVX mint amount from CRV earned via the Convex cliff emission schedule.
    function _cvxMintAmount(uint256 crvEarned) internal view returns (uint256) {
        if (crvEarned == 0 || CVX_TOKEN == address(0)) return 0;
        (bool ok, uint256 supply) = _safeUint(CVX_TOKEN, abi.encodeWithSignature("totalSupply()"));
        if (!ok) return 0;
        uint256 cliff = supply / _CVX_REDUCTION_PER_CLIFF;
        if (cliff >= _CVX_TOTAL_CLIFFS) return 0;
        uint256 remaining = _CVX_TOTAL_CLIFFS - cliff;
        uint256 cvxAmount = (crvEarned * remaining) / _CVX_TOTAL_CLIFFS;
        uint256 amtTillMax = _CVX_MAX_SUPPLY > supply ? _CVX_MAX_SUPPLY - supply : 0;
        return cvxAmount > amtTillMax ? amtTillMax : cvxAmount;
    }

    function _safeUint(address target, bytes memory data) internal view returns (bool ok, uint256 result) {
        return StaticCallLib.safeUint(target, data);
    }

    function _safeAddr(address target, bytes memory data) internal view returns (bool ok, address result) {
        return StaticCallLib.safeAddr(target, data);
    }
}

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IConvexBooster {
    function poolInfo(uint256 pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
}

interface IConvexRewarder {
    function pid() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 index) external view returns (address);
}
