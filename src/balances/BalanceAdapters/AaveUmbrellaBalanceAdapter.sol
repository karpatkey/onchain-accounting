// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "../BalanceAdapterBase.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {RegisteredAssetLib} from "src/balances/RegisteredAssetLib.sol";
import {ERC4626RedeemLib} from "src/balances/ERC4626RedeemLib.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";

/// @title Aave Umbrella Balance Adapter (multi-token, dynamic discovery)
/// @author KPK
/// @notice Reports balances across every Aave Umbrella stake token registered with a single
///         `RewardsController` (the protocol's trust anchor, pinned at construction). For each
///         stake position the adapter emits up to three `PositionBalance` entries:
///           - `(<bareReserve>, PositionKind.Staking)` — the user's principal denominated in the
///             bare reserve token (e.g. USDC, USDT, WETH, GHO). The principal is split by
///             withdrawability into a locked leg (`isLocked=true`) and an unlocked leg
///             (`isLocked=false`), so it may yield up to two entries.
///           - `(<bareReserve>, PositionKind.Rewards)` — the user's claimable but unclaimed rewards,
///             also denominated in the bare reserve. Reward aTokens are 1:1 unit-equivalent with
///             their underlying reserve, so the amount returned by `calculateCurrentUserRewards`
///             can be treated as bare-reserve-denominated. The `positionId` (`abi.encode(stakeToken)`)
///             disambiguates which stake token the position belongs to.
/// @dev The full Umbrella stake-token set is discovered at runtime via
///      `RewardsController.getAllAssets()`. For each stake token the adapter follows at most one
///      ERC4626 wrapper hop on the `asset()` chain — `stk → waToken → bare reserve` for the
///      `stkwaEth*` family, or `stk → bare reserve` for stake tokens whose underlying is already a
///      plain ERC20 (e.g. `stkGHO.v1`). Reward tokens are translated to the bare reserve via
///      `IAToken.UNDERLYING_ASSET_ADDRESS()`; tokens that do not implement that getter are treated
///      as already-bare (e.g. plain GHO for stkGHO.v1).
///
///      Each external probe (`asset()`, `convertToAssets(uint256)`, `UNDERLYING_ASSET_ADDRESS()`)
///      is performed via a low-level staticcall with a tight gas budget (`PROBE_GAS`) so a
///      misbehaving fallback on a non-ERC4626 token (e.g. legacy WETH9, USDC's transparent proxy)
///      cannot drain the parent call's gas. Probe failures are interpreted as "this token is not a
///      wrapper / not an aToken" and the walk falls back to the safe default.
///
///      No stake-token, waToken, aToken, or reserve addresses are hardcoded in this adapter — only
///      the trust-anchor `RewardsController` is pinned via constructor argument. Aave governance
///      can add a new Umbrella stake token (or change the reward token configured on an existing
///      one) and the adapter will pick it up automatically, provided the bare reserve it ultimately
///      reports against is registered on `NAVCalculator` with a price feed. Unregistered reserves
///      are silently skipped — same convention used by the Aave lending adapters.
///
///      Slashing-correctness: Umbrella stake tokens reduce `totalAssets` while keeping
///      `totalSupply` constant when slashing fires, so the chained `convertToAssets` walk is
///      automatically post-slash-correct without extra accounting.
///
///      Cooldown / unstake-window state does not affect `balanceOf`. The balance methods report total staked
///      principal regardless of window, but `getAdapterPositions` splits the principal by withdrawability into a
///      locked leg (`isLocked=true` — active stake + a cooldown still cooling/expired) and an unlocked leg
///      (`isLocked=false` — a cooldown elapsed and inside the withdrawal window), both under
///      `positionId = abi.encode(stakeToken)` — read from `getStakerCooldown`. Total value is unchanged.
contract AaveUmbrellaBalanceAdapter is BalanceAdapterBase {
    /// @dev Gas forwarded to single-word probes (`asset()`, `convertToAssets(uint256)`,
    ///      `UNDERLYING_ASSET_ADDRESS()`). 30k covers a normal SLOAD-and-return path comfortably
    ///      while preventing a misbehaving fallback (cf. WETH9 dispatching unknown selectors to
    ///      `deposit()`, USDC's proxy chain) from burning the caller's remaining gas budget.
    uint256 private constant PROBE_GAS = 30_000;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.AAVE;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.AAVE_V3_UMBRELLA;

    //
    // State
    //

    /// @notice Aave Umbrella RewardsController — the trust anchor for stake-token enumeration.
    /// @dev Pinned at construction. All stake-token / reward-token discovery flows through this address.
    IUmbrellaRewardsController public immutable REWARDS_CONTROLLER;

    /// @notice Reference to NAVCalculator for asset registry lookups.
    INAVCalculator public immutable NAV_CALCULATOR;

    //
    // Constructor
    //

    /// @param rewardsController The Umbrella RewardsController address (registry root). Required to be a contract.
    /// @param navCalculator The NAVCalculator address (used to look up registered assets when emitting positions).
    constructor(address rewardsController, address navCalculator) {
        if (rewardsController == address(0) || navCalculator == address(0)) {
            revert InvalidArguments();
        }
        AddressCheckLib.requireContract(rewardsController, "RewardsController");
        AddressCheckLib.requireContract(navCalculator, "NAVCalculator");
        REWARDS_CONTROLLER = IUmbrellaRewardsController(rewardsController);
        NAV_CALCULATOR = INAVCalculator(navCalculator);
    }

    //
    // IERC165
    //

    /// @inheritdoc IPositionDescribable
    /// @dev Names the PROTOCOL, not the product: Umbrella is one of Aave V3's three products in this repo
    ///      (lending instances, Safety Module, Umbrella), all sharing `ProtocolIds.AAVE_V3`, so all three report
    ///      "Aave V3". The product is carried by `positionLabels()` (`["Umbrella Module"]`) and by the typed
    ///      `protocolSubId` (`AAVE_V3_UMBRELLA`). Returning "Aave Umbrella" here — as this adapter did before —
    ///      made consumers that group configured adapters by display name list Umbrella as a peer protocol of
    ///      Aave V3 rather than one of its products. See `src/utils/ProtocolNames.sol`.
    function protocolName() external pure returns (string memory) {
        return ProtocolNames.AAVE_V3;
    }

    /// @inheritdoc IPositionDescribable
    /// @dev Single-segment breadcrumb: the category IS the leaf. Rendered as `["Aave V3", "Umbrella Module"]`
    ///      alongside `protocolName()`.
    function positionLabels(bytes calldata) external pure override returns (string[] memory) {
        string[] memory out = new string[](1);
        out[0] = "Umbrella Module";
        return out;
    }

    //
    // IBalanceAdapter
    //

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns the deduplicated set of bare reserves this adapter currently reports against.
    /// @dev Walks every stake token registered with the RewardsController, resolves each one's
    ///      bare reserve, and dedupes. Reward-side underlyings are not surfaced here because they
    ///      are mapped onto the bare reserve unit-for-unit and therefore add no new assets.
    function underlyingAssetsSupported() external view override returns (address[] memory) {
        address[] memory stakeTokens = REWARDS_CONTROLLER.getAllAssets();
        address[] memory tmp = new address[](stakeTokens.length);
        uint256 count;
        for (uint256 i; i < stakeTokens.length; ++i) {
            address bare = _resolveBareReserve(stakeTokens[i]);
            if (bare == address(0)) continue;
            if (_contains(tmp, count, bare)) continue;
            tmp[count++] = bare;
        }
        address[] memory out = new address[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns the **summed** balance for `asset` (staked + rewards) across every Umbrella
    ///         stake token whose bare reserve equals `asset`.
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        address[] memory stakeTokens = REWARDS_CONTROLLER.getAllAssets();
        uint256 total;
        for (uint256 i; i < stakeTokens.length; ++i) {
            address stk = stakeTokens[i];
            address bare = _resolveBareReserve(stk);
            if (bare != asset) continue;
            total += _stakedUnderlying(stk, account);
            total += _claimableRewardInBareReserve(stk, account, bare);
        }
        return (total, false);
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns deduplicated per-asset summed balances. Skips zero amounts.
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) {
            return (new address[](0), new uint256[](0), new bool[](0));
        }

        address[] memory stakeTokens = REWARDS_CONTROLLER.getAllAssets();
        address[] memory tmpAssets = new address[](stakeTokens.length);
        uint256[] memory tmpAmounts = new uint256[](stakeTokens.length);
        uint256 count;

        for (uint256 i; i < stakeTokens.length; ++i) {
            address stk = stakeTokens[i];
            address bare = _resolveBareReserve(stk);
            if (bare == address(0)) continue;

            uint256 contribution = _stakedUnderlying(stk, account) + _claimableRewardInBareReserve(stk, account, bare);
            if (contribution == 0) continue;

            (uint256 idx, bool found) = _indexOf(tmpAssets, count, bare);
            if (found) {
                tmpAmounts[idx] += contribution;
            } else {
                tmpAssets[count] = bare;
                tmpAmounts[count] = contribution;
                ++count;
            }
        }

        assets = new address[](count);
        amounts = new uint256[](count);
        isDebt = new bool[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = tmpAssets[i];
            amounts[i] = tmpAmounts[i];
        }
    }

    /// @inheritdoc IBalanceAdapter
    /// @notice Returns PositionBalance legs per stake token: the staking principal split by
    ///         withdrawability into a locked and an unlocked leg (`PositionKind.Staking`), plus a
    ///         `PositionKind.Rewards` leg — up to three legs per stake token.
    /// @dev Each emitted position is self-describing through its typed identity fields
    ///      (`protocolBrand`/`protocolId`/`protocolSubId`, `positionId`, `positionKind`, `isLocked`).
    ///      Zero-amount legs are skipped. Stake tokens whose bare reserve is not registered on
    ///      NAVCalculator are silently skipped (same convention as the Aave V3 lending adapters).
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory stakeTokens = REWARDS_CONTROLLER.getAllAssets();

        // Worst case: 3 positions per stake token (free stake + unstaking cooldown + Rewards).
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](stakeTokens.length * 3);
        uint256 count;

        for (uint256 i; i < stakeTokens.length; ++i) {
            address stk = stakeTokens[i];
            address bare = _resolveBareReserve(stk);
            if (bare == address(0)) continue;
            if (!_passesFilter(bare, assetFilter)) continue;

            (INAVCalculator.Asset memory assetMeta,) = RegisteredAssetLib.find(registered, bare);
            if (assetMeta.asset == address(0)) continue;

            // Staked-token leg(s): split by withdrawability. isLocked = non-withdrawable. The only withdrawable
            // portion is a cooldown that has elapsed and is inside the withdrawal window; everything else (active
            // stake + a cooldown still cooling or past the window) is locked. Both legs share
            // `positionId = abi.encode(stakeToken)` and are told apart by `isLocked`.
            {
                uint256 balShares = IUmbrellaStakeToken(stk).balanceOf(account);
                (, uint256 cooldownShares, bool inWindow) = _umbrellaCooldownSplit(stk, account, balShares);
                uint256 unlockedShares = inWindow ? cooldownShares : 0;
                uint256 lockedShares = balShares - unlockedShares;

                // Locked = non-withdrawable (active stake + cooling/expired cooldown).
                if (lockedShares != 0) {
                    uint256 amt = _sharesToUnderlying(stk, lockedShares);
                    if (amt != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            balanceAsset: assetMeta,
                            balanceAdapter: address(this),
                            amount: amt,
                            isDebt: false,
                            protocolBrand: PROTOCOL_BRAND,
                            protocolId: PROTOCOL_ID,
                            protocolSubId: PROTOCOL_SUB_ID,
                            positionId: abi.encode(address(stk)),
                            positionKind: PositionKind.Staking,
                            isLocked: true,
                            positionInstanceId: bytes32(0)
                        });
                    }
                }

                // Unlocked = withdrawable now (cooldown elapsed and inside the withdrawal window).
                if (unlockedShares != 0) {
                    uint256 amt = _sharesToUnderlying(stk, unlockedShares);
                    if (amt != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            balanceAsset: assetMeta,
                            balanceAdapter: address(this),
                            amount: amt,
                            isDebt: false,
                            protocolBrand: PROTOCOL_BRAND,
                            protocolId: PROTOCOL_ID,
                            protocolSubId: PROTOCOL_SUB_ID,
                            positionId: abi.encode(address(stk)),
                            positionKind: PositionKind.Staking,
                            isLocked: false,
                            positionInstanceId: bytes32(0)
                        });
                    }
                }
            }

            // Rewards leg.
            uint256 rewardAmount = _claimableRewardInBareReserve(stk, account, bare);
            if (rewardAmount != 0) {
                tmp[count++] = INAVCalculator.PositionBalance({
                    balanceAsset: assetMeta,
                    balanceAdapter: address(this),
                    amount: rewardAmount,
                    isDebt: false,
                    protocolBrand: PROTOCOL_BRAND,
                    protocolId: PROTOCOL_ID,
                    protocolSubId: PROTOCOL_SUB_ID,
                    positionId: abi.encode(address(stk)),
                    positionKind: PositionKind.Rewards,
                    isLocked: false,
                    positionInstanceId: bytes32(0)
                });
            }
        }

        positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i; i < count; ++i) {
            positions[i] = tmp[i];
        }
    }

    //
    // Internal — balance math
    //

    /// @dev Translate the user's full stake-token balance into the bare reserve. Returns 0 when no shares.
    function _stakedUnderlying(address stakeToken, address account) internal view returns (uint256) {
        return _sharesToUnderlying(stakeToken, IUmbrellaStakeToken(stakeToken).balanceOf(account));
    }

    /// @dev Translate a specific stake-token share amount into the bare reserve via at most one ERC4626
    ///      wrapper hop. Returns 0 when `shares` is 0 (skips the hops), and also when the wrapper hop's
    ///      fee-net `previewRedeem` cannot be read — see {ERC4626RedeemLib.redeemValue} for why that is a 0
    ///      and not a fee-inclusive estimate.
    function _sharesToUnderlying(address stakeToken, uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        uint256 amount = IUmbrellaStakeToken(stakeToken).convertToAssets(shares);

        // First-level asset: e.g. `stkwaEthUSDC.asset() = waEthUSDC`, or `stkGHO.asset() = GHO`.
        address firstLevel = _safeAsset(stakeToken);
        if (firstLevel == address(0)) return amount;

        // If the first-level asset is itself a real ERC4626 wrapper (waToken), walk one more hop to the bare
        // reserve. Use previewRedeem so a redemption fee on the wrapper (possible via Aave governance) is not
        // over-reported (convertToAssets ignores it per EIP-4626 §4.3). If preview cannot be read the hop
        // reports 0 and the caller skips the leg — it does NOT fall back to convertToAssets, which would report
        // the fee-inclusive figure and inflate the position. See {ERC4626RedeemLib.redeemValue}.
        if (_isErc4626Wrapper(firstLevel)) {
            return ERC4626RedeemLib.redeemValue(firstLevel, amount);
        }
        return amount;
    }

    /// @dev Splits an account's stake-token shares into a free (live-stake) portion and an unstaking (cooldown)
    ///      portion, and reports whether the cooldown is inside its claim window. Reads Umbrella's per-user cooldown
    ///      snapshot (`getStakerCooldown` → `(amount, endOfCooldown, withdrawalWindow)`; the window is snapshotted per
    ///      cooldown, so it is read from the struct, not a global getter). Any read failure degrades gracefully to
    ///      "entire balance is free, no cooldown leg".
    /// @return freeShares Shares not committed to a cooldown (live stake).
    /// @return cooldownShares Shares committed to the active cooldown (= min(cooldown amount, balance)).
    /// @return inWindow True iff the cooldown has elapsed and is still within its withdrawal window (claimable now).
    function _umbrellaCooldownSplit(address stakeToken, address account, uint256 balShares)
        internal
        view
        returns (uint256 freeShares, uint256 cooldownShares, bool inWindow)
    {
        if (balShares == 0) {
            return (0, 0, false);
        }

        IUmbrellaStakeToken.CooldownSnapshot memory s;
        try IUmbrellaStakeToken(stakeToken).getStakerCooldown(account) returns (
            IUmbrellaStakeToken.CooldownSnapshot memory snap
        ) {
            s = snap;
        } catch {
            return (balShares, 0, false);
        }
        if (s.amount == 0) {
            return (balShares, 0, false); // no active cooldown
        }

        cooldownShares = uint256(s.amount) < balShares ? uint256(s.amount) : balShares;
        freeShares = balShares - cooldownShares;
        inWindow =
            block.timestamp >= s.endOfCooldown && block.timestamp <= uint256(s.endOfCooldown) + s.withdrawalWindow;
    }

    /// @dev Pull `(rewardTokens[], amounts[])` from the controller, then for each reward token
    ///      resolve its bare reserve (via `IAToken.UNDERLYING_ASSET_ADDRESS()` when present, else
    ///      the reward token itself), and sum amounts whose resolved bare reserve equals
    ///      `wantedBareReserve`.
    function _claimableRewardInBareReserve(address stakeToken, address user, address wantedBareReserve)
        internal
        view
        returns (uint256 total)
    {
        (address[] memory tokens, uint256[] memory amounts) =
            REWARDS_CONTROLLER.calculateCurrentUserRewards(stakeToken, user);
        for (uint256 i; i < tokens.length; ++i) {
            address bare = _resolveRewardBareReserve(tokens[i]);
            if (bare == wantedBareReserve) {
                total += amounts[i];
            }
        }
    }

    //
    // Internal — discovery
    //

    /// @dev Resolve a stake token's bare reserve by following at most one ERC4626 wrapper hop.
    ///      Returns address(0) when the chain doesn't terminate at a non-ERC4626 token within one
    ///      hop, or when `stakeToken.asset()` itself is unreachable.
    function _resolveBareReserve(address stakeToken) internal view returns (address) {
        address firstLevel = _safeAsset(stakeToken);
        if (firstLevel == address(0)) return address(0);
        // If the first-level asset is itself a wrapper, the bare reserve is the wrapper's `asset()`.
        // Otherwise the first-level asset IS the bare reserve.
        if (_isErc4626Wrapper(firstLevel)) {
            address bare = _safeAsset(firstLevel);
            return bare == address(0) ? address(0) : bare;
        }
        return firstLevel;
    }

    /// @dev Detect whether `token` looks like an ERC4626 wrapper. The probe combines two checks:
    ///        - `asset()` succeeds and returns a non-zero address.
    ///        - `convertToAssets(0)` succeeds and returns exactly 0 (the canonical ERC4626 invariant).
    ///      A token whose fallback returns garbage / empty data on unknown selectors fails one or
    ///      both checks and is correctly classified as non-wrapper.
    function _isErc4626Wrapper(address token) internal view returns (bool) {
        // asset() must return a non-zero address.
        address inner = _safeAsset(token);
        if (inner == address(0)) return false;
        // convertToAssets(0) must succeed and return exactly 0.
        (bool ok, bytes memory ret) =
            token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("convertToAssets(uint256)", uint256(0)));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == 0;
    }

    /// @dev Resolve a reward token's bare reserve. aTokens expose `UNDERLYING_ASSET_ADDRESS()`
    ///      returning the bare reserve; non-aToken reward tokens (e.g. plain GHO for stkGHO.v1)
    ///      and tokens with permissive fallbacks return as-is.
    function _resolveRewardBareReserve(address rewardToken) internal view returns (address) {
        (, address bare) =
            StaticCallLib.safeAddr(rewardToken, abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"));
        return bare == address(0) ? rewardToken : bare;
    }

    /// @dev `IERC4626.asset()` via {StaticCallLib.safeAddr}. Returns address(0) when the call reverts, the
    ///      target has no code, the reply is short, or the returned word masks to zero.
    ///
    ///      Routed through the shared reader rather than a hand-rolled `staticcall` + `abi.decode` for three
    ///      reasons, in increasing order of how much they matter:
    ///        1. `abi.decode(ret, (address))` emits a range validator that REVERTS on a word with dirty bits
    ///           above 160, in THIS frame, past any `catch` — so a reward or stake token answering with a
    ///           `bytes32`-shaped word took the whole adapter out of the NAV read. `safeAddr` masks instead.
    ///        2. Assigning `(bool, bytes memory)` from a raw staticcall makes solc `returndatacopy` the ENTIRE
    ///           reply into fresh memory, and the caller pays that quadratically, OUTSIDE the gas stipend. A
    ///           token returning ~200KB is cheap for the callee and expensive here. `safeAddr` writes through a
    ///           fixed 32-byte output window, so reply size cannot influence this contract's gas at all.
    ///        3. It is one reader instead of a fourth local copy.
    ///
    ///      This raises the ceiling on these two probes from this file's `PROBE_GAS` (30_000) to
    ///      `StaticCallLib.PROBE_GAS` (100_000). Deliberate, and the safe direction: the failure mode of too
    ///      tight a cap is a spurious `address(0)` that silently drops a real position, while the thing a
    ///      generous cap exposes, an expensive hostile callee, is bounded by the cap AND by the output window,
    ///      which the 30_000 version was not.
    function _safeAsset(address token) internal view returns (address) {
        (, address underlyingAsset) = StaticCallLib.safeAddr(token, abi.encodeWithSignature("asset()"));
        return underlyingAsset;
    }

    //
    // Internal — array helpers
    //

    function _passesFilter(address asset, address assetFilter) internal pure returns (bool) {
        return assetFilter == address(0) || assetFilter == asset;
    }

    function _contains(address[] memory arr, uint256 length, address needle) internal pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (arr[i] == needle) return true;
        }
        return false;
    }

    function _indexOf(address[] memory arr, uint256 length, address needle)
        internal
        pure
        returns (uint256 idx, bool found)
    {
        for (uint256 i; i < length; ++i) {
            if (arr[i] == needle) return (i, true);
        }
        return (0, false);
    }
}

/// @notice Minimal interface for an Aave Umbrella stake token (ERC4626 vault with slashing semantics).
/// @dev Reference impl: https://github.com/aave-dao/aave-umbrella/blob/main/src/contracts/stakeToken/StakeToken.sol
interface IUmbrellaStakeToken {
    /// @notice Per-user cooldown snapshot. `amount` shares become redeemable in
    ///         `[endOfCooldown, endOfCooldown + withdrawalWindow]`; the window is snapshotted at cooldown time.
    struct CooldownSnapshot {
        uint192 amount;
        uint32 endOfCooldown;
        uint32 withdrawalWindow;
    }

    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice The account's cooldown snapshot. A zero `amount` means no active cooldown.
    /// @dev Older/other stake-token versions may not expose this ABI; callers must tolerate a call/decode failure.
    function getStakerCooldown(address user) external view returns (CooldownSnapshot memory);
}

/// @notice Minimal interface for the Aave Umbrella RewardsController (multi-reward distributor).
/// @dev Reference impl: https://github.com/aave-dao/aave-umbrella/tree/main/src/contracts/rewards
interface IUmbrellaRewardsController {
    /// @notice Enumerates every stake token currently tracked by the controller.
    function getAllAssets() external view returns (address[] memory);

    /// @notice Claimable reward amounts for a user on a given stake token, broken down by reward token.
    /// @param asset Stake-token address (must be present in `getAllAssets()`).
    /// @param user Address whose claimable rewards to query.
    /// @return rewardTokens Reward token addresses configured for `asset`.
    /// @return amounts Corresponding claimable but unclaimed amounts (in reward-token units).
    function calculateCurrentUserRewards(address asset, address user)
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory amounts);
}
