// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Aave Umbrella Balance Oracle (multi-token, dynamic discovery)
/// @author kpk
/// @notice Reports balances across every Aave Umbrella stake token registered with a single
///         `RewardsController` (the protocol's trust anchor, pinned at construction). For each
///         stake position the adapter emits up to two `PositionBalance` entries:
///           - `(<bareReserve>, type="Staking")` — the user's principal denominated in the bare
///             reserve token (e.g. USDC, USDT, WETH, GHO).
///           - `(<bareReserve>, type="Rewards")` — the user's claimable but unclaimed rewards,
///             also denominated in the bare reserve. Reward aTokens are 1:1 unit-equivalent with
///             their underlying reserve, so the amount returned by `calculateCurrentUserRewards`
///             can be treated as bare-reserve-denominated. The `underlyingAsset` field disambiguates
///             which stake token the position belongs to.
/// @dev The full Umbrella stake-token set is discovered at runtime via
///      `RewardsController.getAllAssets()`. For each stake token the adapter follows at most one
///      ERC4626 wrapper hop on the `asset()` chain — `stk → waToken → bare reserve` for the
///      `stkwaEth*` family, or `stk → bare reserve` for stake tokens whose underlying is already a
///      plain ERC20 (e.g. `stkGHO.v1`). Reward tokens are translated to the bare reserve via
///      `IAToken.UNDERLYING_ASSET_ADDRESS()`; tokens that do not implement that getter are treated
///      as already-bare (e.g. plain GHO for stkGHO.v1).
///
///      Each external probe (`asset()`, `convertToAssets(uint256)`, `UNDERLYING_ASSET_ADDRESS()`,
///      `symbol()`) is performed via a low-level staticcall with a tight gas budget (≤ 50k) so a
///      misbehaving fallback on a non-ERC4626 token (e.g. legacy WETH9, USDC's transparent proxy)
///      cannot drain the parent call's gas. Probe failures are interpreted as "this token is not a
///      wrapper / not an aToken" and the walk falls back to the safe default.
///
///      No stake-token, waToken, aToken, or reserve addresses are hardcoded in this adapter — only
///      the trust-anchor `RewardsController` is pinned via constructor argument. Aave governance
///      can add a new Umbrella stake token (or change the reward token configured on an existing
///      one) and the adapter will pick it up automatically, provided the bare reserve it ultimately
///      reports against is registered on `NAVCalculator` with a price feed. Unregistered reserves
///      are silently skipped — same convention used by `AaveV3InstanceBalanceOracle`.
///
///      Slashing-correctness: Umbrella stake tokens reduce `totalAssets` while keeping
///      `totalSupply` constant when slashing fires, so the chained `convertToAssets` walk is
///      automatically post-slash-correct without extra accounting.
///
///      Cooldown / unstake-window state does not affect `balanceOf`, so this adapter reports total
///      staked principal regardless of which window the user is in.
contract AaveUmbrellaBalanceOracle is IBalanceOracleAdapter {
    /// @dev Gas forwarded to single-word probes (`asset()`, `convertToAssets(uint256)`,
    ///      `UNDERLYING_ASSET_ADDRESS()`). 30k covers a normal SLOAD-and-return path comfortably
    ///      while preventing a misbehaving fallback (cf. WETH9 dispatching unknown selectors to
    ///      `deposit()`, USDC's proxy chain) from burning the caller's remaining gas budget.
    uint256 private constant PROBE_GAS = 30_000;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.AAVE_V3_UMBRELLA;

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
        require(rewardsController.code.length > 0, "RewardsController must be a contract");
        require(navCalculator.code.length > 0, "NAVCalculator must be a contract");
        REWARDS_CONTROLLER = IUmbrellaRewardsController(rewardsController);
        NAV_CALCULATOR = INAVCalculator(navCalculator);
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function protocolName() external pure returns (string memory) { return "Aave Umbrella"; }
    function describePosition(bytes calldata) external pure returns (string memory) { return "umbrella stake"; }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
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

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the **summed** balance for `asset` (staked + rewards) across every Umbrella
    ///         stake token whose bare reserve equals `asset`.
    function getOracleBalanceForAsset(address account, address asset)
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

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns deduplicated per-asset summed balances. Skips zero amounts.
    function getOracleBalances(address account)
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

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns one PositionBalance per `(stakeToken, leg)` pair where `leg ∈ {Staking, Rewards}`.
    /// @dev Each emitted position is self-describing through `positionDetail`. Zero-amount legs are
    ///      skipped. Stake tokens whose bare reserve is not registered on NAVCalculator are
    ///      silently skipped (same convention as `AaveV3InstanceBalanceOracle`).
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();
        address[] memory stakeTokens = REWARDS_CONTROLLER.getAllAssets();

        // Worst case: 2 positions per stake token (Staked + Rewards).
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](stakeTokens.length * 2);
        uint256 count;

        for (uint256 i; i < stakeTokens.length; ++i) {
            address stk = stakeTokens[i];
            address bare = _resolveBareReserve(stk);
            if (bare == address(0)) continue;
            if (!_passesFilter(bare, assetFilter)) continue;

            INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, bare);
            if (assetMeta.asset == address(0)) continue;

            // Staked-token leg.
            uint256 stakedAmount = _stakedUnderlying(stk, account);
            if (stakedAmount != 0) {
                tmp[count++] = INAVCalculator.PositionBalance({
                    balanceAsset: assetMeta,
                    balanceOracle: address(this),
                    amount: stakedAmount,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: abi.encode(address(stk)),
                    positionKind: PositionKind.Supplied
                });
            }

            // Rewards leg.
            uint256 rewardAmount = _claimableRewardInBareReserve(stk, account, bare);
            if (rewardAmount != 0) {
                tmp[count++] = INAVCalculator.PositionBalance({
                    balanceAsset: assetMeta,
                    balanceOracle: address(this),
                    amount: rewardAmount,
                    isDebt: false,
                    protocolId: PROTOCOL_ID,
                    positionId: abi.encode(address(stk)),
                    positionKind: PositionKind.Earned
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

    /// @dev Translate the user's stake-token shares into the bare reserve via at most one ERC4626
    ///      wrapper hop. Returns 0 when the user has no shares (skips the hops).
    function _stakedUnderlying(address stakeToken, address account) internal view returns (uint256) {
        uint256 amount = IUmbrellaStakeToken(stakeToken).balanceOf(account);
        if (amount == 0) return 0;
        amount = IUmbrellaStakeToken(stakeToken).convertToAssets(amount);

        // First-level asset: e.g. `stkwaEthUSDC.asset() = waEthUSDC`, or `stkGHO.asset() = GHO`.
        address firstLevel = _safeAsset(stakeToken);
        if (firstLevel == address(0)) return amount;

        // If the first-level asset is itself a real ERC4626 wrapper, walk one more hop to the bare
        // reserve. Otherwise `firstLevel` is already the bare reserve and `amount` is in its units.
        if (_isErc4626Wrapper(firstLevel)) {
            return IERC4626Like(firstLevel).convertToAssets(amount);
        }
        return amount;
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
    ///        - `asset()` succeeds and returns a non-zero contract.
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
        (bool ok, bytes memory ret) =
            rewardToken.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"));
        if (!ok || ret.length < 32) return rewardToken;
        address bare = abi.decode(ret, (address));
        return bare == address(0) ? rewardToken : bare;
    }

    /// @dev `IERC4626.asset()` via low-level staticcall with bounded gas. Returns address(0) when
    ///      the call reverts, returns no data, or returns less than a full word.
    function _safeAsset(address token) internal view returns (address) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("asset()"));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    //
    // Internal — array helpers
    //

    function _passesFilter(address asset, address assetFilter) internal pure returns (bool) {
        return assetFilter == address(0) || assetFilter == asset;
    }

    function _findRegisteredAsset(INAVCalculator.Asset[] memory registered, address asset)
        internal
        pure
        returns (INAVCalculator.Asset memory)
    {
        uint256 n = registered.length;
        for (uint256 i; i < n; ++i) {
            if (registered[i].asset == asset) return registered[i];
        }
        return INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0});
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
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Generic ERC4626-shaped reader used to walk wrapper layers without binding to a
///         particular implementation (StakeToken, StataTokenV2, or any future variant).
interface IERC4626Like {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
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
