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
///      goes through {StaticCallLib}, which bounds both the callee's gas and — via a fixed 32-byte
///      output window — how much returndata this contract can be made to copy, so a misbehaving
///      fallback on a non-ERC4626 token (e.g. legacy WETH9, USDC's transparent proxy) cannot drain
///      the parent call's gas. It also masks a dirty address word rather than reverting on it, which
///      a local `abi.decode` did not. Probe failures are interpreted as "this token is not a wrapper
///      / not an aToken" and the walk falls back to the safe default.
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
    // The local `PROBE_GAS = 30_000` that used to sit here is gone: every single-word probe now routes through
    // {StaticCallLib}, which carries the repo-wide `PROBE_GAS` (100_000) plus a fixed 32-byte output window that
    // the hand-rolled `(bool, bytes memory)` form did not have. See {_safeAsset} for why the higher ceiling is
    // the safe direction. Leaving the constant behind as dead code would have implied a bound that no longer
    // applies to anything.

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
    ///      cooldown, so it is read from the struct, not a global getter).
    ///
    ///      A read failure returns `(balShares, 0, false)`. Note what the CALLER then produces: `unlockedShares`
    ///      is 0, so `lockedShares == balShares` and the whole principal is emitted as one LOCKED leg. An
    ///      earlier version of this line said the balance degrades to "free", which is the opposite of what
    ///      ships — `freeShares` is in fact discarded by the only caller. Corrected in review.
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

        // Raw bounded staticcall, NOT `try`/`catch`. This is the same shape `ERC4626RedeemLib` was rewritten
        // for, in the same call chain: a high-level call expecting return data emits no `extcodesize` check, so
        // a stake token whose `getStakerCooldown` SUCCEEDS with zero bytes makes the struct decode revert in
        // THIS frame, past the `catch`. And this adapter has no per-stake-token isolation — the revert would
        // propagate out of `getAdapterPositions`, `PriceFeedLib` would score it benign, and every Umbrella
        // staking, cooldown and rewards leg would vanish from the NAV with no signal. The interface's own doc
        // promises callers "must tolerate a call/decode failure"; `try`/`catch` did not deliver that.
        //
        // A fixed cap is acceptable HERE, unlike in `ERC4626RedeemLib`: this read is classification-only. It
        // splits an already-computed `balShares` into locked/unlocked legs and cannot change any amount, so a
        // starved probe degrades to "all locked" — cosmetic, and never a number.
        uint256 cdAmount;
        uint256 cdEnd;
        uint256 cdWindow;
        {
            // The repo-wide probe budget, not a second local copy of the same number — this file deleted its
            // own `PROBE_GAS` for exactly that reason and reintroducing an identical constant four lines below
            // that explanation was the inconsistency review flagged. A FIXED cap is safe here specifically
            // because this read is classification-only: `cdAmount` can only ever narrow `cooldownShares`, and
            // the leg total is `balShares` for every value of it, so no probe outcome can move an amount.
            uint256 probeGas = StaticCallLib.PROBE_GAS;
            bytes memory cd = abi.encodeWithSelector(IUmbrellaStakeToken.getStakerCooldown.selector, account);
            bool ok;
            uint256 size;
            assembly ("memory-safe") {
                let out := mload(0x40)
                mstore(out, 0)
                mstore(add(out, 0x20), 0)
                mstore(add(out, 0x40), 0)
                ok := staticcall(probeGas, stakeToken, add(cd, 0x20), mload(cd), out, 0x60)
                size := returndatasize()
                // MASK to the declared widths. Taking the raw read without the mask discards exactly the
                // validation the `uint192`/`uint32` decoder performed, and the arithmetic below is CHECKED:
                // a reply of (1, 1, 2**256-1) makes `cdEnd + cdWindow` panic with Panic(0x11) in THIS frame,
                // past every `catch` — reinstating the uncatchable revert this read was rewritten to remove.
                // `shl`/`shr` for the 192-bit field rather than a 48-digit hex literal, which is easy to
                // miscount. Masking also bounds `cdEnd + cdWindow` by 2**33, so the checked add cannot
                // overflow at all. This is the same "mask, do not trust the word" rule {_safeAsset} states
                // for addresses further down this file. Found in review.
                cdAmount := shr(64, shl(64, mload(out)))
                cdEnd := and(mload(add(out, 0x20)), 0xffffffff)
                cdWindow := and(mload(add(out, 0x40)), 0xffffffff)
            }
            // The snapshot is three static fields, so a canonical reply is exactly three words.
            if (!ok || size < 0x60) return (balShares, 0, false);
        }
        if (cdAmount == 0) {
            return (balShares, 0, false); // no active cooldown
        }

        cooldownShares = cdAmount < balShares ? cdAmount : balShares;
        freeShares = balShares - cooldownShares;
        inWindow = block.timestamp >= cdEnd && block.timestamp <= cdEnd + cdWindow;
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
    ///      Returns address(0) only when `stakeToken.asset()` itself is unreachable.
    ///
    ///      **One `asset()` read per hop, reused.** This used to read `firstLevel.asset()` TWICE — once inside
    ///      `_isErc4626Wrapper`, then again to take the result — and treat a zero from the second read as
    ///      "unresolvable", dropping the stake token's entire set of legs (staking, cooldown and rewards) with
    ///      no way for a caller to distinguish that from "this account holds nothing here". Two reads of the same
    ///      view can only disagree for a reason that is not about the token: the second one starving. A fixed
    ///      `{gas: …}` ceiling cannot be escaped by a caller supplying more gas, so that drop was both silent and
    ///      unrecoverable. {_wrapperAsset} performs the read once and hands back the value the test was based on,
    ///      which removes the disagreeing window rather than papering over it.
    ///
    ///      The remaining `address(0)` — `stakeToken.asset()` unreadable — is genuinely "this is not an Umbrella
    ///      stake token", and the callers' `continue` is correct for it.
    function _resolveBareReserve(address stakeToken) internal view returns (address) {
        address firstLevel = _safeAsset(stakeToken);
        if (firstLevel == address(0)) return address(0);
        // If the first-level asset is itself a wrapper, the bare reserve is the wrapper's `asset()` — the very
        // value the wrapper test just read. Otherwise the first-level asset IS the bare reserve.
        address bare = _wrapperAsset(firstLevel);
        return bare == address(0) ? firstLevel : bare;
    }

    /// @dev `token.asset()` when `token` looks like an ERC4626 wrapper, else `address(0)`. The probe combines:
    ///        - `asset()` succeeds and returns a non-zero address;
    ///        - `convertToAssets(0)` returns a full word that is exactly 0 (the canonical ERC4626 invariant).
    ///      A token whose fallback returns garbage / empty data on unknown selectors fails one or both and is
    ///      correctly classified as non-wrapper.
    ///
    ///      `convertToAssets(0)` is gated on {StaticCallLib.probeWord}'s `hasWord`, NOT on `safeUint`'s `ok`.
    ///      The distinction is load-bearing precisely here, and is the trap {StaticCallLib} documents: `ok` is
    ///      the raw staticcall flag and stays true for a callee that returns NOTHING, so `safeUint` would hand
    ///      back `(true, 0)` — and 0 is this test's success condition. Every code-less address and every silent
    ///      fallback would have been promoted to "ERC4626 wrapper".
    function _wrapperAsset(address token) internal view returns (address) {
        address inner = _safeAsset(token);
        if (inner == address(0)) return address(0);
        (, bool hasWord, uint256 converted) =
            StaticCallLib.probeWord(token, abi.encodeWithSignature("convertToAssets(uint256)", uint256(0)));
        if (!hasWord || converted != 0) return address(0);
        return inner;
    }

    /// @dev Detect whether `token` looks like an ERC4626 wrapper. Thin wrapper over {_wrapperAsset} so there is
    ///      exactly one implementation of the test and it cannot drift from the value {_resolveBareReserve} uses.
    function _isErc4626Wrapper(address token) internal view returns (bool) {
        return _wrapperAsset(token) != address(0);
    }

    /// @dev Resolve a reward token's bare reserve. aTokens expose `UNDERLYING_ASSET_ADDRESS()`
    ///      returning the bare reserve; non-aToken reward tokens (e.g. plain GHO for stkGHO.v1)
    ///      and tokens with permissive fallbacks return as-is.
    function _resolveRewardBareReserve(address rewardToken) internal view returns (address) {
        (, address bare) = StaticCallLib.safeAddr(rewardToken, abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"));
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
    ///      This raises the ceiling on these probes from this file's former `PROBE_GAS` (30_000) to
    ///      `StaticCallLib.PROBE_GAS` (100_000), and that local constant is now gone. Deliberate, and the safe
    ///      direction: the failure mode of too tight a cap is a spurious `address(0)` that silently drops a real
    ///      position — the very defect {_resolveBareReserve} was fixed for — while the thing a generous cap
    ///      exposes, an expensive hostile callee, is bounded by the cap AND by the output window, which the
    ///      30_000 version was not.
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
