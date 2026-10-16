// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    FablesSickleRangesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/FablesSickleRangesMetaBalanceAdapter.sol";
import {FablesRangeIndex} from "src/balances/MetaBalanceAdapters/fables/FablesRangeIndex.sol";
import {FablesRangeState, FablesUserPosition} from "src/balances/MetaBalanceAdapters/fables/IFablesHook.sol";
import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {NotAContract} from "src/errors.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockSickleFactory, MockSickle} from "test/balances/MetaBalanceAdapters/vfat/SickleMocks.sol";
import {
    MockFablesHook,
    MockForgedHook,
    MockGriefHook,
    MockV4PoolManager,
    MockFablesToken
} from "test/balances/MetaBalanceAdapters/fables/FablesMocks.sol";

/// @title FablesSickleRangesMetaBalanceAdapter unit tests (no fork)
/// @author KPK
/// @notice Covers the four things the chain-4663 build's natspec argues hardest for and the three the
///         upstream meta contract requires: the three authority checks, the per-(holder, hook) bucketing that
///         closed the 24 Sep 2026 blinding attack, the staked-principal/staked-fees split, the `_backlog`
///         arithmetic including its Q128 round trip, the native-ether sentinel mapping, the registered-asset
///         gate and `assetFilter`, and the exact identity bytes every row carries.
///
/// @dev **WHY THE FEE NUMBERS ARE WHOLE.** The pool state is built so each stage of the fee reconstruction
///      lands on an exact integer: pool liquidity 1,000,000 against a fee-growth delta of exactly one Q128
///      unit makes the raw backlog exactly 1,000,000. Every expected value below is therefore written as a
///      literal rather than recomputed through the adapter's own formula, which would be a tautology. The one
///      deliberate exception is {test_backlogIsNetOfTheClaimFeeAndKeepsTheQ128RoundTrip}, where the literal is
///      899,999 and the single missing wei IS the assertion.
contract FablesSickleRangesMetaBalanceAdapterTest is Test {
    /// @dev `LPFeeLibrary.DYNAMIC_FEE_FLAG`. Every Fables pool is created with it, which is why the label
    ///      leaf carries no fee tier.
    uint24 internal constant DYNAMIC_FEE = 8_388_608;
    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;
    uint128 internal constant LIQUIDITY = 1_000_000;
    uint256 internal constant RANGE_ID = uint256(keccak256("range/A"));

    address internal constant NATIVE = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    Mock_NAVCalculator internal nav;
    MockV4PoolManager internal poolManager;
    FablesRangeIndex internal index;
    MockSickleFactory internal sickleFactory;
    MockFablesHook internal hook;
    FablesSickleRangesMetaBalanceAdapter internal meta;

    address internal token0;
    address internal token1;
    PoolKey internal key;
    bytes32 internal poolId;

    address internal holder = makeAddr("holder");
    address internal feeRecipient = makeAddr("claimFeeRecipient");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        poolManager = new MockV4PoolManager();
        index = new FablesRangeIndex();
        sickleFactory = new MockSickleFactory();
        hook = new MockFablesHook(feeRecipient);

        address a = address(new MockFablesToken("TKA", 18));
        address b = address(new MockFablesToken("TKB", 18));
        (token0, token1) = a < b ? (a, b) : (b, a);
        nav.registerAsset(token0, 18, a < b ? "TKA" : "TKB");
        nav.registerAsset(token1, 18, a < b ? "TKB" : "TKA");
        nav.registerAsset(NATIVE, 18, "ETH");

        key = PoolKey({currency0: token0, currency1: token1, fee: DYNAMIC_FEE, tickSpacing: 10, hooks: address(hook)});
        poolId = keccak256(abi.encode(key));

        meta = new FablesSickleRangesMetaBalanceAdapter(
            address(poolManager), address(index), address(sickleFactory), address(nav)
        );

        _seedRange(holder, LIQUIDITY, 0, 5, 7);
        _seedPool(FixedPoint128.Q128, FixedPoint128.Q128, 0, 0);

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        meta.registerPoolKeys(keys);

        _file(holder, address(hook), RANGE_ID);
    }

    //
    // fixture helpers
    //

    /// @dev Configure the hook: `who` holds `balance` shares of the range, `staked` of them staked, and is
    ///      already owed `owed0`/`owed1` that the hook has settled and checkpointed.
    function _seedRange(address who, uint128 balance, uint128 staked, uint128 owed0, uint128 owed1) internal {
        hook.setRange(RANGE_ID, key, TICK_LOWER, TICK_UPPER, true);
        hook.setBalance(who, RANGE_ID, balance);

        FablesRangeState memory st;
        st.totalShares = LIQUIDITY;
        st.totalStaked = staked;
        hook.setRangeState(RANGE_ID, st);

        FablesUserPosition memory p;
        p.staked = staked;
        p.owed0 = owed0;
        p.owed1 = owed1;
        hook.setUserPosition(RANGE_ID, who, p);
    }

    /// @dev Pool state: price at tick 0 (inside [-100, 100]), fee-growth globals `g0`/`g1` with both boundary
    ///      ticks' outside pairs at zero, so `feeGrowthInside == global`, and the hook's own V4 position
    ///      carrying `LIQUIDITY` with `feeGrowthInsideLast` at `last0`/`last1`.
    function _seedPool(uint256 g0, uint256 g1, uint256 last0, uint256 last1) internal {
        poolManager.setSlot0(poolId, TickMath.getSqrtRatioAtTick(0), 0, 0, 0);
        poolManager.setFeeGrowthGlobals(poolId, g0, g1);
        poolManager.setTickFeeGrowthOutside(poolId, TICK_LOWER, 0, 0);
        poolManager.setTickFeeGrowthOutside(poolId, TICK_UPPER, 0, 0);
        poolManager.setPosition(poolId, address(hook), TICK_LOWER, TICK_UPPER, bytes32(0), LIQUIDITY, last0, last1);
    }

    function _file(address who, address hook_, uint256 rangeId) internal {
        FablesRangeIndex.Entry[] memory e = new FablesRangeIndex.Entry[](1);
        e[0] = FablesRangeIndex.Entry({hook: hook_, rangeId: rangeId});
        index.index(who, e);
    }

    function _instances(bytes32 id) internal pure returns (bytes32[] memory one) {
        one = new bytes32[](1);
        one[0] = id;
    }

    function _rows(address account) internal view returns (INAVCalculator.PositionBalance[] memory) {
        return meta.getAdapterPositionsForInstances(account, _instances(poolId), address(0));
    }

    function _amount(INAVCalculator.PositionBalance[] memory rows, address asset, PositionKind kind)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].balanceAsset.asset == asset && rows[i].positionKind == kind) total += rows[i].amount;
        }
    }

    function _expectedPrincipal(uint128 liquidity) internal pure returns (uint256 amount0, uint256 amount1) {
        return LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(0),
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            liquidity
        );
    }

    //
    // shape and identity
    //

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionEnumerable).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
        assertFalse(meta.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// @notice Every row carries the Fables brand at all three levels and the documented id shapes.
    /// @dev `ProtocolIds.FABLES` at brand level is the point, not an oversight: a Fables share is not a
    ///      Uniswap position, and filing these rows under `UNISWAP` would make a portfolio view claim
    ///      liquidity the account cannot touch.
    function test_identityFieldsAndExactPositionIdBytes() public view {
        INAVCalculator.PositionBalance[] memory rows = _rows(holder);
        assertGt(rows.length, 0, "fixture produced no rows");
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].protocolBrand, ProtocolIds.FABLES, "brand");
            assertEq(rows[i].protocolId, ProtocolIds.FABLES, "id");
            assertEq(rows[i].protocolSubId, ProtocolIds.FABLES, "subId");
            assertEq(rows[i].positionId, abi.encode(poolId), "positionId is abi.encode(bytes32 poolId)");
            assertEq(rows[i].positionId.length, 32, "positionId is exactly one word");
            assertEq(rows[i].positionInstanceId, bytes32(RANGE_ID), "rangeId rides in positionInstanceId");
            assertEq(rows[i].balanceAdapter, address(meta), "balanceAdapter");
            assertFalse(rows[i].isDebt, "an LP leg is never debt");
            assertFalse(rows[i].isLocked, "withdraw auto-unstakes and carries no pause check");
        }
        assertEq(meta.protocolName(), ProtocolNames.FABLES, "display name is derived from the protocolId");
    }

    /// @notice {IPositionEnumerable} requires `positionIds()` to be byte-identical to what rows carry.
    /// @dev The base's default `_instancePositionId` encodes the coordinate as an ADDRESS, which for a 32-byte
    ///      pool id would revert; the override is what keeps this honest.
    function test_positionIdsMatchTheEmittedBytes() public {
        nav.setMetaInstances(address(meta), _instances(poolId));
        bytes[] memory ids = meta.positionIds();
        assertEq(ids.length, 1, "one governed shape");
        assertEq(ids[0], abi.encode(poolId), "enumerated id");
        assertEq(ids[0], _rows(holder)[0].positionId, "enumerated id equals the emitted positionId");
    }

    function test_positionLabels() public view {
        string[] memory lbl = meta.positionLabels(abi.encode(poolId));
        assertEq(lbl.length, 2, "[category, leaf]");
        assertEq(lbl[0], "AMM Liquidity Pool");
        assertEq(lbl[1], string.concat(MockFablesToken(token0).symbol(), "/", MockFablesToken(token1).symbol()));

        // A malformed positionId degrades to nothing rather than reverting or labelling a foreign coordinate.
        assertEq(meta.positionLabels(abi.encodePacked(poolId, poolId)).length, 0, "two words is not our shape");
        assertEq(meta.positionLabels(hex"").length, 0, "empty");

        // A pool whose key was never registered has no leaf to derive, so the category collapses to one segment.
        string[] memory unknown = meta.positionLabels(abi.encode(keccak256("never registered")));
        assertEq(unknown.length, 1, "empty-leaf collapse");
        assertEq(unknown[0], "AMM Liquidity Pool");
    }

    function test_constructorRequiresContracts() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "PoolManager"));
        new FablesSickleRangesMetaBalanceAdapter(makeAddr("eoa"), address(index), address(sickleFactory), address(nav));
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "FablesRangeIndex"));
        new FablesSickleRangesMetaBalanceAdapter(
            address(poolManager), makeAddr("eoa"), address(sickleFactory), address(nav)
        );
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "SickleFactory"));
        new FablesSickleRangesMetaBalanceAdapter(address(poolManager), address(index), makeAddr("eoa"), address(nav));
    }

    function test_emptyAccountReportsNothing() public {
        assertEq(_rows(makeAddr("nobody")).length, 0);
        (address[] memory assets, uint256[] memory amounts, bool[] memory debts) = meta.getAdapterBalances(holder);
        assertEq(assets.length, 0, "meta adapters are not on the flat-balance path");
        assertEq(amounts.length, 0);
        assertEq(debts.length, 0);
        (uint256 amount, bool ok) = meta.getAdapterBalanceForAsset(holder, token0);
        assertEq(amount, 0);
        assertFalse(ok);
    }

    //
    // valuation
    //

    /// @notice Principal and fees for the plain case: no staking, no claim fee.
    /// @dev The fee literal is `owed` plus the whole raw backlog, because with `totalStaked == 0` and a zero
    ///      claim fee {_backlog} must pass the raw amount through untouched.
    function test_principalAndFeesWithNoCuts() public view {
        INAVCalculator.PositionBalance[] memory rows = _rows(holder);
        (uint256 e0, uint256 e1) = _expectedPrincipal(LIQUIDITY);
        assertGt(e0, 0, "fixture is in range on currency0");
        assertGt(e1, 0, "fixture is in range on currency1");
        assertEq(_amount(rows, token0, PositionKind.Supplied), e0, "supplied0");
        assertEq(_amount(rows, token1, PositionKind.Supplied), e1, "supplied1");
        assertEq(_amount(rows, token0, PositionKind.Fees), 1_000_005, "owed0 + the whole raw backlog");
        assertEq(_amount(rows, token1, PositionKind.Fees), 1_000_007, "owed1 + the whole raw backlog");
        assertEq(_amount(rows, token0, PositionKind.Staking), 0, "nothing is staked in this fixture");
    }

    /// @notice The mid-stage component: fees credited to the range but not yet pushed into this holder's
    ///         `owed`, which a valuer stopping at `owed` would miss entirely.
    /// @dev `accFee0X128 - checkpoint0X128` is one Q128 unit per unstaked share, so the component is exactly
    ///      the holder's share count. Already net of both cuts (the hook applied them before raising
    ///      `accFee`), which is why no rate is involved here.
    function test_accruedButUnsettledFeesAreReported() public {
        FablesRangeState memory st;
        st.totalShares = LIQUIDITY;
        st.accFee0X128 = FixedPoint128.Q128;
        hook.setRangeState(RANGE_ID, st);
        // No backlog, so the only moving part is the accFee-minus-checkpoint term.
        _seedPool(0, 0, 0, 0);

        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 5 + 1_000_000, "owed0 + accrued-not-settled");
    }

    /// @notice Staked principal IS valued, as `PositionKind.Staking`; the fees those shares earn are NOT.
    /// @dev This is the split issue #40 got half right. `withdraw` auto-unstakes, so staked principal is
    ///      fully withdrawable and must be on the books. Its fee accrual goes to the Fables distributor
    ///      against an offchain emission claim, so booking it would record revenue the fund can never
    ///      receive. The fee leg therefore drops to the unstaked quarter-share exactly: 750,000, not
    ///      1,000,000.
    function test_stakedPrincipalIsValuedAndItsFeesAreNot() public {
        _seedRange(holder, LIQUIDITY, 250_000, 5, 7);

        INAVCalculator.PositionBalance[] memory rows = _rows(holder);
        (uint256 u0, uint256 u1) = _expectedPrincipal(750_000);
        (uint256 s0, uint256 s1) = _expectedPrincipal(250_000);

        assertEq(_amount(rows, token0, PositionKind.Supplied), u0, "unstaked principal0");
        assertEq(_amount(rows, token1, PositionKind.Supplied), u1, "unstaked principal1");
        assertEq(_amount(rows, token0, PositionKind.Staking), s0, "staked principal0");
        assertEq(_amount(rows, token1, PositionKind.Staking), s1, "staked principal1");
        assertGt(s0 + s1, 0, "the staking legs must actually carry something");

        assertEq(_amount(rows, token0, PositionKind.Fees), 5 + 750_000, "only the unstaked shares earn");
        assertEq(_amount(rows, token1, PositionKind.Fees), 7 + 750_000, "only the unstaked shares earn");
    }

    /// @notice The backlog is net of the claim fee, and the Q128 round trip is kept rather than simplified.
    /// @dev 10% of a 1,000,000 raw backlog leaves 900,000 — but the hook truncates at BOTH of its two Q128
    ///      steps, and this adapter mirrors it term for term, so the holder's share is 899,999. The missing
    ///      wei is the assertion: a valuer that simplified to `unstaked * net / unstakedTotal` would report
    ///      exactly 900,000 and disagree with the hook on every claim.
    ///
    ///      `owed` is NOT discounted again — it was already net at accrual — so the row is `5 + 899,999`.
    function test_backlogIsNetOfTheClaimFeeAndKeepsTheQ128RoundTrip() public {
        hook.setClaimFee(RANGE_ID, 1000);
        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 5 + 899_999, "net of 10%, floored twice");
    }

    /// @notice The staked cut comes off the backlog before the claim fee, mirroring `LedgerLib._split`.
    /// @dev A quarter of the range's shares are staked across all holders, so a quarter of the raw backlog is
    ///      routed to the distributor before anything else happens to it.
    function test_backlogIsNetOfTheStakedCut() public {
        _seedRange(holder, LIQUIDITY, 250_000, 0, 0);
        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 750_000, "raw minus the staked quarter");
    }

    /// @notice A hook that will not say what the claim fee is loses its backlog, not its principal.
    /// @dev The `type(uint16).max` sentinel. Guessing zero would over-report by up to the cap; under-reporting
    ///      an unsynced sliver is recoverable, over-reporting a NAV is not. Only the backlog is dropped —
    ///      `owed` and the accrued-not-settled component are already net and stay.
    function test_unknownClaimFeeRateDropsOnlyTheBacklog() public {
        (uint256 e0,) = _expectedPrincipal(LIQUIDITY);

        hook.setEffectiveClaimFeeReverts(true);
        INAVCalculator.PositionBalance[] memory rows = _rows(holder);
        assertEq(_amount(rows, token0, PositionKind.Fees), 5, "backlog dropped, owed kept");
        assertEq(_amount(rows, token0, PositionKind.Supplied), e0, "principal untouched");

        // Same outcome when the recipient getter is the one that will not answer...
        hook.setEffectiveClaimFeeReverts(false);
        hook.setClaimFeeRecipientReverts(true);
        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 5, "recipient unreadable");

        // ...and when it answers with a word that is not an address. `address(0)` is a MEANINGFUL value here
        // ("no claim fee at all"), so manufacturing it out of a dirty word would change the answer.
        hook.setClaimFeeRecipientReverts(false);
        hook.setClaimFeeRecipientDirty(true);
        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 5, "recipient word is not an address");

        // A rate that takes everything is not a rate.
        hook.setClaimFeeRecipientDirty(false);
        hook.setClaimFee(RANGE_ID, 10_000);
        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 5, "bps >= 10_000 rejected");
    }

    /// @notice No claim-fee recipient means `_split` takes no claim fee at all, whatever the rate says.
    function test_zeroRecipientMeansNoClaimFee() public {
        hook.setClaimFee(RANGE_ID, 1000);
        hook.setClaimFeeRecipient(address(0));
        assertEq(_amount(_rows(holder), token0, PositionKind.Fees), 5 + 1_000_000, "rate is moot with no recipient");
    }

    /// @notice A paused hook is reported exactly as an unpaused one.
    /// @dev Deliberate: `withdraw` and `unstake` carry no pause check, so principal is always exitable, and
    ///      `owed` stays a real claim even while `claimFees` is frozen. A wrong lock signal is worse than
    ///      none, so the pause is an offchain gate and never a haircut here.
    function test_pausedHookIsReportedUnchanged() public {
        INAVCalculator.PositionBalance[] memory before = _rows(holder);
        hook.setPaused(true);
        INAVCalculator.PositionBalance[] memory afterPause = _rows(holder);
        assertEq(afterPause.length, before.length, "row count");
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterPause[i].amount, before[i].amount, "amount");
            assertFalse(afterPause[i].isLocked, "pause is not a lock");
        }
    }

    //
    // native ether
    //

    /// @notice A native-ether pool reports its ETH side under the ERC-7528 sentinel, never the raw zero.
    /// @dev `registerAsset(address(0), ...)` is rejected by the NAV and `PriceFeedLib` DROPS an unpriceable
    ///      leg silently, so an unmapped zero makes the whole ETH side of a position vanish with no stale
    ///      flag and no error. That exact bug was measured on the Uniswap V4 sibling on 14 Sep 2026.
    function test_nativeCurrencyIsMappedToTheSentinel() public {
        PoolKey memory nativeKey = PoolKey({
            currency0: address(0), currency1: token1, fee: DYNAMIC_FEE, tickSpacing: 10, hooks: address(hook)
        });
        bytes32 nativePoolId = keccak256(abi.encode(nativeKey));
        uint256 nativeRangeId = uint256(keccak256("range/native"));

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = nativeKey;
        meta.registerPoolKeys(keys);

        (address c0, address c1) = meta.poolCurrencies(nativePoolId);
        assertEq(c0, NATIVE, "currency0 normalised to the sentinel");
        assertEq(c1, token1, "currency1 untouched");

        hook.setRange(nativeRangeId, nativeKey, TICK_LOWER, TICK_UPPER, true);
        hook.setBalance(holder, nativeRangeId, LIQUIDITY);
        FablesRangeState memory st;
        st.totalShares = LIQUIDITY;
        hook.setRangeState(nativeRangeId, st);
        poolManager.setSlot0(nativePoolId, TickMath.getSqrtRatioAtTick(0), 0, 0, 0);
        poolManager.setPosition(nativePoolId, address(hook), TICK_LOWER, TICK_UPPER, bytes32(0), LIQUIDITY, 0, 0);
        _file(holder, address(hook), nativeRangeId);

        INAVCalculator.PositionBalance[] memory rows =
            meta.getAdapterPositionsForInstances(holder, _instances(nativePoolId), address(0));
        (uint256 e0,) = _expectedPrincipal(LIQUIDITY);
        assertEq(_amount(rows, NATIVE, PositionKind.Supplied), e0, "ETH principal under the sentinel");
        assertEq(_amount(rows, address(0), PositionKind.Supplied), 0, "never the raw zero address");

        // And the label reads the native symbol out of the registry rather than calling `symbol()` on nothing.
        string[] memory lbl = meta.positionLabels(abi.encode(nativePoolId));
        assertEq(lbl[1], string.concat("ETH/", MockFablesToken(token1).symbol()));
    }

    //
    // registry gate and assetFilter
    //

    /// @notice One unregistered currency drops the WHOLE instance.
    /// @dev NAV values an LP from the sum of its two legs, so a half-priced LP would silently understate it.
    ///      Same rule as `UniswapV3PoolsMetaBalanceAdapter`.
    function test_unregisteredAssetDropsTheInstance() public {
        assertGt(_rows(holder).length, 0, "registered to begin with");
        nav.unregisterAssetHelper(token1);
        assertEq(_rows(holder).length, 0, "one unregistered currency drops both legs");
    }

    /// @notice `assetFilter` gates which legs are emitted, never whether the instance is valued.
    function test_assetFilter() public {
        INAVCalculator.PositionBalance[] memory only1 =
            meta.getAdapterPositionsForInstances(holder, _instances(poolId), token1);
        assertGt(only1.length, 0, "filtered rows exist");
        for (uint256 i; i < only1.length; ++i) {
            assertEq(only1[i].balanceAsset.asset, token1, "only the filtered currency");
        }

        // A filter naming neither currency short-circuits to nothing.
        assertEq(
            meta.getAdapterPositionsForInstances(holder, _instances(poolId), makeAddr("other")).length,
            0,
            "filter matching neither currency"
        );
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_instances(poolId));
        assertEq(assets.length, 2);
        assertEq(assets[0], token0);
        assertEq(assets[1], token1);
        // A pool with no registered preimage names nothing: V4 pool ids are one-way.
        assertEq(meta.underlyingAssetsSupportedForInstances(_instances(keccak256("unknown"))).length, 0);
    }

    //
    // the three authority checks
    //

    /// @notice A contract that is not the pool's hook cannot get itself valued, even holding the real key.
    /// @dev Check 2, plus an honest note on check 3. The forged hook claims a `uint128` max balance and
    ///      answers with the GENUINE PoolKey, which is trivially within a hostile contract's power — so a
    ///      valuer that stopped at "the key the hook returned hashes to my instance" would be fully
    ///      satisfied and would then trust that balance.
    ///
    ///      Check 3 (`key.hooks == hook`) is no longer REACHABLE through any public path, and that is a
    ///      consequence of the 24 Sep 2026 bucketing rather than an accident: `_poolHook[instance]` is taken
    ///      from a preimage of `instance` itself, and check 2 forces the hook's returned key to hash to
    ///      `instance`, so by collision resistance the returned `key.hooks` IS the hook that was called. It
    ///      is kept as defence in depth against a future edit that re-opens who gets called. Before the
    ///      bucketing it was load-bearing: `hook` came straight from the permissionless index, and check 3
    ///      was the only thing between a forged hook and an arbitrarily inflated NAV.
    function test_forgedHookIsNotValued() public {
        MockForgedHook forged = new MockForgedHook(key, type(uint128).max, TICK_LOWER, TICK_UPPER);
        _file(holder, address(forged), RANGE_ID);
        // The governed pool still names the real hook, so the forger's bucket is not even loaded.
        assertEq(meta.poolHook(poolId), address(hook), "registered hook unchanged");

        // Point the instance at the forger directly to exercise check 3 rather than the bucketing: register a
        // key that NAMES the forger, then file a range whose returned key names the real hook instead.
        PoolKey memory forgedKey = key;
        forgedKey.hooks = address(forged);
        bytes32 forgedPoolId = keccak256(abi.encode(forgedKey));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = forgedKey;
        meta.registerPoolKeys(keys);
        assertEq(meta.poolHook(forgedPoolId), address(forged), "instance now names the forger");

        assertEq(
            meta.getAdapterPositionsForInstances(holder, _instances(forgedPoolId), address(0)).length,
            0,
            "a hook returning someone else's key is not valued"
        );
    }

    /// @notice A range filed under the right hook but belonging to a different pool is not valued.
    /// @dev Check 2, and why checks 2 and 3 are not redundant: one hook hosts several pools.
    function test_rangeFromAnotherPoolOnTheSameHookIsNotValued() public {
        PoolKey memory otherKey = key;
        otherKey.tickSpacing = 60; // a different pool, same hook
        bytes32 otherPoolId = keccak256(abi.encode(otherKey));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = otherKey;
        meta.registerPoolKeys(keys);

        // The filed range's key hashes to `poolId`, not `otherPoolId`.
        assertEq(
            meta.getAdapterPositionsForInstances(holder, _instances(otherPoolId), address(0)).length, 0, "wrong pool"
        );
        assertGt(_rows(holder).length, 0, "the right pool still values it");
    }

    /// @notice A filed range the holder has exited contributes nothing, even before anyone prunes it.
    /// @dev Check 1, and the normal state of the index rather than an edge case: every re-centre empties a
    ///      range and files a new one.
    function test_staleRangeEntryIsNotValued() public {
        hook.setBalance(holder, RANGE_ID, 0);
        assertEq(_rows(holder).length, 0, "an emptied range was still valued");
        assertTrue(index.isIndexed(holder, address(hook), RANGE_ID), "the entry is still filed");
        (uint256 live, uint256 filed) = meta.coverage(holder);
        assertEq(live, 0, "coverage sees it is empty");
        assertEq(filed, 1, "but it is still filed");
    }

    /// @notice A hook that says `set == false` for the range is not valued.
    function test_rangeWithoutAPreimageIsNotValued() public {
        hook.setRange(RANGE_ID, key, TICK_LOWER, TICK_UPPER, false);
        assertEq(_rows(holder).length, 0, "no preimage, no valuation");
    }

    //
    // the 24 Sep 2026 blinding attack
    //

    /// @notice A stranger files an unprunable entry under a hook that reverts for the adapter. The real
    ///         position is still valued, row for row.
    /// @dev THE regression test for the review of PR #46. The first version walked every filed entry and
    ///      called its hook, so this entry reverted the holder's read for EVERY instance and the real range
    ///      reported zero rows (reproduced on a live chain-4663 fork). The per-(holder, hook) bucketing means
    ///      the grief hook's entry is never loaded, because no governed pool's PoolKey names it.
    function test_strangerFiledHookCannotHideARealPosition() public {
        INAVCalculator.PositionBalance[] memory before = _rows(holder);
        assertGt(before.length, 0, "real position valued before");

        MockGriefHook grief = new MockGriefHook(address(index), key);
        FablesRangeIndex.Entry[] memory e = new FablesRangeIndex.Entry[](1);
        e[0] = FablesRangeIndex.Entry({hook: address(grief), rangeId: 1});
        vm.prank(makeAddr("stranger"));
        index.index(holder, e);

        // It cannot be pruned either: it answers the index with a non-zero balance.
        vm.expectRevert(
            abi.encodeWithSelector(FablesRangeIndex.EntryStillValid.selector, holder, address(grief), uint256(1))
        );
        index.prune(holder, e);

        INAVCalculator.PositionBalance[] memory afterGrief = _rows(holder);
        assertEq(afterGrief.length, before.length, "rows changed");
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterGrief[i].amount, before[i].amount, "amount changed");
            assertEq(afterGrief[i].balanceAsset.asset, before[i].balanceAsset.asset, "asset changed");
        }
        assertEq(index.indexedRangeIds(holder, address(grief)).length, 1, "it IS filed, in its own bucket");
        assertEq(index.indexedRangeIds(holder, address(hook)).length, 1, "the governed bucket is untouched");
    }

    /// @notice No registered PoolKey, no rows: the adapter will not guess which hook to call.
    /// @dev The stated cost of the bucketing fix. An operator runbook must register the key of every governed
    ///      pool and gate on {poolHook} matching it.
    function test_unregisteredInstanceReportsNothing() public {
        FablesSickleRangesMetaBalanceAdapter fresh = new FablesSickleRangesMetaBalanceAdapter(
            address(poolManager), address(index), address(sickleFactory), address(nav)
        );
        assertEq(fresh.poolHook(poolId), address(0), "hook before registration");
        assertEq(
            fresh.getAdapterPositionsForInstances(holder, _instances(poolId), address(0)).length,
            0,
            "valued without a registered key"
        );

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        fresh.registerPoolKeys(keys);
        assertEq(fresh.poolHook(poolId), address(hook), "hook after registration");
        assertGt(
            fresh.getAdapterPositionsForInstances(holder, _instances(poolId), address(0)).length,
            0,
            "not valued after registration"
        );
    }

    //
    // the pool-key registry
    //

    /// @notice A key is only ever accepted under the pool id it hashes to, and the first write wins.
    function test_registerPoolKeysIsSelfValidatingAndIdempotent() public {
        (address c0, address c1) = meta.poolCurrencies(poolId);
        assertEq(c0, token0);
        assertEq(c1, token1);

        // Re-registering a pool id already recorded cannot repoint its hook.
        PoolKey memory impostor = key;
        impostor.hooks = address(new MockForgedHook(key, 1, TICK_LOWER, TICK_UPPER));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = impostor;
        meta.registerPoolKeys(keys);
        assertEq(meta.poolHook(poolId), address(hook), "a different key hashes to a different pool id");

        // And it did land — under its own id, which no governed instance names.
        assertEq(meta.poolHook(keccak256(abi.encode(impostor))), impostor.hooks, "filed under its own id");
    }

    /// @notice The recorded hook is the one the KEY names, never the contract that was asked.
    /// @dev `learnPoolKeys` calls whatever address it is given. A forger returning the real key must record
    ///      the real hook, or registration itself would become the way in.
    function test_learnPoolKeysRecordsTheKeysHookNotTheCaller() public {
        FablesSickleRangesMetaBalanceAdapter fresh = new FablesSickleRangesMetaBalanceAdapter(
            address(poolManager), address(index), address(sickleFactory), address(nav)
        );
        MockForgedHook forged = new MockForgedHook(key, type(uint128).max, TICK_LOWER, TICK_UPPER);
        uint256[] memory ids = new uint256[](1);
        ids[0] = RANGE_ID;
        fresh.learnPoolKeys(address(forged), ids);

        assertEq(fresh.poolHook(poolId), address(hook), "the forger recorded the real hook");
        (address c0, address c1) = fresh.poolCurrencies(poolId);
        assertEq(c0, token0);
        assertEq(c1, token1);
    }

    function test_learnPoolKeysRejectsAnUnknownRange() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = uint256(keccak256("never deposited into"));
        vm.expectRevert(
            abi.encodeWithSelector(FablesSickleRangesMetaBalanceAdapter.UnknownRange.selector, address(hook), ids[0])
        );
        meta.learnPoolKeys(address(hook), ids);
    }

    //
    // the Sickle indirection
    //

    /// @notice A range held by the account's Sickle is reported as the account's.
    /// @dev The reason this family exists: a vfat deposit moves the tokens into the Safe's Sickle, and NAV is
    ///      strictly account-scoped, so an adapter reading only `account` reports zero for a deployed book.
    function test_sickleHeldRangeIsReportedForTheOwner() public {
        address safe = makeAddr("safe");
        MockSickle sickle = new MockSickle(safe);
        sickleFactory.setSickle(safe, address(sickle));

        assertEq(_rows(safe).length, 0, "the Safe itself holds nothing");

        _seedRange(address(sickle), LIQUIDITY, 0, 5, 7);
        _file(address(sickle), address(hook), RANGE_ID);

        INAVCalculator.PositionBalance[] memory rows = _rows(safe);
        (uint256 e0,) = _expectedPrincipal(LIQUIDITY);
        assertEq(_amount(rows, token0, PositionKind.Supplied), e0, "the Sickle's principal counts as the Safe's");
        assertEq(meta.sickleOf(safe), address(sickle), "both directions agree");
    }

    /// @notice A Sickle whose `owner()` names someone else is never admitted.
    function test_unattestedSickleIsNotAdmitted() public {
        address safe = makeAddr("safe2");
        MockSickle sickle = new MockSickle(makeAddr("someone else"));
        sickleFactory.setSickle(safe, address(sickle));

        _seedRange(address(sickle), LIQUIDITY, 0, 5, 7);
        _file(address(sickle), address(hook), RANGE_ID);

        assertEq(meta.sickleOf(safe), address(0), "reverse attestation fails");
        assertEq(_rows(safe).length, 0, "and nothing is borrowed from it");
    }

    //
    // coverage
    //

    /// @notice {coverage} reports the index's own two numbers and does not pretend to a denominator.
    /// @dev `live == filed` means "no filed entry has emptied", NOT "the book is covered": ERC-6909 has no
    ///      per-holder range count anywhere on chain, so nothing here can see a range that was never filed.
    function test_coverageCountsOnlyWhatIsFiled() public {
        (uint256 live, uint256 filed) = meta.coverage(holder);
        assertEq(filed, 1, "one entry filed");
        assertEq(live, 1, "and it still carries a balance");

        // A second genuine range the holder actually holds moves both numbers — and nothing anywhere would
        // have revealed that it existed. That is the point being pinned.
        uint256 second = uint256(keccak256("range/B"));
        hook.setRange(second, key, TICK_LOWER, TICK_UPPER, true);
        hook.setBalance(holder, second, 1);
        (live, filed) = meta.coverage(holder);
        assertEq(filed, 1, "still invisible until someone files it");

        _file(holder, address(hook), second);
        (live, filed) = meta.coverage(holder);
        assertEq(filed, 2, "filed");
        assertEq(live, 2, "and live");
    }
}
