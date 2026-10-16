// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    FablesSickleRangesMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/FablesSickleRangesMetaBalanceAdapter.sol";
import {FablesRangeIndex} from "src/balances/MetaBalanceAdapters/fables/FablesRangeIndex.sol";
import {IFablesHook, FablesRangeState} from "src/balances/MetaBalanceAdapters/fables/IFablesHook.sol";
import {IExtsload, PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockGriefHook} from "test/balances/MetaBalanceAdapters/fables/FablesMocks.sol";

/// @notice The deployed chain-4663 Fables adapter, for a cross-build comparison.
/// @dev Only the one method this suite calls. That contract is an INDEPENDENT build of the same valuation:
///      a different base class, `FullMath` instead of OpenZeppelin's `Math.mulDiv`, and its own vendored
///      TickMath. Wei-level agreement between it and this port is therefore real evidence about the port,
///      not a self-consistency check.
interface ILegacyFablesAdapter {
    function getAdapterPositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory);
}

interface IMetaInstances {
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
}

/// @title FablesSickleRangesMetaBalanceForkTest
/// @author KPK
/// @notice Fork tests against chain 4663 at a pinned block, on the vault position the adapter was built for:
///         the kRHETH Sickle's NATIVE ether / USDG Fables range.
///
/// @dev **WHAT IS TRUE AT {FORK_BLOCK} = 90,186,157 (all measured 16 Oct 2026 by reading the chain).**
///        - The live Fables adapter `0xf48B…841F` governs exactly 7 instances on the NAV proxy `0x54EA…6214`.
///        - Instance `0xbac3aa3b…e551` is kRHETH's Fables pool. Its PoolKey is
///          `(currency0 = address(0), currency1 = USDG, fee = 0x800000 dynamic, tickSpacing = 10,
///          hooks = 0x06a8…6080)` — a NATIVE ether pool, which is exactly the case the family's worst
///          measured bug (14 Sep 2026, the raw zero address silently dropping a whole ETH side) came from.
///        - The vault's Avatar Safe `0x2EeB…8aa4` holds nothing itself; its vfat Sickle
///          `0x744b…cac6` holds 6,467,343,454,345,013 shares of range `0x28f2…c4af`, ticks
///          [-198070, -196620]. Both vfat directions agree: `SickleFactory.sickles(avatar) == sickle` and
///          `ISickle(sickle).owner() == avatar`.
///        - `rangeState.totalStaked == 0` and the Sickle is the range's sole holder
///          (`balanceOf == totalShares`), so the staking legs are empty here. That matches the measured
///          fleet-wide fact (zero `Staked` events over 3,000,000 blocks, `totalStaked == 0` on all 1,915
///          ranges, 24 Sep 2026) and is why the staking path is covered in the unit suite instead.
///        - `claimFeeRecipient() == address(0)` on this hook, so no claim fee is taken whatever the rate
///          says, and `effectiveClaimFee(rangeId) == 0`.
///        - The spot price sits BELOW the range, so the position is entirely currency0: the adapter emits an
///          ETH `Supplied` leg and no USDG `Supplied` leg, plus both fee legs.
///
/// @dev Pinned rather than run at head, unlike the chain-4663 original (which could not pin, because the
///      public RPC it used prunes state). Alchemy serves archive state for 4663, so every number below is a
///      fact about one block rather than a relation that has to hold forever.
contract FablesSickleRangesMetaBalanceForkTest is BalanceAdapterTestBase {
    uint256 public constant FORK_BLOCK = 90_186_157;

    address public constant NAV_PROXY = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address public constant LIVE_ADAPTER = 0xf48B71F3a234EEd583a4B1b883e02FeEa505841F;
    address public constant LIVE_INDEX = 0xfCdaC9e666D65b63D38f1E20c05FA199Ab6ad55E;
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant SICKLE_FACTORY = 0x3575Aa02Ae85D8Cd2AaE6DCaA5D8750cFc9622e6;

    address public constant AVATAR = 0x2EeB414D0bc548094a574E6801f5365498D28aa4;
    address public constant SICKLE = 0x744b5597203E2a49169c2E49Bc671A065Ec6cac6;
    address public constant HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant NATIVE = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    bytes32 public constant POOL_ID = 0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551;
    uint256 public constant RANGE_ID = 0x28f2d251381722a5606bd2aeae9f0e2889a215a774d1deb95131dc24d352c4af;
    int24 public constant TICK_LOWER = -198070;
    int24 public constant TICK_UPPER = -196620;
    uint128 public constant SHARES = 6_467_343_454_345_013;

    /// @notice `LPFeeLibrary.DYNAMIC_FEE_FLAG`. Every Fables pool is created with it.
    uint24 public constant DYNAMIC_FEE = 8_388_608;

    /// @notice The two hooks whose ABIs are measured to differ, and the reason {IFablesHook} omits
    ///         `claimFeeBps` in both of its shapes.
    address public constant SPY_HOOK = 0xA0E8fBFf13E24Af2b5e61A72800E08a161bDe080;
    address public constant CRCL_HOOK = 0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080;

    FablesSickleRangesMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp(); // calls _setupFork()
        balances = _deployBalancesForAdapter(_assets());
        // Registered directly rather than through `_deployBalancesForAdapter`: the ERC-7528 sentinel is a
        // code-less address, so the helper's `decimals()` probe has nothing to call.
        balances.registerAssetForTest(NATIVE, 18, "ETH");

        meta = new FablesSickleRangesMetaBalanceAdapter(POOL_MANAGER, LIVE_INDEX, SICKLE_FACTORY, address(balances));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = _key();
        meta.registerPoolKeys(keys);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("robinhood-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = USDG;
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: USDG, fee: DYNAMIC_FEE, tickSpacing: 10, hooks: HOOK});
    }

    function _instances() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = POOL_ID;
    }

    function _rows(address account) internal view returns (INAVCalculator.PositionBalance[] memory) {
        return meta.getAdapterPositionsForInstances(account, _instances(), address(0));
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

    //
    // independent reads of PoolManager storage
    //
    // The slot derivations below are written out inline rather than taken from {V4StateLibrary}, so a change
    // to that library's layout constants fails these tests instead of moving the mock and the reader
    // together. `Pool.State` is: +0 Slot0, +1/+2 feeGrowthGlobal, +3 liquidity, +4 ticks, +6 positions.
    //

    function _poolStateSlot() internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(POOL_ID, bytes32(uint256(6)))));
    }

    function _load(uint256 slot) internal view returns (uint256) {
        return uint256(IExtsload(POOL_MANAGER).extsload(bytes32(slot)));
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        uint256 word = _load(_poolStateSlot());
        // Both casts are field EXTRACTIONS from a packed word, not value narrowings: `Slot0` is
        // `sqrtPriceX96 | tick | protocolFee | lpFee`, low to high. The `uint24 -> int24` hop restores the
        // sign, which is load-bearing — this pool trades around tick -197000.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(word);
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(uint24(word >> 160));
    }

    /// @dev `ticks` is keyed by `int24`, which Solidity pads SIGN-EXTENDED to a full word.
    function _tickFeeGrowthOutside(int24 tick) internal view returns (uint256 o0, uint256 o1) {
        uint256 base = uint256(keccak256(abi.encodePacked(int256(tick), bytes32(_poolStateSlot() + 4))));
        o0 = _load(base + 1);
        o1 = _load(base + 2);
    }

    /// @dev v4-core `Position.calculatePositionKey`, with the HOOK as owner and salt zero — the whole point
    ///      of the Fables ownership model.
    function _hookPosition() internal view returns (uint128 liquidity, uint256 last0, uint256 last1) {
        bytes32 posKey = keccak256(abi.encodePacked(HOOK, TICK_LOWER, TICK_UPPER, bytes32(0)));
        uint256 slot = uint256(keccak256(abi.encodePacked(posKey, bytes32(_poolStateSlot() + 6))));
        liquidity = uint128(_load(slot));
        last0 = _load(slot + 1);
        last1 = _load(slot + 2);
    }

    /// @dev The whole three-way `getFeeGrowthInside` branch, recomputed here rather than imported.
    function _feeGrowthInside() internal view returns (uint256 inside0, uint256 inside1) {
        (, int24 tick) = _slot0();
        (uint256 lo0, uint256 lo1) = _tickFeeGrowthOutside(TICK_LOWER);
        (uint256 up0, uint256 up1) = _tickFeeGrowthOutside(TICK_UPPER);
        unchecked {
            if (tick < TICK_LOWER) {
                inside0 = lo0 - up0;
                inside1 = lo1 - up1;
            } else if (tick >= TICK_UPPER) {
                inside0 = up0 - lo0;
                inside1 = up1 - lo1;
            } else {
                inside0 = _load(_poolStateSlot() + 1) - lo0 - up0;
                inside1 = _load(_poolStateSlot() + 2) - lo1 - up1;
            }
        }
    }

    //
    // the claim the whole design rests on
    //

    /// @notice A Fables share IS one unit of Uniswap V4 liquidity, so `balanceOf` feeds `LiquidityAmounts`
    ///         unscaled and the adapter needs no conversion factor anywhere.
    /// @dev MEASURED offchain over 1,915 live ranges across all seven hooks with zero mismatches (chain 4663,
    ///      block 71,453,253, 24 Sep 2026). Pinned here in Solidity so a hook redeploy that introduced a
    ///      share price fails this suite rather than silently mis-valuing the book: `totalShares` is compared
    ///      against the liquidity PoolManager itself holds for `(hook, tickLower, tickUpper, salt = 0)`,
    ///      which is an entirely independent number reached through raw storage.
    function test_sharesAreUnitsOfV4Liquidity() public view {
        FablesRangeState memory st = IFablesHook(HOOK).rangeState(RANGE_ID);
        (uint128 liquidity,,) = _hookPosition();

        assertGt(st.totalShares, 0, "fixture range is empty");
        assertEq(uint256(st.totalShares), uint256(liquidity), "a share is not a unit of V4 liquidity");
        assertEq(uint256(st.totalShares), uint256(SHARES), "shares moved: re-pin the block or the number");
        assertEq(uint256(st.totalStaked), 0, "nothing is staked at this block");
        assertEq(IFablesHook(HOOK).balanceOf(SICKLE, RANGE_ID), SHARES, "the Sickle is the sole holder");
    }

    //
    // the position, valued
    //

    /// @notice The principal equals an independent recompute off the same PoolManager storage.
    /// @dev The spot price is BELOW the range at this block, so Uniswap's own math puts the whole position in
    ///      currency0 — native ether — and the USDG principal leg is legitimately absent rather than missing.
    ///      That is asserted explicitly, because "no USDG leg" is exactly what a dropped leg also looks like.
    function test_principalMatchesAnIndependentRecompute() public view {
        (uint160 sqrtPriceX96, int24 tick) = _slot0();
        assertLt(tick, TICK_LOWER, "price is below the range at this block");

        (uint256 e0, uint256 e1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(TICK_LOWER), TickMath.getSqrtRatioAtTick(TICK_UPPER), SHARES
        );
        assertGt(e0, 0, "the ETH side carries the whole position");
        assertEq(e1, 0, "and the USDG side is empty, by the price, not by a dropped leg");

        INAVCalculator.PositionBalance[] memory rows = _rows(SICKLE);
        assertEq(_amount(rows, NATIVE, PositionKind.Supplied), e0, "ETH principal");
        assertEq(_amount(rows, USDG, PositionKind.Supplied), 0, "no USDG principal");
        assertEq(_amount(rows, NATIVE, PositionKind.Staking), 0, "nothing staked");
        assertEq(_amount(rows, USDG, PositionKind.Staking), 0, "nothing staked");
    }

    /// @notice The fee legs equal the unsynced V4 backlog, recomputed independently.
    /// @dev At this block the hook has settled nothing into `owed` and the holder's checkpoints equal the
    ///      range's `accFee`, so the first two of the three fee components are zero and the whole fee leg IS
    ///      the backlog. With `totalStaked == 0` and `claimFeeRecipient() == address(0)` the backlog takes no
    ///      cut, so it reduces to the holder's share of `feeGrowthInside`-since-sync — which is what this
    ///      recomputes. The one-wei tolerance is the Q128 round trip the adapter deliberately keeps, because
    ///      the hook truncates at both of those steps and matching its rounding is the whole point.
    function test_feeLegsMatchAnIndependentBacklogRecompute() public view {
        assertEq(IFablesHook(HOOK).claimFeeRecipient(), address(0), "no claim fee is taken on this hook");
        assertEq(IFablesHook(HOOK).effectiveClaimFee(RANGE_ID), 0, "and the rate agrees");

        (uint128 liquidity, uint256 last0, uint256 last1) = _hookPosition();
        (uint256 inside0, uint256 inside1) = _feeGrowthInside();
        uint256 raw0;
        uint256 raw1;
        unchecked {
            raw0 = Math.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            raw1 = Math.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
        assertGt(raw0, 0, "the range has earned currency0 fees since its last sync");
        assertGt(raw1, 0, "and currency1 fees too");

        INAVCalculator.PositionBalance[] memory rows = _rows(SICKLE);
        assertApproxEqAbs(_amount(rows, NATIVE, PositionKind.Fees), raw0, 1, "ETH fees");
        assertApproxEqAbs(_amount(rows, USDG, PositionKind.Fees), raw1, 1, "USDG fees");
    }

    /// @notice The ETH side is reported under the ERC-7528 sentinel, never the raw zero address.
    /// @dev The family's worst measured bug, 14 Sep 2026: the raw zero made `PriceFeedLib` DROP the whole
    ///      native side of a position with no revert, no stale flag and no `stalePriceAssets` entry. This pool
    ///      is a native pool, so the mapping is exercised rather than merely present.
    function test_nativeCurrencyUsesTheSentinel() public view {
        (address c0, address c1) = meta.poolCurrencies(POOL_ID);
        assertEq(c0, NATIVE, "currency0 normalised");
        assertEq(c1, USDG, "currency1 untouched");

        INAVCalculator.PositionBalance[] memory rows = _rows(SICKLE);
        assertGt(rows.length, 0, "no rows");
        for (uint256 i; i < rows.length; ++i) {
            assertTrue(rows[i].balanceAsset.asset == NATIVE || rows[i].balanceAsset.asset == USDG, "unexpected asset");
            assertTrue(rows[i].balanceAsset.asset != address(0), "raw zero reached the NAV");
        }
        assertGt(_amount(rows, NATIVE, PositionKind.Supplied), 0, "the ETH side is actually reported");

        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(assets.length, 2);
        assertEq(assets[0], NATIVE);
        assertEq(assets[1], USDG);
    }

    //
    // the Sickle indirection
    //

    /// @notice The Avatar Safe holds nothing; its Sickle holds the range; the adapter reports it for the Safe.
    /// @dev The reason this family exists. NAVCalculator is strictly account-scoped, so an adapter that only
    ///      inspected the Safe would report ZERO for a fully deployed vault.
    function test_sickleHeldRangeIsReportedForTheAvatarSafe() public view {
        assertEq(meta.sickleOf(AVATAR), SICKLE, "both vfat directions agree at this block");
        assertEq(IFablesHook(HOOK).balanceOf(AVATAR, RANGE_ID), 0, "the Safe itself holds no shares");

        INAVCalculator.PositionBalance[] memory viaSafe = _rows(AVATAR);
        INAVCalculator.PositionBalance[] memory viaSickle = _rows(SICKLE);
        assertEq(viaSafe.length, viaSickle.length, "same rows through either door");
        assertGt(viaSafe.length, 0, "and there are rows to compare");
        for (uint256 i; i < viaSafe.length; ++i) {
            assertEq(viaSafe[i].amount, viaSickle[i].amount, "amount");
            assertEq(viaSafe[i].balanceAsset.asset, viaSickle[i].balanceAsset.asset, "asset");
            assertEq(uint8(viaSafe[i].positionKind), uint8(viaSickle[i].positionKind), "kind");
        }
    }

    //
    // identity, and agreement with the deployed build
    //

    function test_rowShapeAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory rows = _rows(SICKLE);
        assertGt(rows.length, 0, "no rows");
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].protocolBrand, ProtocolIds.FABLES, "brand");
            assertEq(rows[i].protocolId, ProtocolIds.FABLES, "id");
            assertEq(rows[i].protocolSubId, ProtocolIds.FABLES, "subId");
            assertEq(rows[i].positionId, abi.encode(POOL_ID), "positionId is abi.encode(bytes32 poolId)");
            assertEq(rows[i].positionInstanceId, bytes32(RANGE_ID), "rangeId rides in positionInstanceId");
            assertEq(rows[i].balanceAdapter, address(meta), "balanceAdapter");
            assertFalse(rows[i].isDebt);
            assertFalse(rows[i].isLocked, "withdraw auto-unstakes and carries no pause check");
        }
        assertEq(meta.protocolName(), ProtocolNames.FABLES);

        string[] memory lbl = meta.positionLabels(abi.encode(POOL_ID));
        assertEq(lbl.length, 2, "[category, leaf]");
        assertEq(lbl[0], "AMM Liquidity Pool");
        assertEq(lbl[1], "ETH/USDG", "the sentinel renders through the registered-asset record");
    }

    /// @notice This port agrees, row for row and wei for wei, with the adapter deployed on chain 4663.
    /// @dev The deployed contract is an independent build of the same valuation — different base class,
    ///      `FullMath` rather than OpenZeppelin's `Math.mulDiv`, its own vendored TickMath — so agreement
    ///      covers the liquidity conversion, the three-part fee reconstruction and the identity bytes at
    ///      once. MEASURED at this block: it returns exactly 3 rows for this Sickle on this instance.
    function test_agreesWithTheDeployedChain4663Adapter() public view {
        INAVCalculator.PositionBalance[] memory mine = _rows(SICKLE);
        INAVCalculator.PositionBalance[] memory theirs =
            ILegacyFablesAdapter(LIVE_ADAPTER).getAdapterPositionsForInstances(SICKLE, _instances(), address(0));

        assertEq(theirs.length, 3, "the deployed adapter's row count at this block");
        assertEq(mine.length, theirs.length, "row count");
        for (uint256 i; i < mine.length; ++i) {
            assertEq(mine[i].balanceAsset.asset, theirs[i].balanceAsset.asset, "asset");
            assertEq(mine[i].amount, theirs[i].amount, "amount");
            assertEq(uint8(mine[i].positionKind), uint8(theirs[i].positionKind), "kind");
            assertEq(mine[i].positionId, theirs[i].positionId, "positionId");
            assertEq(mine[i].positionInstanceId, theirs[i].positionInstanceId, "positionInstanceId");
            assertEq(mine[i].protocolSubId, theirs[i].protocolSubId, "protocolSubId");
        }
    }

    /// @notice The governed instance set on chain is what this adapter family is pointed at.
    /// @dev MEASURED 16 Oct 2026: 7 instances for the live adapter, and kRHETH's pool is one of them.
    function test_liveGovernedInstanceSet() public view {
        bytes32[] memory governed = IMetaInstances(NAV_PROXY).getMetaInstances(LIVE_ADAPTER);
        assertEq(governed.length, 7, "7 governed Fables pools at this block");
        bool found;
        for (uint256 i; i < governed.length; ++i) {
            if (governed[i] == POOL_ID) found = true;
        }
        assertTrue(found, "kRHETH's pool is governed");
    }

    //
    // the ABI drift that shaped IFablesHook
    //

    /// @notice The hooks are not one ABI, and the adapter must never call the shape that differs.
    /// @dev MEASURED 16 Oct 2026 at this block, and still true: `claimFeeBps()` answers on the SPY hook and
    ///      REVERTS on the CRCL hook, which declares `claimFeeBps(bytes32)` instead — and that hook alone
    ///      hosts four of the ten candidate pools. Calling it would price all four at ZERO with no error
    ///      anywhere, because `PriceFeedLib` reads an adapter revert as "nothing to report". If this ever
    ///      stops failing on the CRCL hook the hooks have converged and {IFablesHook}'s omission can be
    ///      revisited.
    function test_claimFeeBpsShapeDiffersAcrossHooks() public view {
        (bool spyOk,) = SPY_HOOK.staticcall(abi.encodeWithSignature("claimFeeBps()"));
        (bool crclOk,) = CRCL_HOOK.staticcall(abi.encodeWithSignature("claimFeeBps()"));
        assertTrue(spyOk, "claimFeeBps() no longer answers on the SPY hook");
        assertFalse(crclOk, "claimFeeBps() now answers on the CRCL hook: revisit IFablesHook");

        // The shape all seven hooks DO share, and the only one this adapter calls.
        assertEq(IFablesHook(SPY_HOOK).effectiveClaimFee(RANGE_ID), 0);
        assertEq(IFablesHook(HOOK).effectiveClaimFee(RANGE_ID), 0);
    }

    //
    // the pool-key registry, and the 24 Sep 2026 blinding attack
    //

    /// @notice No registered PoolKey, no rows: the adapter will not guess which hook to call.
    function test_unregisteredInstanceReportsNothing() public {
        FablesSickleRangesMetaBalanceAdapter fresh =
            new FablesSickleRangesMetaBalanceAdapter(POOL_MANAGER, LIVE_INDEX, SICKLE_FACTORY, address(balances));
        assertEq(fresh.poolHook(POOL_ID), address(0), "hook before registration");
        assertEq(
            fresh.getAdapterPositionsForInstances(SICKLE, _instances(), address(0)).length,
            0,
            "valued without a registered key"
        );

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = _key();
        fresh.registerPoolKeys(keys);
        assertEq(fresh.poolHook(POOL_ID), HOOK, "hook after registration");
        assertGt(
            fresh.getAdapterPositionsForInstances(SICKLE, _instances(), address(0)).length,
            0,
            "not valued after registration"
        );
    }

    /// @notice `learnPoolKeys` reaches the same answer from the live rangeId, without the key typed out.
    function test_learnPoolKeysFromTheLiveRange() public {
        FablesSickleRangesMetaBalanceAdapter fresh =
            new FablesSickleRangesMetaBalanceAdapter(POOL_MANAGER, LIVE_INDEX, SICKLE_FACTORY, address(balances));
        uint256[] memory ids = new uint256[](1);
        ids[0] = RANGE_ID;
        fresh.learnPoolKeys(HOOK, ids);

        assertEq(fresh.poolHook(POOL_ID), HOOK);
        (address c0, address c1) = fresh.poolCurrencies(POOL_ID);
        assertEq(c0, NATIVE);
        assertEq(c1, USDG);
    }

    /// @notice A stranger files an unprunable entry, against the LIVE index, under a hook that reverts for
    ///         the adapter. The vault's real position is still valued, row for row.
    /// @dev The regression test for the review of PR #46 (24 Sep 2026), run against the real index holding
    ///      the real vault entry. The first version walked every filed entry and called its hook, so this
    ///      dropped the Sickle's rows for every instance while `coverage()` still read healthy.
    function test_strangerFiledHookCannotHideTheVaultPosition() public {
        INAVCalculator.PositionBalance[] memory before = _rows(SICKLE);
        assertGt(before.length, 0, "the vault position is valued before");

        FablesRangeIndex index = FablesRangeIndex(LIVE_INDEX);
        MockGriefHook grief = new MockGriefHook(LIVE_INDEX, _key());
        FablesRangeIndex.Entry[] memory e = new FablesRangeIndex.Entry[](1);
        e[0] = FablesRangeIndex.Entry({hook: address(grief), rangeId: 1});
        vm.prank(makeAddr("stranger"));
        index.index(SICKLE, e);

        vm.expectRevert(
            abi.encodeWithSelector(FablesRangeIndex.EntryStillValid.selector, SICKLE, address(grief), uint256(1))
        );
        index.prune(SICKLE, e);

        INAVCalculator.PositionBalance[] memory afterGrief = _rows(SICKLE);
        assertEq(afterGrief.length, before.length, "rows changed");
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterGrief[i].amount, before[i].amount, "amount changed");
        }
        assertEq(index.indexedRangeIds(SICKLE, address(grief)).length, 1, "it IS filed, in its own bucket");
        assertEq(index.indexedRangeIds(SICKLE, HOOK).length, 1, "the governed bucket is untouched");
    }

    //
    // the registry gate, assetFilter and coverage
    //

    /// @notice One unregistered currency drops the WHOLE instance — including the native sentinel.
    /// @dev NAV values an LP from the sum of its two legs, so a half-priced LP would silently understate it.
    ///      The chain-4663 original had no such gate; this is the upstream rule, applied here.
    function test_unregisteredAssetDropsTheInstance() public {
        address[] memory usdgOnly = new address[](1);
        usdgOnly[0] = USDG;
        FablesSickleRangesMetaBalanceAdapter gated = new FablesSickleRangesMetaBalanceAdapter(
            POOL_MANAGER, LIVE_INDEX, SICKLE_FACTORY, address(_deployBalancesForAdapter(usdgOnly))
        );
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = _key();
        gated.registerPoolKeys(keys);

        assertEq(
            gated.getAdapterPositionsForInstances(SICKLE, _instances(), address(0)).length,
            0,
            "native unregistered, so neither leg is emitted"
        );
    }

    function test_assetFilter() public {
        INAVCalculator.PositionBalance[] memory onlyNative =
            meta.getAdapterPositionsForInstances(SICKLE, _instances(), NATIVE);
        assertGt(onlyNative.length, 0);
        for (uint256 i; i < onlyNative.length; ++i) {
            assertEq(onlyNative[i].balanceAsset.asset, NATIVE);
        }

        assertEq(
            meta.getAdapterPositionsForInstances(SICKLE, _instances(), makeAddr("unrelated")).length,
            0,
            "a filter naming neither currency"
        );
    }

    /// @notice {coverage} reports the live index's own two numbers for the vault's Sickle.
    /// @dev MEASURED at this block: one entry filed, and it still carries a balance. `live == filed` says
    ///      only that no filed entry has emptied — ERC-6909 has no per-holder range count anywhere on chain,
    ///      so it says nothing about a range nobody filed.
    function test_coverageOfTheVaultSickle() public view {
        (uint256 live, uint256 filed) = meta.coverage(SICKLE);
        assertEq(filed, 1, "one entry filed for the Sickle");
        assertEq(live, 1, "and it still carries a balance");
        assertEq(FablesRangeIndex(LIVE_INDEX).indexedRangeIds(SICKLE, HOOK).length, 1, "in the hook's bucket");
    }
}
