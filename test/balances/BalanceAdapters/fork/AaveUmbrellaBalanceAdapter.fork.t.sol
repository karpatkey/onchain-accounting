// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {AaveUmbrellaBalanceAdapter} from "src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @dev Minimal subset of the Umbrella stake-token / RewardsController surface needed by this test
///      to compute expected values independently of the adapter under test.
interface IUmbrellaStakeTokenForkView {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function REWARDS_CONTROLLER() external view returns (address);
    function symbol() external view returns (string memory);
}

interface IStataTokenV2ForkView {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IUmbrellaRewardsControllerForkView {
    function getAllAssets() external view returns (address[] memory);
    function calculateCurrentUserRewards(address asset, address user)
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory amounts);
}

/// @title AaveUmbrellaBalanceAdapterForkTest
/// @notice Fork tests for the dynamic-discovery AaveUmbrellaBalanceAdapter against real Mainnet contracts.
/// @dev The adapter takes the RewardsController address (plus the NAVCalculator, used only for
///      asset-registry lookups) as constructor input and discovers the stake-token set + bare
///      reserves + reward-token-to-bare-reserve mapping at runtime. These
///      tests verify the discovery is correct against the live state at a pinned block, with real
///      holders chosen to have non-zero stake balances and non-zero accrued rewards on each stake
///      token.
contract AaveUmbrellaBalanceAdapterForkTest is BalanceAdapterTestBase {
    /// @notice Aave Umbrella RewardsController on Mainnet — the discovery trust anchor the adapter
    ///         under test is given. The adapter learns the stake-token set and everything
    ///         downstream from here; the bare reserves and holders pinned below are test-side
    ///         constants used only for independent verification.
    IUmbrellaRewardsControllerForkView public constant REWARDS_CONTROLLER =
        IUmbrellaRewardsControllerForkView(0x4655Ce3D625a63d30bA704087E52B4C31E38188B);

    // Bare reserves used by the adapter today. Pinned here so we can pre-register them with the
    // BalancesHarness and assert the adapter's positions land in the right asset.
    address public constant USDC = MAINNET_USDC;
    address public constant USDT = MAINNET_USDT;
    address public constant WETH = MAINNET_WETH;
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    /// @dev Recent Mainnet block at which the four currently-deployed Umbrella stake tokens are
    ///      active and each pinned holder has both a non-zero stake balance and non-zero accrued
    ///      rewards. Confirmed by direct RPC reads at planning time.
    uint256 public constant FORK_BLOCK = 25_287_877;

    AaveUmbrellaBalanceAdapter public adapter;

    // Real Mainnet holders, one per stake token (today's set). The WETH holder is also the legacy
    // SM stkAAVE / stkABPTv2 holder used in test/balances/BalanceAdapters/fork/AaveV3SafetyModuleBalanceAdapter.fork.t.sol.
    address public constant STK_WA_USDC_HOLDER = 0xd0002c648CCa8DeE2f2b8D70D542Ccde8ad6EC03;
    address public constant STK_WA_USDT_HOLDER = 0x7FE4b2632f5AE6d930677D662AF26Bc0a06672b3;
    address public constant STK_WA_WETH_HOLDER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant STK_GHO_HOLDER = 0x6Ca0D65fe5c8700a5cc7A2C3bfE801111A1dEd1a;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupAdapter();
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _setupAdapter() internal {
        address[] memory assets = new address[](4);
        assets[0] = USDC;
        assets[1] = USDT;
        assets[2] = WETH;
        assets[3] = GHO;
        balances = _deployBalancesForAdapter(assets);
        adapter = new AaveUmbrellaBalanceAdapter(address(REWARDS_CONTROLLER), address(balances));
    }

    // ─── Sanity ───────────────────────────────────────────────────────────────

    function test_holdersHaveNonZeroBalances() public view {
        address[] memory live = REWARDS_CONTROLLER.getAllAssets();
        // The order of getAllAssets is stable in practice but the test treats it as a set:
        address[] memory holders = _expectedHolderOrderForLiveSet(live);
        for (uint256 i; i < live.length; ++i) {
            assertGt(IUmbrellaStakeTokenForkView(live[i]).balanceOf(holders[i]), 0, "holder dropped its position");
        }
    }

    function test_underlyingAssetsSupported_dedupesToBareReserves() public view {
        address[] memory list = adapter.underlyingAssetsSupported();
        // Today's set resolves to four distinct bare reserves (USDC, USDT, WETH, GHO). If governance
        // adds a stake token whose bare reserve is already in the set the dedup keeps the count
        // at 4; if governance adds a brand-new reserve the count goes up. Either is acceptable —
        // we just assert the live set is a non-empty subset of the registered NAV assets, which we
        // can verify cleanly by checking each entry is one we pre-registered.
        assertGt(list.length, 0);
        for (uint256 i; i < list.length; ++i) {
            address a = list[i];
            assertTrue(
                a == USDC || a == USDT || a == WETH || a == GHO,
                "discovered bare reserve is not in the test asset registry - either Umbrella expanded into a new reserve, or the discovery walk regressed"
            );
        }
    }

    function test_stakeTokensShareSameRewardsController() public view {
        // The adapter assumes one controller covers every stake token returned by getAllAssets().
        // Assert that today.
        address[] memory live = REWARDS_CONTROLLER.getAllAssets();
        for (uint256 i; i < live.length; ++i) {
            assertEq(IUmbrellaStakeTokenForkView(live[i]).REWARDS_CONTROLLER(), address(REWARDS_CONTROLLER));
        }
    }

    // ─── Per-stake-token: balance math ────────────────────────────────────────

    function test_stkwaEthUSDC_balance_matchesAdapterDiscovery() public view {
        _assertHolderBalanceMatches(STK_WA_USDC_HOLDER, USDC, "stkwaEthUSDC.v1");
    }

    function test_stkwaEthUSDT_balance_matchesAdapterDiscovery() public view {
        _assertHolderBalanceMatches(STK_WA_USDT_HOLDER, USDT, "stkwaEthUSDT.v1");
    }

    function test_stkwaEthWETH_balance_matchesAdapterDiscovery() public view {
        _assertHolderBalanceMatches(STK_WA_WETH_HOLDER, WETH, "stkwaEthWETH.v1");
    }

    function test_stkGHO_balance_matchesAdapterDiscovery() public view {
        _assertHolderBalanceMatches(STK_GHO_HOLDER, GHO, "stkGHO.v1");
    }

    // ─── Position attribution and labels ──────────────────────────────────────

    function test_getAdapterPositions_emitsStakedAndRewardsLegsForUSDCHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(STK_WA_USDC_HOLDER, address(0));

        bool sawStaked;
        bool sawRewards;
        for (uint256 i; i < positions.length; ++i) {
            assertGt(positions[i].amount, 0);
            assertEq(positions[i].balanceAdapter, address(adapter));
            assertFalse(positions[i].isDebt);

            if (positions[i].balanceAsset.asset == USDC) {
                if (positions[i].positionKind == PositionKind.Staking) sawStaked = true;
                if (positions[i].positionKind == PositionKind.Rewards) sawRewards = true;
            }
        }
        assertTrue(sawStaked, "missing USDC/stkwaEthUSDC.v1 Staking position");
        assertTrue(sawRewards, "missing USDC/stkwaEthUSDC.v1 Rewards position");
    }

    function test_getAdapterPositions_emitsStakedAndRewardsLegsForGHOHolder() public view {
        // stkGHO.v1 staked and rewards are BOTH in GHO, so the holder sees two GHO entries with
        // distinct positionKind values (Staking vs Rewards) — exactly the disambiguation the
        // framework needs.
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(STK_GHO_HOLDER, address(0));

        bool sawStaked;
        bool sawRewards;
        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].balanceAsset.asset != GHO) continue;
            if (positions[i].positionKind == PositionKind.Staking) sawStaked = true;
            if (positions[i].positionKind == PositionKind.Rewards) sawRewards = true;
        }
        assertTrue(sawStaked, "missing GHO/stkGHO.v1 Staking position");
        assertTrue(sawRewards, "missing GHO/stkGHO.v1 Rewards position");
    }

    function test_getAdapterPositions_assetFilter_onlyEmitsMatchingAsset() public view {
        // GHO holder filtered to GHO — should emit both legs (Staked + Rewards).
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(STK_GHO_HOLDER, GHO);
        assertEq(positions.length, 2);
        for (uint256 i; i < positions.length; ++i) {
            assertEq(positions[i].balanceAsset.asset, GHO);
        }
    }

    function test_getAdapterPositions_assetFilter_excludesUnrelatedHolderPositions() public view {
        // GHO holder doesn't hold any wa-stake; filter to USDC should yield nothing.
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(STK_GHO_HOLDER, USDC);
        assertEq(positions.length, 0);
    }

    // ─── getAdapterBalances aggregation ────────────────────────────────────────

    function test_getAdapterBalances_returnsOneEntryPerNonZeroUnderlying() public view {
        (address[] memory assetsArr, uint256[] memory amountsArr, bool[] memory isDebtArr) =
            adapter.getAdapterBalances(STK_WA_USDC_HOLDER);
        assertEq(assetsArr.length, 1, "USDC holder should report exactly one underlying");
        assertEq(assetsArr[0], USDC);
        assertGt(amountsArr[0], 0);
        assertFalse(isDebtArr[0]);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Compute the expected (staked + rewards-mapped-to-bare-reserve) total for a holder by
    ///      walking the same path as the adapter, then assert the adapter's discovered stake-token
    ///      symbol matches `expectedSymbol` and that getAdapterBalanceForAsset returns that total.
    function _assertHolderBalanceMatches(address holder, address bareReserve, string memory expectedSymbol)
        internal
        view
    {
        // Locate this holder's stake token by scanning getAllAssets for the one whose resolved
        // bare reserve equals `bareReserve` AND where `holder` has a non-zero balance.
        address[] memory live = REWARDS_CONTROLLER.getAllAssets();
        address stakeToken;
        for (uint256 i; i < live.length; ++i) {
            if (_resolveBareReserve(live[i]) != bareReserve) continue;
            if (IUmbrellaStakeTokenForkView(live[i]).balanceOf(holder) == 0) continue;
            stakeToken = live[i];
            break;
        }
        require(stakeToken != address(0), "no live stake token matches expected bare reserve for holder");

        // Sanity: discovered symbol matches the test's expectation.
        assertEq(IUmbrellaStakeTokenForkView(stakeToken).symbol(), expectedSymbol);

        // Independently compute staked underlying via two-hop ERC4626 walk where applicable.
        uint256 expectedStaked = _expectedStakedUnderlying(stakeToken, holder);
        uint256 expectedRewards = _expectedRewardsInBareReserve(stakeToken, holder, bareReserve);

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(holder, bareReserve);
        assertEq(amount, expectedStaked + expectedRewards, "adapter sum diverges from independent computation");
        assertGt(amount, 0);
        assertFalse(isDebt);
    }

    function _expectedStakedUnderlying(address stakeToken, address holder) internal view returns (uint256) {
        uint256 amount = IUmbrellaStakeTokenForkView(stakeToken).balanceOf(holder);
        if (amount == 0) return 0;
        amount = IUmbrellaStakeTokenForkView(stakeToken).convertToAssets(amount);
        address inner = IUmbrellaStakeTokenForkView(stakeToken).asset();
        // If `inner` is itself an ERC4626 wrapper, do one more hop. Otherwise we're at the bare reserve.
        if (_safeAsset(inner) != address(0)) {
            amount = IStataTokenV2ForkView(inner).convertToAssets(amount);
        }
        return amount;
    }

    function _expectedRewardsInBareReserve(address stakeToken, address holder, address bareReserve)
        internal
        view
        returns (uint256 total)
    {
        (address[] memory tokens, uint256[] memory amounts) =
            REWARDS_CONTROLLER.calculateCurrentUserRewards(stakeToken, holder);
        for (uint256 i; i < tokens.length; ++i) {
            address bare = _resolveRewardBareReserve(tokens[i]);
            if (bare == bareReserve) total += amounts[i];
        }
    }

    function _resolveBareReserve(address stakeToken) internal view returns (address) {
        address inner = IUmbrellaStakeTokenForkView(stakeToken).asset();
        address deeper = _safeAsset(inner);
        return deeper == address(0) ? inner : deeper;
    }

    function _resolveRewardBareReserve(address rewardToken) internal view returns (address) {
        // Try aToken's UNDERLYING_ASSET_ADDRESS(); fallback to the reward token itself.
        (bool ok, bytes memory data) = rewardToken.staticcall(abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"));
        if (!ok || data.length < 32) return rewardToken;
        address bare = abi.decode(data, (address));
        return bare == address(0) ? rewardToken : bare;
    }

    function _safeAsset(address token) internal view returns (address) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("asset()"));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    /// @dev Map each entry of the live `getAllAssets` set to a known holder address, by symbol.
    ///      Fails if the live set introduces a symbol this test doesn't know about — prompting a
    ///      deliberate update.
    function _expectedHolderOrderForLiveSet(address[] memory live) internal view returns (address[] memory holders) {
        holders = new address[](live.length);
        for (uint256 i; i < live.length; ++i) {
            string memory sym = IUmbrellaStakeTokenForkView(live[i]).symbol();
            if (_eq(sym, "stkwaEthUSDC.v1")) holders[i] = STK_WA_USDC_HOLDER;
            else if (_eq(sym, "stkwaEthUSDT.v1")) holders[i] = STK_WA_USDT_HOLDER;
            else if (_eq(sym, "stkwaEthWETH.v1")) holders[i] = STK_WA_WETH_HOLDER;
            else if (_eq(sym, "stkGHO.v1")) holders[i] = STK_GHO_HOLDER;
            else revert(string.concat("no test holder for new Umbrella stake token: ", sym));
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
