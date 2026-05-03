// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Aave Umbrella Balance Oracle (multi-token, hardcoded)
/// @author kpk
/// @notice Reports balances across every Aave Umbrella stake token deployed on Mainnet, currently:
///         `stkwaEthUSDC.v1`, `stkwaEthUSDT.v1`, `stkwaEthWETH.v1`, and `stkGHO.v1`. For each stake
///         position we emit two `PositionBalance` entries — one labeled `<symbol> Staked` for the
///         user's principal (denominated in the bare reserve token: USDC / USDT / WETH / GHO), and
///         one labeled `<symbol> Rewards` for the user's claimable but unclaimed rewards (also in
///         the bare reserve token, since rewards are paid in the matching aToken which is value-
///         equivalent to the bare reserve unit-for-unit).
/// @dev Mainnet only. Umbrella is deployed only on Ethereum Mainnet today; the Aave V3 reserves it
///      covers (USDC / USDT / WETH on the Core market, plus GHO) are Mainnet-specific. Deploying
///      this adapter on another chain is meaningless: the constants would resolve to EOAs and
///      revert at the first `IUmbrellaStakeToken.balanceOf` call.
///
///      The Umbrella `RewardsController` does expose `getAllAssets()` for on-chain enumeration of
///      stake tokens, but ADR 0006 chooses to hardcode the four entries in source for the same
///      reasons ADR 0005 chose hardcoding for the legacy Safety Module: every wiring decision is
///      caught at code-review time, the adapter remains immutable and write-function-free, and a
///      new stake token is a redeploy event regardless. See `docs/decisions/0006-aave-umbrella-balance-oracle.md`.
///
///      Two-hop ERC4626 conversion: for the three `stkwaEth*` stake tokens the underlying asset is
///      a `waEth*` static-aToken wrapper, not the bare reserve. The adapter performs
///      `stk.convertToAssets(stk.balanceOf(user))` followed by `wa.convertToAssets(...)` to land on
///      the bare reserve. For `stkGHO.v1` the underlying is plain GHO and a single hop suffices.
///
///      Slashing-correctness: Umbrella stake tokens reduce `totalAssets` while keeping `totalSupply`
///      constant when slashing fires, so `convertToAssets(shares)` automatically reflects post-slash
///      values without any extra accounting.
contract AaveUmbrellaBalanceOracle is IBalanceOracleAdapter {
    //
    // Constants — bare reserve tokens
    //

    /// @notice USDC reserve token (Mainnet).
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice USDT reserve token (Mainnet).
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @notice WETH reserve token (Mainnet).
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice GHO stablecoin (Mainnet).
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    //
    // Constants — Umbrella stake tokens (Mainnet)
    //

    /// @notice stkwaEthUSDC.v1 — Umbrella stake token over `waEthUSDC` (StataTokenV2 wrapping aEthUSDC).
    address public constant STK_WA_USDC = 0x6bf183243FdD1e306ad2C4450BC7dcf6f0bf8Aa6;

    /// @notice stkwaEthUSDT.v1 — Umbrella stake token over `waEthUSDT`.
    address public constant STK_WA_USDT = 0xA484Ab92fe32B143AEE7019fC1502b1dAA522D31;

    /// @notice stkwaEthWETH.v1 — Umbrella stake token over `waEthWETH`.
    address public constant STK_WA_WETH = 0xaAFD07D53A7365D3e9fb6F3a3B09EC19676B73Ce;

    /// @notice stkGHO.v1 — Umbrella stake token over plain GHO (no aToken wrapper layer).
    address public constant STK_GHO = 0x4f827A63755855cDf3e8f3bcD20265C833f15033;

    //
    // Constants — waToken intermediate wrappers (StataTokenV2, ERC4626 over aTokens)
    //

    /// @notice waEthUSDC — `STK_WA_USDC.asset()`. ERC4626 wrapper over aEthUSDC.
    address public constant WA_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

    /// @notice waEthUSDT — `STK_WA_USDT.asset()`. ERC4626 wrapper over aEthUSDT.
    address public constant WA_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    /// @notice waEthWETH — `STK_WA_WETH.asset()`. ERC4626 wrapper over aEthWETH.
    address public constant WA_WETH = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;

    //
    // Constants — reward tokens (returned by RewardsController.calculateCurrentUserRewards)
    //
    // For the `stkwaEth*` stake tokens the reward is the corresponding aToken; aTokens are 1:1
    // value-equivalent with the bare reserve, so the emitted reward amount can be reported in the
    // bare reserve unit-for-unit. For `stkGHO.v1` the reward token is plain GHO.

    /// @notice aEthUSDC — reward token of stkwaEthUSDC.v1.
    address public constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    /// @notice aEthUSDT — reward token of stkwaEthUSDT.v1.
    address public constant A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    /// @notice aEthWETH — reward token of stkwaEthWETH.v1.
    address public constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    //
    // Constants — Umbrella infrastructure
    //

    /// @notice Aave Umbrella RewardsController (Mainnet, transparent proxy).
    /// @dev Shared by all four stake tokens today (each stake token's `REWARDS_CONTROLLER()` resolves
    ///      to this address). Pinned at compile time so a future stake-token whose controller diverges
    ///      forces a deliberate code change rather than silently skewing rewards accounting.
    address public constant REWARDS_CONTROLLER = 0x4655Ce3D625a63d30bA704087E52B4C31E38188B;

    //
    // Type Definitions
    //

    /// @dev One row of the hardcoded Umbrella stake-token table.
    /// @param stakeToken         Umbrella stake-token address (the ERC4626 vault users hold shares of).
    /// @param waToken            ERC4626 wrapper between stake-token-asset and bare reserve. `address(0)`
    ///                           means there is no second hop (stkGHO.v1's case — `asset()` is GHO directly).
    /// @param underlying         Bare reserve token to report both legs in (USDC, USDT, WETH, or GHO).
    /// @param rewardToken        Reward token returned by `RewardsController.calculateCurrentUserRewards`.
    ///                           Used to filter the returned tuple — only matches against this token are
    ///                           emitted; if Aave governance configures additional reward tokens for a
    ///                           stake token in the future, this adapter is a code-change-and-redeploy.
    /// @param positionDetailBase Position-detail prefix; emitted entries get suffixed `" Staked"` /
    ///                           `" Rewards"` to disambiguate the two legs.
    struct StakeRecord {
        address stakeToken;
        address waToken;
        address underlying;
        address rewardToken;
        string positionDetailBase;
    }

    //
    // State
    //

    /// @notice Reference to NAVCalculator for asset registry lookups.
    INAVCalculator public immutable NAV_CALCULATOR;

    /// @notice Protocol identifier emitted on every PositionBalance (e.g. "Aave Umbrella").
    string public PROTOCOL;

    //
    // Constructor
    //

    /// @param navCalculator The NAVCalculator address (used to look up registered assets when emitting positions).
    /// @param protocol_ Protocol identifier emitted on every PositionBalance (e.g. "Aave Umbrella").
    constructor(address navCalculator, string memory protocol_) {
        if (navCalculator == address(0)) revert InvalidArguments();
        require(navCalculator.code.length > 0, "NAVCalculator must be a contract");
        NAV_CALCULATOR = INAVCalculator(navCalculator);
        PROTOCOL = protocol_;
    }

    //
    // Internal — stake token table
    //

    /// @dev The full hardcoded list of Umbrella stake tokens. `pure` — no storage reads, baked into bytecode.
    function _records() internal pure returns (StakeRecord[4] memory recs) {
        recs[0] = StakeRecord({
            stakeToken: STK_WA_USDC,
            waToken: WA_USDC,
            underlying: USDC,
            rewardToken: A_USDC,
            positionDetailBase: "stkwaEthUSDC.v1"
        });
        recs[1] = StakeRecord({
            stakeToken: STK_WA_USDT,
            waToken: WA_USDT,
            underlying: USDT,
            rewardToken: A_USDT,
            positionDetailBase: "stkwaEthUSDT.v1"
        });
        recs[2] = StakeRecord({
            stakeToken: STK_WA_WETH,
            waToken: WA_WETH,
            underlying: WETH,
            rewardToken: A_WETH,
            positionDetailBase: "stkwaEthWETH.v1"
        });
        recs[3] = StakeRecord({
            stakeToken: STK_GHO, waToken: address(0), underlying: GHO, rewardToken: GHO, positionDetailBase: "stkGHO.v1"
        });
    }

    //
    // IERC165
    //

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //
    // IBalanceOracleAdapter
    //

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the four bare reserve tokens this adapter reports — USDC, USDT, WETH, GHO.
    /// @dev The reward legs land in the same bare reserves (aTokens map 1:1 to their underlying for
    ///      value purposes), so the supported set equals the staked-side underlyings.
    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        address[] memory out = new address[](4);
        out[0] = USDC;
        out[1] = USDT;
        out[2] = WETH;
        out[3] = GHO;
        return out;
    }

    /// @inheritdoc IBalanceOracleAdapter
    /// @notice Returns the **summed** balance for `asset` (staked + rewards) across every Umbrella stake token
    ///         whose `underlying == asset`.
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (account == address(0) || asset == address(0)) return (0, false);
        return (_summedBalance(account, asset), false);
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

        address[] memory supported = new address[](4);
        supported[0] = USDC;
        supported[1] = USDT;
        supported[2] = WETH;
        supported[3] = GHO;

        address[] memory tmpAssets = new address[](4);
        uint256[] memory tmpAmounts = new uint256[](4);
        uint256 count;

        for (uint256 i; i < 4; ++i) {
            uint256 bal = _summedBalance(account, supported[i]);
            if (bal != 0) {
                tmpAssets[count] = supported[i];
                tmpAmounts[count] = bal;
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
    /// @notice Returns one PositionBalance per `(stakeToken, leg)` pair where `leg ∈ {Staked, Rewards}`.
    /// @dev Each emitted position is self-describing through `positionDetail`. Zero-amount legs are skipped.
    ///      A holder of stkGHO.v1 with both staked and rewards balances will see two entries with the same
    ///      `underlyingAsset = GHO` but distinct `positionDetail` values (`"stkGHO.v1 Staked"` and
    ///      `"stkGHO.v1 Rewards"`).
    function getOraclePositions(address account, address assetFilter)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory positions)
    {
        if (account == address(0)) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.Asset[] memory registered = NAV_CALCULATOR.getRegisteredAssets();

        StakeRecord[4] memory recs = _records();
        // Worst case: 2 positions per stake token (staked + rewards).
        INAVCalculator.PositionBalance[] memory tmp = new INAVCalculator.PositionBalance[](recs.length * 2);
        uint256 count;

        for (uint256 i; i < recs.length; ++i) {
            StakeRecord memory r = recs[i];

            // Staked-token leg.
            if (_passesFilter(r.underlying, assetFilter)) {
                INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, r.underlying);
                if (assetMeta.asset != address(0)) {
                    uint256 stakedAmount = _stakedUnderlying(r, account);
                    if (stakedAmount != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            underlyingAsset: assetMeta,
                            balanceOracle: address(this),
                            amount: stakedAmount,
                            isDebt: false,
                            protocol: PROTOCOL,
                            positionDetail: string.concat(r.positionDetailBase, " Staked")
                        });
                    }
                }
            }

            // Rewards leg. The `underlying` and `rewardToken` are mapped to the SAME bare reserve
            // (aTokens are 1:1 with their underlying for value), so the position is emitted in
            // `r.underlying`. We pass `r.underlying` to the filter check for that reason.
            if (_passesFilter(r.underlying, assetFilter)) {
                INAVCalculator.Asset memory assetMeta = _findRegisteredAsset(registered, r.underlying);
                if (assetMeta.asset != address(0)) {
                    uint256 rewardAmount = _claimableRewardForToken(r.stakeToken, account, r.rewardToken);
                    if (rewardAmount != 0) {
                        tmp[count++] = INAVCalculator.PositionBalance({
                            underlyingAsset: assetMeta,
                            balanceOracle: address(this),
                            amount: rewardAmount,
                            isDebt: false,
                            protocol: PROTOCOL,
                            positionDetail: string.concat(r.positionDetailBase, " Rewards")
                        });
                    }
                }
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

    /// @dev Sum of staked + rewards for a given bare reserve `asset` across the hardcoded stake-token set.
    function _summedBalance(address account, address asset) internal view returns (uint256 total) {
        StakeRecord[4] memory recs = _records();
        for (uint256 i; i < recs.length; ++i) {
            StakeRecord memory r = recs[i];
            if (r.underlying != asset) continue;
            total += _stakedUnderlying(r, account);
            total += _claimableRewardForToken(r.stakeToken, account, r.rewardToken);
        }
    }

    /// @dev Translate a user's stake-token shares into the bare reserve via at most two ERC4626 hops.
    ///      Returns 0 when the user has no shares to skip the second-hop call.
    function _stakedUnderlying(StakeRecord memory r, address account) internal view returns (uint256) {
        uint256 shares = IUmbrellaStakeToken(r.stakeToken).balanceOf(account);
        if (shares == 0) return 0;
        uint256 hopOne = IUmbrellaStakeToken(r.stakeToken).convertToAssets(shares);
        if (r.waToken == address(0)) return hopOne;
        return IStataTokenV2(r.waToken).convertToAssets(hopOne);
    }

    /// @dev Pull `(rewardTokens[], amounts[])` for one stake token and return the amount matching `wantedToken`.
    ///      Reward tokens not in the hardcoded mapping are silently dropped — adding a new reward token requires
    ///      a code change to extend the mapping (per ADR 0006).
    function _claimableRewardForToken(address stakeToken, address user, address wantedToken)
        internal
        view
        returns (uint256)
    {
        (address[] memory tokens, uint256[] memory amounts) =
            IUmbrellaRewardsController(REWARDS_CONTROLLER).calculateCurrentUserRewards(stakeToken, user);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == wantedToken) return amounts[i];
        }
        return 0;
    }

    //
    // Internal — helpers
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
}

/// @notice Minimal interface for an Aave Umbrella stake token (an ERC4626 vault with slashing semantics).
/// @dev Reference impl: https://github.com/aave-dao/aave-umbrella/blob/main/src/contracts/stakeToken/StakeToken.sol
///      Only the read functions needed by this adapter are declared.
interface IUmbrellaStakeToken {
    /// @notice ERC20 share balance of the stake token (in vault-share units).
    function balanceOf(address account) external view returns (uint256);

    /// @notice ERC4626 view: convert stake-token shares into underlying-asset amount (post-slash-correct).
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice ERC4626 view: address of the underlying asset (waToken for waEth* stake tokens, GHO for stkGHO.v1).
    function asset() external view returns (address);

    /// @notice Address of the RewardsController paying rewards on this stake token.
    // solhint-disable-next-line func-name-mixedcase
    function REWARDS_CONTROLLER() external view returns (address);
}

/// @notice Minimal interface for the Aave V3 StataTokenV2 wrapper (`waEthUSDC`, `waEthUSDT`, `waEthWETH`).
/// @dev StataTokenV2 wraps an aToken into a static-balance ERC4626. The adapter only needs `convertToAssets`
///      to translate waToken amount into the bare reserve token amount.
interface IStataTokenV2 {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Minimal interface for the Aave Umbrella RewardsController (multi-reward distributor).
/// @dev Reference impl: https://github.com/aave-dao/aave-umbrella/tree/main/src/contracts/rewards
interface IUmbrellaRewardsController {
    /// @notice Claimable reward amounts for a user on a given stake token, broken down by reward token.
    /// @param asset Stake-token address (`getAllAssets()` enumerates all assets the controller tracks).
    /// @param user Address whose claimable rewards to query.
    /// @return rewardTokens Reward token addresses configured for `asset`.
    /// @return amounts Corresponding claimable but unclaimed amounts (in reward-token units).
    function calculateCurrentUserRewards(address asset, address user)
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory amounts);
}
