// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BalancerV3PoolLib} from "./balancer/BalancerV3PoolLib.sol";
import {IStablePool} from "./balancer/IBalancerV3.sol";
import {BalancerV2PoolLib, IBalancerV2Pool, IBalancerV2Vault} from "./balancer/BalancerV2PoolLib.sol";

/// @title AuraRewardsMetaBalanceAdapter
/// @author kpk
/// @notice One immutable adapter that reports an account's Aura-staked Balancer LP positions
///         across any configured Aura pool, plus all claimable rewards.
///
/// @dev Instance coordinate: `bytes32(uint256(uint160(auraRewards)))` — the Aura BaseRewardPool4626
///      (AURA_REWARDS / crvRewards) address widened to bytes32. The Balancer BPT pool address is
///      resolved on-chain via:
///        1. `auraRewards.pid()` → pool ID in the Aura Booster
///        2. `Booster.poolInfo(pid).lptoken` → the Balancer V3 or V2 pool/BPT
///        3. Pool-type detection (try `getStablePoolDynamicData()`) → V3 or V2 decomposition path
///      This eliminates the need to pass pool/gauge/pid as constructor args.
///
/// @dev AURA token is resolved at construction from `Booster.minter()`:
///      - Mainnet: `minter()` returns the AURA token directly.
///      - L2s (Arbitrum, Base, …): `minter()` returns the L2Coordinator whose `auraOFT()` is the
///        bridged AURA. AURA derivation uses `L2Coordinator.mintRate()` instead of the cliff schedule.
///
///      Per-rewarder positions emitted:
///        1. **Supplied** legs — one per registered Balancer pool token (ERC4626 vault tokens are
///           unwrapped to their underlying via `previewRedeem`), pro-rata from staked BPT.
///        2. **Earned** leg for BAL — `auraRewards.earned(account)` (view-safe exact value).
///        3. **Earned** leg for AURA:
///           - Mainnet: `rewardClaimed(earned × rewardMultiplier)` then AURA cliff schedule.
///           - L2: `earned × L2Coordinator.mintRate() / 1e18`.
///        4. **Earned** legs for extra rewards — up to 8 extra rewarders; stash tokens are
///           transparently unwrapped (`stashToken.baseToken()` → underlying reward address).
///           AURA from extra pools is accumulated into the single AURA leg.
///
///      positionId = abi.encode(address auraRewards)
contract AuraRewardsMetaBalanceAdapter is MetaBalanceOracle {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.AURA;
    uint256 private constant _MAX_EXTRA = 8;

    /// @notice Aura Booster — resolves pool info from pid.
    IAuraBooster public immutable BOOSTER;

    /// @notice AURA token address — resolved from Booster.minter() at construction.
    address public immutable AURA_TOKEN;

    /// @notice True when deployed on Ethereum mainnet (cliff-schedule AURA derivation).
    ///         False on L2s (mintRate-based derivation via L2Coordinator).
    bool public immutable IS_MAINNET;

    /// @notice Mainnet AURA token interface (address(0) on L2).
    IAuraToken private immutable _IAURA;

    /// @notice L2Coordinator for bridged AURA (address(0) on mainnet).
    IL2Coordinator private immutable _L2_COORDINATOR;

    /// @notice Balancer V2 Vault address for V2 pool decomposition.
    ///         Universal across all EVM chains: 0xBA12222222228d8Ba445958a75a0704d566BF2C8
    ///         Pass address(0) to disable V2 pool support (V2 instances will emit no Supplied legs).
    address public immutable BALANCER_V2_VAULT;

    /// @param booster_           Aura Booster contract.
    ///                           Mainnet: 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234
    ///                           Arbitrum / Base: 0x98Ef32edd24e2c92525E59afc4475C1242a30184
    /// @param balancerV2Vault_   Balancer V2 Vault (0xBA12222222228d8Ba445958a75a0704d566BF2C8
    ///                           on all EVM chains). Pass address(0) to disable V2 support.
    /// @param protocolName_      Human-readable name (e.g. "Aura").
    /// @param navCalculator_     The NAVCalculator contract for asset-registry access.
    constructor(address booster_, address balancerV2Vault_, string memory protocolName_, address navCalculator_)
        MetaBalanceOracle(protocolName_, navCalculator_)
    {
        require(booster_.code.length > 0, "Booster must be a contract");
        BOOSTER = IAuraBooster(booster_);
        BALANCER_V2_VAULT = balancerV2Vault_;

        // Detect mainnet vs L2 from Booster.minter():
        //   Mainnet  → minter IS the AURA token (auraOFT() absent or returns address(0))
        //   L2       → minter IS the L2Coordinator (auraOFT() returns a non-zero bridged AURA address)
        // NOTE: The real AURA mainnet token has a storage-slot-read fallback, so a call to auraOFT()
        //       succeeds but returns 32 bytes of zeros. We therefore require the decoded address to be
        //       non-zero before treating the deployment as L2.
        address minter = BOOSTER.minter();
        (bool ok, bytes memory l2Data) = minter.staticcall(abi.encodeWithSignature("auraOFT()"));
        address maybeOft = (ok && l2Data.length >= 32) ? abi.decode(l2Data, (address)) : address(0);
        if (maybeOft != address(0)) {
            IS_MAINNET = false;
            _L2_COORDINATOR = IL2Coordinator(minter);
            AURA_TOKEN = maybeOft;
            _IAURA = IAuraToken(address(0));
        } else {
            IS_MAINNET = true;
            AURA_TOKEN = minter;
            _IAURA = IAuraToken(minter);
            _L2_COORDINATOR = IL2Coordinator(address(0));
        }
    }

    // ─── MetaBalanceOracle hooks ──────────────────────────────────────────────

    /// @inheritdoc MetaBalanceOracle
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        address auraRewards = _toAddress(instance);
        IStablePool pool = _poolOf(auraRewards);
        if (address(pool) == address(0)) return new INAVCalculator.PositionBalance[](0);

        uint256 stakedBpt = IAuraBaseRewardPool(auraRewards).balanceOf(account);

        // Detect pool version once — used by _maxTokens, _poolTokens, and the branch below.
        bool isV3 = _isV3Pool(address(pool));

        // Pre-allocate
        INAVCalculator.PositionBalance[] memory tmp =
            new INAVCalculator.PositionBalance[](_maxTokens(pool, isV3) + 2 + _MAX_EXTRA);
        uint256 n;
        bytes memory pid = _instancePositionId(instance);

        // ── 1. Supplied legs: staked BPT decomposed into Balancer pool tokens ─
        if (stakedBpt > 0) {
            address[] memory tokens = _poolTokens(address(pool), isV3);
            if (isV3) {
                // V3 path: live-scaled-balance math + ERC4626 unwrapping via BalancerV3PoolLib
                for (uint256 i; i < tokens.length; ++i) {
                    address tok = tokens[i];
                    if (assetFilter != address(0) && tok != assetFilter) continue;
                    (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(tok);
                    if (!found) continue;
                    uint256 amount = BalancerV3PoolLib.poolBalanceOf(pool, stakedBpt, tok);
                    if (amount == 0) continue;
                    tmp[n++] = INAVCalculator.PositionBalance({
                        balanceAsset: info,
                        balanceOracle: address(this),
                        amount: amount,
                        isDebt: false,
                        protocolId: PROTOCOL_ID,
                        positionId: pid,
                        positionKind: PositionKind.Supplied
                    });
                }
            } else if (BALANCER_V2_VAULT != address(0)) {
                // V2 path: raw Vault balances via BalancerV2PoolLib.
                // shares() returns (tokens, amounts) together, excluding the self-BPT in composable pools.
                bytes32 poolId;
                bool poolIdOk;
                try IBalancerV2Pool(address(pool)).getPoolId() returns (bytes32 _poolId) {
                    poolId = _poolId;
                    poolIdOk = true;
                } catch {}
                if (!poolIdOk) return positions; // non-standard V2 address — bail out gracefully
                (address[] memory v2Toks, uint256[] memory v2Amts) =
                    BalancerV2PoolLib.shares(BALANCER_V2_VAULT, poolId, address(pool), stakedBpt);
                for (uint256 i; i < v2Toks.length; ++i) {
                    address tok = v2Toks[i];
                    if (assetFilter != address(0) && tok != assetFilter) continue;
                    if (v2Amts[i] == 0) continue;
                    (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(tok);
                    if (!found) continue;
                    tmp[n++] = INAVCalculator.PositionBalance({
                        balanceAsset: info,
                        balanceOracle: address(this),
                        amount: v2Amts[i],
                        isDebt: false,
                        protocolId: PROTOCOL_ID,
                        positionId: pid,
                        positionKind: PositionKind.Supplied
                    });
                }
            }
        }

        // ── 2. Earned leg: BAL from main rewarder ─────────────────────────────
        address balToken = _safeAddr(auraRewards, abi.encodeWithSignature("rewardToken()"));
        uint256 totalAuraFromBal;
        if (balToken != address(0)) {
            uint256 balEarned = _earned(auraRewards, account);
            if (balEarned > 0 && (assetFilter == address(0) || assetFilter == balToken)) {
                (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(balToken);
                if (found) {
                    tmp[n++] = INAVCalculator.PositionBalance({
                        balanceAsset: info,
                        balanceOracle: address(this),
                        amount: balEarned,
                        isDebt: false,
                        protocolId: PROTOCOL_ID,
                        positionId: pid,
                        positionKind: PositionKind.Earned
                    });
                }
            }
            // Accumulate AURA derived from this pool's BAL rewards
            totalAuraFromBal += _auraFrom(auraRewards, balEarned);
        }

        // ── 3. Extra reward pools ─────────────────────────────────────────────
        (bool lenOk, uint256 extraLen) = _safeUint(auraRewards, abi.encodeWithSignature("extraRewardsLength()"));
        if (lenOk) {
            uint256 cap = extraLen > _MAX_EXTRA ? _MAX_EXTRA : extraLen;
            for (uint256 i; i < cap; ++i) {
                (bool eOk, address extraPool) =
                    _safeUintAddr(auraRewards, abi.encodeWithSignature("extraRewards(uint256)", i));
                if (!eOk || extraPool == address(0)) continue;

                address rawToken = _safeAddr(extraPool, abi.encodeWithSignature("rewardToken()"));
                if (rawToken == address(0)) continue;

                // Unwrap stash token → base token
                address rewardToken = _unstash(rawToken);

                // AURA from extra pool accumulates into the single AURA leg.
                // On L2 the mintRate applies only to BAL earned on the main rewarder, not to
                // arbitrary extra-reward tokens (LDO, stETH, etc.), so skip on L2.
                uint256 extraEarned = _earned(extraPool, account);
                if (IS_MAINNET) totalAuraFromBal += _auraFrom(extraPool, extraEarned);

                if (rewardToken == AURA_TOKEN || rewardToken == balToken) continue;
                if (assetFilter != address(0) && rewardToken != assetFilter) continue;
                if (extraEarned == 0) continue;

                (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(rewardToken);
                if (!found) continue;

                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: info,
                    balanceOracle: address(this),
                    amount: extraEarned,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: pid,
                    positionKind: PositionKind.Earned
                });
            }
        }

        // ── 4. Earned leg: AURA (aggregated from main + extra pools) ─────────
        if (
            totalAuraFromBal > 0 && AURA_TOKEN != address(0) && (assetFilter == address(0) || assetFilter == AURA_TOKEN)
        ) {
            (INAVCalculator.Asset memory info, bool found) = _getAssetInfo(AURA_TOKEN);
            if (found) {
                tmp[n++] = INAVCalculator.PositionBalance({
                    balanceAsset: info,
                    balanceOracle: address(this),
                    amount: totalAuraFromBal,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: pid,
                    positionKind: PositionKind.Earned
                });
            }
        }

        positions = new INAVCalculator.PositionBalance[](n);
        for (uint256 i; i < n; ++i) {
            positions[i] = tmp[i];
        }
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        address auraRewards = _toAddress(instance);
        IStablePool pool = _poolOf(auraRewards);

        address[] memory poolTokens =
            address(pool) != address(0) ? _poolTokens(address(pool), _isV3Pool(address(pool))) : new address[](0);

        address[] memory rwd = new address[](_MAX_EXTRA + 2);
        uint256 rn;
        address balToken = _safeAddr(auraRewards, abi.encodeWithSignature("rewardToken()"));
        if (balToken != address(0)) rwd[rn++] = balToken;
        if (AURA_TOKEN != address(0)) rwd[rn++] = AURA_TOKEN;

        (bool ok, uint256 len) = _safeUint(auraRewards, abi.encodeWithSignature("extraRewardsLength()"));
        if (ok) {
            uint256 cap = len > _MAX_EXTRA ? _MAX_EXTRA : len;
            for (uint256 i; i < cap; ++i) {
                (bool eOk, address ep) = _safeUintAddr(auraRewards, abi.encodeWithSignature("extraRewards(uint256)", i));
                if (!eOk) continue;
                address raw = _safeAddr(ep, abi.encodeWithSignature("rewardToken()"));
                address tok = _unstash(raw);
                bool dup;
                for (uint256 j; j < rn; ++j) {
                    if (rwd[j] == tok) dup = true;
                    break;
                }
                if (!dup) rwd[rn++] = tok;
            }
        }

        address[] memory all = new address[](poolTokens.length + rn);
        for (uint256 i; i < poolTokens.length; ++i) {
            all[i] = poolTokens[i];
        }
        for (uint256 i; i < rn; ++i) {
            all[poolTokens.length + i] = rwd[i];
        }
        return all;
    }

    // ─── IPositionDescribable ─────────────────────────────────────────────────

    /// @inheritdoc MetaBalanceOracle
    function describePosition(bytes calldata pid) external view override returns (string memory) {
        if (pid.length < 32) return "";
        address auraRewards = abi.decode(pid, (address));
        IStablePool pool = _poolOf(auraRewards);
        if (address(pool) == address(0)) return "";
        address[] memory tokens = _poolTokens(address(pool), _isV3Pool(address(pool)));
        if (tokens.length == 0) return "";
        string memory syms;
        for (uint256 i; i < tokens.length; ++i) {
            string memory s;
            try IERC20Metadata(tokens[i]).symbol() returns (string memory sym) {
                s = sym;
            } catch {
                s = "?";
            }
            syms = i == 0 ? s : string.concat(syms, "/", s);
        }
        return string.concat(syms, " Aura");
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @notice Resolves the Balancer pool from an Aura rewarder via Booster.poolInfo(pid).lptoken.
    function _poolOf(address auraRewards) internal view returns (IStablePool) {
        (bool pidOk, uint256 pid) = _safeUint(auraRewards, abi.encodeWithSignature("pid()"));
        if (!pidOk) return IStablePool(address(0));
        try BOOSTER.poolInfo(pid) returns (address lptoken, address, address, address, address, bool) {
            return IStablePool(lptoken);
        } catch {
            return IStablePool(address(0));
        }
    }

    /// @notice Returns the AURA amount derived from `balEarned` on a given rewarder.
    function _auraFrom(address rewarderAddr, uint256 balEarned) internal view returns (uint256) {
        if (balEarned == 0 || AURA_TOKEN == address(0)) return 0;
        if (IS_MAINNET) {
            // Apply Aura Booster reward multiplier before the cliff schedule
            uint256 multiplied = _applyMultiplier(rewarderAddr, balEarned);
            return _auraMintMainnet(multiplied);
        } else {
            return _auraMintL2(balEarned);
        }
    }

    function _applyMultiplier(address rewarderAddr, uint256 amount) internal view returns (uint256) {
        (bool ok1, uint256 multiplier) =
            _safeUint(address(BOOSTER), abi.encodeWithSignature("getRewardMultipliers(address)", rewarderAddr));
        (bool ok2, uint256 denom) =
            _safeUint(address(BOOSTER), abi.encodeWithSignature("REWARD_MULTIPLIER_DENOMINATOR()"));
        if (!ok1 || !ok2 || denom == 0) return amount;
        return (amount * multiplier) / denom;
    }

    /// @notice AURA mint amount via Aura's cliff emission schedule (Mainnet only).
    /// @dev Mirrors Aura.auraMintAmountConversion. Uses storage slot 2 of the AURA token to read
    ///      minterMinted (same low-level read as the per-instance adapter).
    function _auraMintMainnet(uint256 amount) internal view returns (uint256) {
        if (amount == 0 || address(_IAURA) == address(0)) return 0;
        uint256 supply = _IAURA.totalSupply();
        if (supply == 0) return 0;

        uint256 initMint = _IAURA.INIT_MINT_AMOUNT();
        uint256 minterMinted = _readSlot2(AURA_TOKEN);
        uint256 emissionsMinted = supply > initMint + minterMinted ? supply - initMint - minterMinted : 0;

        uint256 reductionPerCliff = _IAURA.reductionPerCliff();
        if (reductionPerCliff == 0) return 0;
        uint256 cliff = emissionsMinted / reductionPerCliff;
        uint256 totalCliffs = _IAURA.totalCliffs();
        if (cliff >= totalCliffs) return 0;

        uint256 reduction = ((totalCliffs - cliff) * 5) / 2 + 700;
        uint256 auraAmount = (amount * reduction) / totalCliffs;

        uint256 emissionsMax = _IAURA.EMISSIONS_MAX_SUPPLY();
        uint256 amtTillMax = emissionsMax > emissionsMinted ? emissionsMax - emissionsMinted : 0;
        return auraAmount > amtTillMax ? amtTillMax : auraAmount;
    }

    /// @notice AURA mint amount via L2Coordinator.mintRate() (L2 only).
    function _auraMintL2(uint256 balAmount) internal view returns (uint256) {
        if (address(_L2_COORDINATOR) == address(0)) return 0;
        (bool ok, uint256 mintRate) = _safeUint(address(_L2_COORDINATOR), abi.encodeWithSignature("mintRate()"));
        return (ok && mintRate > 0) ? (balAmount * mintRate) / 1e18 : 0;
    }

    /// @notice Reads storage slot 2 from `auraToken` — the minterMinted accumulator.
    function _readSlot2(address auraToken) internal view returns (uint256 result) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 2) // slot 2
            result := staticcall(gas(), auraToken, ptr, 0x20, ptr, 0x20)
            result := mload(ptr)
        }
    }

    /// @notice Unwraps a stash token wrapper to its base token (if it is one).
    function _unstash(address token) internal view returns (address) {
        if (token == address(0)) return token;
        (bool ok, address base) = _safeUintAddr(token, abi.encodeWithSignature("baseToken()"));
        return (ok && base != address(0)) ? base : token;
    }

    function _earned(address pool, address account) internal view returns (uint256) {
        (bool ok, uint256 amt) = _safeUint(pool, abi.encodeWithSignature("earned(address)", account));
        return ok ? amt : 0;
    }

    function _safeAddr(address target, bytes memory data) internal view returns (address result) {
        bytes memory ret;
        bool ok;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (address));
    }

    function _safeUint(address target, bytes memory data) internal view returns (bool ok, uint256 result) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (uint256));
    }

    // Helper: staticcall that returns a uint256 (for ABI methods that take a uint256 arg and return address)
    function _safeUintAddr(address target, bytes memory data) internal view returns (bool ok, address result) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length >= 32) result = abi.decode(ret, (address));
    }

    /// @notice Returns true if `pool` is a Balancer V3 pool (has getStablePoolDynamicData()).
    function _isV3Pool(address pool) internal view returns (bool ok) {
        (ok,) = pool.staticcall(abi.encodeWithSignature("getStablePoolDynamicData()"));
    }

    /// @notice Returns the pool's underlying tokens, dispatching to V3 or V2 path.
    /// @param isV3 Pre-computed result of `_isV3Pool(pool)` to avoid a redundant staticcall.
    function _poolTokens(address pool, bool isV3) internal view returns (address[] memory) {
        if (isV3) {
            return BalancerV3PoolLib.poolTokens(IStablePool(pool));
        }
        if (BALANCER_V2_VAULT != address(0)) {
            try IBalancerV2Pool(pool).getPoolId() returns (bytes32 poolId) {
                return BalancerV2PoolLib.poolTokens(BALANCER_V2_VAULT, poolId, pool);
            } catch {}
        }
        return new address[](0);
    }

    /// @param isV3 Pre-computed result of `_isV3Pool(pool)` to avoid a redundant staticcall.
    function _maxTokens(IStablePool pool, bool isV3) internal view returns (uint256) {
        if (isV3) {
            try pool.getStablePoolImmutableData() returns (IStablePool.StablePoolImmutableData memory d) {
                return d.tokens.length;
            } catch {}
        }
        return 8; // safe upper bound for V2 pools and fallback
    }
}

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IAuraBooster {
    function minter() external view returns (address);
    function getRewardMultipliers(address token) external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function REWARD_MULTIPLIER_DENOMINATOR() external view returns (uint256);
    function poolInfo(uint256 pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
}

interface IAuraBaseRewardPool {
    function pid() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 index) external view returns (address);
}

interface IAuraToken {
    function totalSupply() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function INIT_MINT_AMOUNT() external view returns (uint256);
    function reductionPerCliff() external view returns (uint256);
    function totalCliffs() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function EMISSIONS_MAX_SUPPLY() external view returns (uint256);
}

interface IL2Coordinator {
    function auraOFT() external view returns (address);
    function mintRate() external view returns (uint256);
}
