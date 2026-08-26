// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {CapStablecoinBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapStablecoinBalanceAdapter.sol";
import {CapSavingsBalanceAdapter} from "src/balances/BalanceAdapters/cap/CapSavingsBalanceAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title Cap leg-adapter fork tests
/// @notice Both Cap leg adapters against the real Cap Finance contracts on Ethereum mainnet, at the same block and
///         against the same holder the pre-split `CapBalanceAdapter.fork.t.sol` used.
/// @dev One file and one fork for the pair, like `BalancerMeta.fork.t.sol` / `CurveMeta.fork.t.sol`: the interesting
///      assertion is a CROSS-LEG one (the two legs still sum to the pre-split total against live burn quotes), and
///      splitting it across two forks would double the RPC cost while making that assertion unreachable.
contract CapBalanceAdaptersForkTest is BalanceAdapterTestBase {
    // Cap Finance contract addresses (Ethereum mainnet)
    address public constant CUSD = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;
    address public constant STCUSD = 0x88887bE419578051FF9F4eb6C858A951921D8888;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Fork block where the SAFE holds known cUSD + stcUSD positions
    uint256 public constant FORK_BLOCK = 24_299_555;

    // karpatkey Safe with cUSD and stcUSD at fork block
    address public constant SAFE = 0xc84718C87B80b45471Ed274c81399f1095971165;

    uint256 public constant EXPECTED_CUSD_BALANCE = 15_418_901_322_365_792_211_158;
    uint256 public constant EXPECTED_STCUSD_BALANCE = 14_477_229_622_350_858_108_721;
    /// @notice The pre-split adapter's combined figure at this block, carried over UNCHANGED.
    /// @dev It is the sum of the two per-leg burn quotes (each floored independently — the vigilo L-01 fix), which is
    ///      exactly what the two adapters now compute in two contracts. Reusing the pre-split constant is the point:
    ///      if the split had moved either leg's amount, `test_pair_sumsToThePreSplitTotal` would fail against it.
    uint256 public constant EXPECTED_USDC_AMOUNT = 30_554_823_915;

    // address(0xdead) may hold Cap dust shares — use a deterministic address with no history
    address internal unknownAccount;

    CapStablecoinBalanceAdapter public stablecoin;
    CapSavingsBalanceAdapter public savings;

    function setUp() public override {
        super.setUp();
        _setupFork();
        unknownAccount = makeAddr("unknownAccount");
        balances = _deployBalancesForAdapter(USDC);
        stablecoin = new CapStablecoinBalanceAdapter(CUSD, USDC, address(balances));
        savings = new CapSavingsBalanceAdapter(CUSD, STCUSD, USDC, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    // ============================================
    // Interface compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(stablecoin.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(stablecoin.supportsInterface(type(IERC165).interfaceId));
        assertTrue(stablecoin.supportsInterface(type(IPositionEnumerable).interfaceId));
        assertTrue(savings.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(savings.supportsInterface(type(IERC165).interfaceId));
        assertTrue(savings.supportsInterface(type(IPositionEnumerable).interfaceId));
    }

    // ============================================
    // IPositionEnumerable — the join guarantee against real positions
    // ============================================

    /// @dev Each adapter advertises exactly its own leg, and the advertised bytes are byte-identical to the
    ///      `PositionBalance.positionId` it emits for the real holder. Mocks cannot establish this: the pinned
    ///      cUSD/stcUSD addresses are the real ones only on a fork.
    function test_positionIds_matchTheEmittedPositionIdsOnMainnet() public view {
        bytes[] memory stableIds = stablecoin.positionIds();
        assertEq(stableIds.length, 1, "one leg, one shape");
        assertEq(stableIds[0], abi.encode(CUSD));

        bytes[] memory savingsIds = savings.positionIds();
        assertEq(savingsIds.length, 1);
        assertEq(savingsIds[0], abi.encode(STCUSD));

        INAVCalculator.PositionBalance[] memory a = stablecoin.getAdapterPositions(SAFE, address(0));
        INAVCalculator.PositionBalance[] memory b = savings.getAdapterPositions(SAFE, address(0));
        assertEq(a.length, 1, "SAFE holds cUSD at this block");
        assertEq(b.length, 1, "SAFE holds stcUSD at this block");
        assertEq(a[0].positionId, stableIds[0]);
        assertEq(b[0].positionId, savingsIds[0]);
    }

    /// @dev The uniformity property against live contracts: each adapter's shape resolves to its own literal pair,
    ///      and the SIBLING's token resolves to `[]` rather than to the sibling's labels.
    function test_positionLabels_areUniformAndDoNotLeakAcrossLegsOnMainnet() public view {
        string[] memory stable = stablecoin.positionLabels(abi.encode(CUSD));
        assertEq(stable.length, 2);
        assertEq(stable[0], "Stablecoin");
        assertEq(stable[1], "cUSD");
        assertEq(stablecoin.positionLabels(abi.encode(STCUSD)).length, 0, "the sibling's token is foreign here");

        string[] memory save = savings.positionLabels(abi.encode(STCUSD));
        assertEq(save.length, 2);
        assertEq(save[0], "Savings");
        assertEq(save[1], "stcUSD");
        assertEq(savings.positionLabels(abi.encode(CUSD)).length, 0, "cUSD is the quote oracle, not this leg");
    }

    function test_positionIds_areAccountIndependentOnMainnet() public view {
        assertEq(stablecoin.getAdapterPositions(unknownAccount, address(0)).length, 0);
        assertEq(savings.getAdapterPositions(unknownAccount, address(0)).length, 0);
        assertEq(stablecoin.positionIds().length, 1, "shapes advertised anyway");
        assertEq(savings.positionIds().length, 1);
    }

    // ============================================
    // Real positions
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory a = stablecoin.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], USDC);
        address[] memory b = savings.underlyingAssetsSupported();
        assertEq(b.length, 1);
        assertEq(b[0], USDC);
    }

    /// @dev **The load-bearing fork assertion of the split.** Each leg is valued against the live burn quote in its
    ///      own contract, and the two amounts must still sum to the constant the pre-split adapter produced at this
    ///      block. Any drift means the split changed accounting, not just display.
    function test_pair_sumsToThePreSplitTotal() public view {
        assertEq(IERC20(CUSD).balanceOf(SAFE), EXPECTED_CUSD_BALANCE, "cUSD balance mismatch at fork block");
        assertEq(IERC20(STCUSD).balanceOf(SAFE), EXPECTED_STCUSD_BALANCE, "stcUSD balance mismatch at fork block");

        (uint256 stableAmount, bool stableDebt) = stablecoin.getAdapterBalanceForAsset(SAFE, USDC);
        (uint256 savingsAmount, bool savingsDebt) = savings.getAdapterBalanceForAsset(SAFE, USDC);
        assertFalse(stableDebt, "Cap positions are always credit");
        assertFalse(savingsDebt);
        assertGt(stableAmount, 0, "the cUSD leg is non-zero here");
        assertGt(savingsAmount, 0, "the stcUSD leg is non-zero here");

        assertEq(
            stableAmount + savingsAmount,
            EXPECTED_USDC_AMOUNT,
            "the two legs must sum to exactly the pre-split combined figure"
        );
    }

    /// @dev Per-adapter `getAdapterPositions` equals that adapter's own aggregate getter — one leg, one position, no
    ///      rounding divergence between the two surfaces (both bottom out in the same `_usdcForCUsd` call).
    function test_getAdapterPositions_oneLegEach() public view {
        INAVCalculator.PositionBalance[] memory a = stablecoin.getAdapterPositions(SAFE, address(0));
        assertEq(a.length, 1);
        assertEq(a[0].balanceAsset.asset, USDC);
        assertEq(a[0].balanceAdapter, address(stablecoin));
        assertTrue(a[0].positionKind == PositionKind.Supplied, "cUSD is Supplied");
        (uint256 stableAggregate,) = stablecoin.getAdapterBalanceForAsset(SAFE, USDC);
        assertEq(a[0].amount, stableAggregate);

        INAVCalculator.PositionBalance[] memory b = savings.getAdapterPositions(SAFE, address(0));
        assertEq(b.length, 1);
        assertEq(b[0].balanceAsset.asset, USDC);
        assertEq(b[0].balanceAdapter, address(savings));
        assertTrue(b[0].positionKind == PositionKind.Staking, "stcUSD is Staking");
        (uint256 savingsAggregate,) = savings.getAdapterBalanceForAsset(SAFE, USDC);
        assertEq(b[0].amount, savingsAggregate);
    }

    function test_getAdapterBalances_onMainnet() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = stablecoin.getAdapterBalances(SAFE);
        assertEq(assets.length, 1);
        assertEq(assets[0], USDC);
        assertGt(amounts[0], 0);
        assertFalse(isDebt[0]);

        (address[] memory sAssets, uint256[] memory sAmounts,) = savings.getAdapterBalances(SAFE);
        assertEq(sAssets.length, 1);
        assertEq(sAssets[0], USDC);
        assertGt(sAmounts[0], 0);
    }

    function test_getAdapterBalances_unknownAccount() public view {
        (address[] memory assets,,) = stablecoin.getAdapterBalances(unknownAccount);
        assertEq(assets.length, 0);
        (address[] memory sAssets,,) = savings.getAdapterBalances(unknownAccount);
        assertEq(sAssets.length, 0);
    }

    /// @notice RESTORED. The pre-split fork suite had this and the split dropped it — the only fork-level check on
    ///         `getAdapterBalanceForAsset` for an account with no holdings.
    /// @dev ⚠️ **This is the least-protected of the three read surfaces, which is why losing it mattered.**
    ///      `getAdapterBalances` and `getAdapterPositions` both short-circuit on `account == address(0)`;
    ///      `SingleAssetBalanceAdapterBase.getAdapterBalanceForAsset` guards only the ASSET, never the account (a
    ///      recorded decision — it is pre-existing and repo-wide across every single-asset adapter). So this surface
    ///      relies entirely on the underlying `balanceOf` being zero, and this is the only test that exercises that
    ///      against the real mainnet tokens.
    ///
    ///      It went missing the way deletions do: the split renamed or folded eleven of the old suite's twelve
    ///      tests, so a by-name diff shows five "missing" of which four are renames — absent-because-fine and
    ///      absent-because-lost look identical until each is checked. #285 has now reduced zero-account protection
    ///      three separate times (a mutated-out guard, this deleted test, and the N1 deregistration), so the
    ///      cheapest defence is that this test simply exist.
    function test_getAdapterBalanceForAsset_unknownAccount() public view {
        (uint256 a,) = stablecoin.getAdapterBalanceForAsset(unknownAccount, USDC);
        assertEq(a, 0, "an account with no cUSD must report nothing on the single-asset surface");
        (uint256 b,) = savings.getAdapterBalanceForAsset(unknownAccount, USDC);
        assertEq(b, 0, "and likewise for stcUSD");
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 a,) = stablecoin.getAdapterBalanceForAsset(SAFE, address(0xdead));
        assertEq(a, 0);
        (uint256 b,) = savings.getAdapterBalanceForAsset(SAFE, address(0xdead));
        assertEq(b, 0);
    }

    function test_getAdapterPositions_withAssetFilter() public view {
        assertEq(stablecoin.getAdapterPositions(SAFE, USDC).length, 1);
        assertEq(savings.getAdapterPositions(SAFE, USDC).length, 1);
        assertEq(stablecoin.getAdapterPositions(SAFE, address(0xdead)).length, 0);
        assertEq(savings.getAdapterPositions(SAFE, address(0xdead)).length, 0);
    }
}
