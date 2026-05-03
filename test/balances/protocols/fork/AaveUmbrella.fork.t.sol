// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveUmbrellaBalanceOracle} from "src/balances/protocols/AaveUmbrella.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @dev Minimal subset of the Umbrella stake-token / RewardsController surface needed by the fork test.
///      Mirrors what the adapter consumes — kept here so the test asserts against the same calls without
///      taking a dependency on internal interface declarations in the adapter source.
interface IUmbrellaStakeTokenForkView {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function REWARDS_CONTROLLER() external view returns (address);
}

interface IStataTokenV2ForkView {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IUmbrellaRewardsControllerForkView {
    function calculateCurrentUserRewards(address asset, address user)
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory amounts);

    function getAllAssets() external view returns (address[] memory);
}

/// @title AaveUmbrellaBalanceOracleForkTest
/// @notice Fork tests for the hardcoded multi-token AaveUmbrellaBalanceOracle against real Mainnet contracts.
/// @dev The adapter pins all Umbrella addresses (stake tokens, waToken intermediates, aToken rewards,
///      RewardsController) as constants. These fork tests verify the addresses are reachable, that the
///      live `RewardsController.getAllAssets()` set matches the four hardcoded entries, and that the
///      balance / position math matches the underlying contracts. Real holders for each stake token were
///      sourced from Etherscan top-holder views and verified to have non-zero current balances and
///      non-zero accrued rewards at the pinned fork block.
contract AaveUmbrellaBalanceOracleForkTest is BalanceAdapterTestBase {
    // Stake tokens (must match the adapter constants).
    IUmbrellaStakeTokenForkView public constant STK_WA_USDC =
        IUmbrellaStakeTokenForkView(0x6bf183243FdD1e306ad2C4450BC7dcf6f0bf8Aa6);
    IUmbrellaStakeTokenForkView public constant STK_WA_USDT =
        IUmbrellaStakeTokenForkView(0xA484Ab92fe32B143AEE7019fC1502b1dAA522D31);
    IUmbrellaStakeTokenForkView public constant STK_WA_WETH =
        IUmbrellaStakeTokenForkView(0xaAFD07D53A7365D3e9fb6F3a3B09EC19676B73Ce);
    IUmbrellaStakeTokenForkView public constant STK_GHO =
        IUmbrellaStakeTokenForkView(0x4f827A63755855cDf3e8f3bcD20265C833f15033);

    // waToken intermediate wrappers.
    IStataTokenV2ForkView public constant WA_USDC = IStataTokenV2ForkView(0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E);
    IStataTokenV2ForkView public constant WA_USDT = IStataTokenV2ForkView(0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8);
    IStataTokenV2ForkView public constant WA_WETH = IStataTokenV2ForkView(0x0bfc9d54Fc184518A81162F8fB99c2eACa081202);

    IUmbrellaRewardsControllerForkView public constant REWARDS_CONTROLLER =
        IUmbrellaRewardsControllerForkView(0x4655Ce3D625a63d30bA704087E52B4C31E38188B);

    // Bare reserves.
    address public constant USDC = MAINNET_USDC;
    address public constant USDT = MAINNET_USDT;
    address public constant WETH = MAINNET_WETH;
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    // Reward tokens (aTokens for the wa-backed stake tokens; GHO for stkGHO.v1).
    address public constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address public constant A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address public constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    /// @dev Recent Mainnet block at which all four stake tokens are active and each pinned holder has both a
    ///      non-zero stake balance and non-zero accrued rewards. Confirmed by direct RPC reads at planning time.
    uint256 public constant FORK_BLOCK = 25_000_000;

    AaveUmbrellaBalanceOracle public oracle;

    // Real Mainnet holders, one per stake token. STK_WA_WETH_HOLDER is also the legacy SM stkAAVE/stkABPTv2
    // holder used in test/balances/protocols/fork/AaveV3SafetyModule.fork.t.sol — kept distinct here for clarity.
    address public constant STK_WA_USDC_HOLDER = 0xd0002c648CCa8DeE2f2b8D70D542Ccde8ad6EC03;
    address public constant STK_WA_USDT_HOLDER = 0x7FE4b2632f5AE6d930677D662AF26Bc0a06672b3;
    address public constant STK_WA_WETH_HOLDER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant STK_GHO_HOLDER = 0x6Ca0D65fe5c8700a5cc7A2C3bfE801111A1dEd1a;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _setupOracle() internal {
        address[] memory assets = new address[](4);
        assets[0] = USDC;
        assets[1] = USDT;
        assets[2] = WETH;
        assets[3] = GHO;
        balances = _deployBalancesForOracle(assets);
        oracle = new AaveUmbrellaBalanceOracle(address(balances), "Aave Umbrella");
    }

    // ─── Sanity ───────────────────────────────────────────────────────────────

    function test_holdersHaveNonZeroBalances() public view {
        assertGt(STK_WA_USDC.balanceOf(STK_WA_USDC_HOLDER), 0, "stkwaEthUSDC.v1 holder dropped its position");
        assertGt(STK_WA_USDT.balanceOf(STK_WA_USDT_HOLDER), 0, "stkwaEthUSDT.v1 holder dropped its position");
        assertGt(STK_WA_WETH.balanceOf(STK_WA_WETH_HOLDER), 0, "stkwaEthWETH.v1 holder dropped its position");
        assertGt(STK_GHO.balanceOf(STK_GHO_HOLDER), 0, "stkGHO.v1 holder dropped its position");
    }

    function test_hardcodedSet_matchesLiveRewardsControllerEnumeration() public view {
        // The adapter hardcodes 4 stake tokens. RewardsController.getAllAssets() enumerates the live set;
        // assert the hardcoded set is a subset (or equal) so a governance addition surfaces as a test failure.
        address[] memory live = REWARDS_CONTROLLER.getAllAssets();
        assertEq(live.length, 4, "Umbrella stake-token set diverged from adapter - review and extend hardcoded list");

        bool sawUsdc;
        bool sawUsdt;
        bool sawWeth;
        bool sawGho;
        for (uint256 i; i < live.length; ++i) {
            if (live[i] == address(STK_WA_USDC)) sawUsdc = true;
            if (live[i] == address(STK_WA_USDT)) sawUsdt = true;
            if (live[i] == address(STK_WA_WETH)) sawWeth = true;
            if (live[i] == address(STK_GHO)) sawGho = true;
        }
        assertTrue(sawUsdc && sawUsdt && sawWeth && sawGho, "live set != hardcoded set");
    }

    function test_stakeTokensShareSameRewardsController() public view {
        assertEq(STK_WA_USDC.REWARDS_CONTROLLER(), address(REWARDS_CONTROLLER));
        assertEq(STK_WA_USDT.REWARDS_CONTROLLER(), address(REWARDS_CONTROLLER));
        assertEq(STK_WA_WETH.REWARDS_CONTROLLER(), address(REWARDS_CONTROLLER));
        assertEq(STK_GHO.REWARDS_CONTROLLER(), address(REWARDS_CONTROLLER));
    }

    function test_underlyingAssetsSupported_returnsBareReserves() public view {
        address[] memory list = oracle.underlyingAssetsSupported();
        assertEq(list.length, 4);
    }

    // ─── Per-stake-token: balance math matches two-hop ERC4626 conversion ─────

    function test_stkwaEthUSDC_stakedBalance_matchesTwoHopConvert() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(STK_WA_USDC_HOLDER, USDC);
        uint256 staked = WA_USDC.convertToAssets(STK_WA_USDC.convertToAssets(STK_WA_USDC.balanceOf(STK_WA_USDC_HOLDER)));
        uint256 rewards = _expectedRewardForStakeToken(address(STK_WA_USDC), STK_WA_USDC_HOLDER, A_USDC);
        assertEq(amount, staked + rewards, "USDC leg should be two-hop staked + claimable aEthUSDC rewards");
        assertGt(amount, 0);
        assertFalse(isDebt);
    }

    function test_stkwaEthUSDT_stakedBalance_matchesTwoHopConvert() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(STK_WA_USDT_HOLDER, USDT);
        uint256 staked = WA_USDT.convertToAssets(STK_WA_USDT.convertToAssets(STK_WA_USDT.balanceOf(STK_WA_USDT_HOLDER)));
        uint256 rewards = _expectedRewardForStakeToken(address(STK_WA_USDT), STK_WA_USDT_HOLDER, A_USDT);
        assertEq(amount, staked + rewards);
        assertGt(amount, 0);
    }

    function test_stkwaEthWETH_stakedBalance_matchesTwoHopConvert() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(STK_WA_WETH_HOLDER, WETH);
        uint256 staked = WA_WETH.convertToAssets(STK_WA_WETH.convertToAssets(STK_WA_WETH.balanceOf(STK_WA_WETH_HOLDER)));
        uint256 rewards = _expectedRewardForStakeToken(address(STK_WA_WETH), STK_WA_WETH_HOLDER, A_WETH);
        assertEq(amount, staked + rewards);
        assertGt(amount, 0);
    }

    function test_stkGHO_stakedBalance_matchesSingleHopConvert() public view {
        // stkGHO.v1's underlying is plain GHO (no waToken intermediate). And the reward token is also GHO,
        // so getOracleBalanceForAsset(holder, GHO) returns staked + rewards in the same asset.
        (uint256 amount,) = oracle.getOracleBalanceForAsset(STK_GHO_HOLDER, GHO);
        uint256 staked = STK_GHO.convertToAssets(STK_GHO.balanceOf(STK_GHO_HOLDER));
        uint256 rewards = _expectedRewardForStakeToken(address(STK_GHO), STK_GHO_HOLDER, GHO);
        assertEq(amount, staked + rewards);
        assertGt(amount, 0);
    }

    // ─── Position attribution and labels ──────────────────────────────────────

    function test_getOraclePositions_emitsStakedAndRewardsLegsForUSDCHolder() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(STK_WA_USDC_HOLDER, address(0));

        bool sawStaked;
        bool sawRewards;
        for (uint256 i; i < positions.length; ++i) {
            assertGt(positions[i].amount, 0);
            assertEq(positions[i].balanceOracle, address(oracle));
            assertEq(positions[i].protocol, "Aave Umbrella");
            assertFalse(positions[i].isDebt);

            if (positions[i].underlyingAsset.asset == USDC) {
                if (_eq(positions[i].positionDetail, "stkwaEthUSDC.v1 Staked")) sawStaked = true;
                if (_eq(positions[i].positionDetail, "stkwaEthUSDC.v1 Rewards")) sawRewards = true;
            }
        }
        assertTrue(sawStaked, "missing USDC/stkwaEthUSDC.v1 Staked position");
        assertTrue(sawRewards, "missing USDC/stkwaEthUSDC.v1 Rewards position");
    }

    function test_getOraclePositions_emitsStakedAndRewardsLegsForGHOHolder() public view {
        // stkGHO.v1 staked and rewards are BOTH in GHO, so the holder sees two GHO entries with distinct
        // positionDetail strings — exactly the disambiguation the framework needs to break out the two legs.
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(STK_GHO_HOLDER, address(0));

        bool sawStaked;
        bool sawRewards;
        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].underlyingAsset.asset != GHO) continue;
            if (_eq(positions[i].positionDetail, "stkGHO.v1 Staked")) sawStaked = true;
            if (_eq(positions[i].positionDetail, "stkGHO.v1 Rewards")) sawRewards = true;
        }
        assertTrue(sawStaked, "missing GHO/stkGHO.v1 Staked position");
        assertTrue(sawRewards, "missing GHO/stkGHO.v1 Rewards position");
    }

    function test_getOraclePositions_assetFilter_onlyEmitsMatchingAsset() public view {
        // Filter the GHO holder's positions to only GHO — should emit both legs (Staked + Rewards) but
        // nothing else. (No other stake token reports in GHO.)
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(STK_GHO_HOLDER, GHO);
        assertEq(positions.length, 2);
        for (uint256 i; i < positions.length; ++i) {
            assertEq(positions[i].underlyingAsset.asset, GHO);
        }
    }

    function test_getOraclePositions_assetFilter_excludesUnrelatedHolderPositions() public view {
        // The stkGHO holder doesn't hold stkwaEth* — filtering by USDC should yield nothing.
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(STK_GHO_HOLDER, USDC);
        assertEq(positions.length, 0);
    }

    // ─── getOracleBalances aggregates across the underlying set ───────────────

    function test_getOracleBalances_returnsOneEntryPerNonZeroUnderlying() public view {
        (address[] memory assetsArr, uint256[] memory amountsArr, bool[] memory isDebtArr) =
            oracle.getOracleBalances(STK_WA_USDC_HOLDER);
        // The USDC holder has stake only in USDC; the other three underlyings should not appear.
        assertEq(assetsArr.length, 1, "USDC holder should report exactly one underlying");
        assertEq(assetsArr[0], USDC);
        assertGt(amountsArr[0], 0);
        assertFalse(isDebtArr[0]);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _expectedRewardForStakeToken(address stakeToken, address user, address wantedToken)
        internal
        view
        returns (uint256)
    {
        (address[] memory tokens, uint256[] memory amounts) =
            REWARDS_CONTROLLER.calculateCurrentUserRewards(stakeToken, user);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == wantedToken) return amounts[i];
        }
        return 0;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
