// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    UniswapV4SicklePoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/UniswapV4SicklePoolsMetaBalanceAdapter.sol";
import {V4PositionIndex} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4PositionIndex.sol";
import {IExtsload, IV4PositionManager, PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title UniswapV4SicklePoolsMetaBalanceForkTest
/// @notice Fork tests against the live Uniswap V4 deployment on Robinhood Chain (chain id 4663) and the real vfat
///         Sickles of two production vaults. Nothing here is mocked: the PositionManager, the PoolManager singleton,
///         the SickleFactory and the {V4PositionIndex} are the deployed ones, and the holders are the Sickles the
///         vaults' books actually sit behind.
///
/// @dev **What is true at {FORK_BLOCK} = 90,186,157** (all measured, 16 Oct 2026; chain head was 90,186,157 when
///      these fixtures were read):
///        - `SICKLE_FACTORY.sickles(USD_SAFE) == USD_SICKLE` and `ISickle(USD_SICKLE).owner() == USD_SAFE`, so the
///          bidirectional admission check in {SickleHeldPositions} passes for this pair.
///        - `POSITION_MANAGER.balanceOf(USD_SICKLE) == 8`.
///        - The live index has **20 ids filed** for that Sickle of which **8 are still owned** — i.e. twelve dead
///          entries sit right next to full coverage, so the stale-entry skip is exercised against real rot rather
///          than a constructed one.
///        - Two of the eight, 3214040 and 3270386, are in the SAME pool, USDG/META 0.3% tickSpacing 60, pool id
///          `0x5875d407…ae36`. `getPositionLiquidity(3214040)` is 653246746695797.
///        - The kRHETH Sickle holds 3 positions, of which 3271380 is in the **native** ETH/USDG 0.3% pool
///          `0xd313d79d…0cf8` whose `currency0` is `address(0)` — the case that made 1,660 USDG of ether vanish
///          from the NAV in Sep 2026 and the reason {_asNavAsset} exists.
///
/// @dev Method: expected amounts are recomputed INLINE from the same chain state, through the SINGLE-slot `extsload`
///      overload and a locally re-derived slot layout, never through {V4StateLibrary}. A bug in the library's slot
///      derivation or in its batching therefore fails this suite instead of being confirmed by it.
contract UniswapV4SicklePoolsMetaBalanceForkTest is BalanceAdapterTestBase {
    uint256 public constant FORK_BLOCK = 90_186_157;

    address public constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant SICKLE_FACTORY = 0x3575Aa02Ae85D8Cd2AaE6DCaA5D8750cFc9622e6;
    /// @notice The {V4PositionIndex} already deployed on 4663; it carries both vaults' filed ids.
    address public constant LIVE_INDEX = 0x025e980Ad119Db4656DFdeF6C5B170eA51A5D301;

    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice kRHUSD: the portfolio Safe the NAV is asked about, and the Sickle its book sits behind.
    address public constant USD_SAFE = 0x01F18eadd996e41235A9155Ec9aF5878c6ED6294;
    address public constant USD_SICKLE = 0x6f94B45B68d9d446706436eB9D55E3a600a723Ba;
    /// @notice kRHETH: the vault that holds the native-ether pool.
    address public constant ETH_SAFE = 0x2EeB414D0bc548094a574E6801f5365498D28aa4;
    address public constant ETH_SICKLE = 0x744b5597203E2a49169c2E49Bc671A065Ec6cac6;

    /// @notice USDG/META 0.3%, tickSpacing 60, no hooks.
    bytes32 public constant META_POOL = 0x5875d407a42965b0e768c8925cea290e06fa50603ef34fc99eb92a1050e6ae36;
    /// @notice ETH/USDG 0.3%, tickSpacing 60, no hooks. `currency0` is NATIVE ether, not WETH.
    bytes32 public constant NATIVE_POOL = 0xd313d79d9d6a714e7bdf02fc42a2c27ede7e51928ffd605126fe9e1192630cf8;

    uint256 public constant META_TOKEN_A = 3214040;
    uint256 public constant META_TOKEN_B = 3270386;
    uint256 public constant NATIVE_TOKEN = 3271380;

    /// @dev `PoolManager._pools`, and the three mapping offsets inside `Pool.State`. Re-stated here rather than
    ///      imported so this suite is an independent witness to the layout {V4StateLibrary} assumes.
    uint256 private constant POOLS_SLOT = 6;
    uint256 private constant TICKS_OFFSET = 4;
    uint256 private constant POSITIONS_OFFSET = 6;

    UniswapV4SicklePoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(_assets());
        // The native sentinel is code-less, so the generic helper cannot read a symbol for it; the NAV supplies one
        // from `_nativeTokenSymbol` in production and the harness is told it here.
        balances.registerAssetForTest(NATIVE, 18, "ETH");
        meta = new UniswapV4SicklePoolsMetaBalanceAdapter(
            POSITION_MANAGER, POOL_MANAGER, LIVE_INDEX, address(balances), SICKLE_FACTORY
        );
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("robinhood-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = USDG;
        a[1] = META;
    }

    function _one(bytes32 instance) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = instance;
    }

    function _positions(address account, bytes32 instance, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return meta.getAdapterPositionsForInstances(account, _one(instance), assetFilter);
    }

    //
    // Premises
    //

    /// @notice The fact the whole V4 design rests on: the PositionManager cannot be enumerated on chain.
    function test_positionManagerIsNotEnumerable() public {
        (bool ok,) = POSITION_MANAGER.staticcall(
            abi.encodeWithSignature("tokenOfOwnerByIndex(address,uint256)", USD_SICKLE, uint256(0))
        );
        assertFalse(ok, "Solmate ERC721, no enumeration extension: hence V4PositionIndex");
        assertEq(IV4PositionManager(POSITION_MANAGER).balanceOf(USD_SICKLE), 8, "but balanceOf works");
    }

    /// @notice The Sickle indirection, in both directions, against the real vfat contracts.
    function test_sickleResolutionAgreesBothWays() public view {
        assertEq(meta.sickleOf(USD_SAFE), USD_SICKLE);
        assertEq(meta.sickleOf(ETH_SAFE), ETH_SICKLE);
        assertEq(meta.sickleOf(USD_SICKLE), address(0), "a Sickle is its own holder and has no Sickle");
    }

    //
    // The index is a hint, and a rotten one here
    //

    function test_coverageIsCompleteAtThisBlock() public view {
        (uint256 live, uint256 held) = meta.coverage(USD_SICKLE);
        assertEq(held, 8, "every V4 position the Sickle holds");
        assertEq(live, 8, "all of them filed: the index is not behind at this block");
    }

    /// @notice Twelve of the twenty filed ids are dead, and not one of them reaches a leg.
    function test_staleFiledEntriesAreSkipped() public view {
        V4PositionIndex idx = V4PositionIndex(LIVE_INDEX);
        uint256[] memory filed = idx.indexedTokenIds(USD_SICKLE);
        uint256[] memory live = idx.liveTokenIds(USD_SICKLE);
        assertEq(filed.length, 20, "real accumulated rot, not a constructed fixture");
        assertEq(live.length, 8);

        INAVCalculator.PositionBalance[] memory p = _positions(USD_SAFE, META_POOL, address(0));
        assertGt(p.length, 0);
        for (uint256 i; i < p.length; ++i) {
            bool isLive;
            for (uint256 j; j < live.length; ++j) {
                if (p[i].positionInstanceId == bytes32(live[j])) isLive = true;
            }
            assertTrue(isLive, "every valued position is one the PositionManager still attributes to the holder");
        }
    }

    //
    // Identity
    //

    function test_identityAndPositionIdBytes() public view {
        INAVCalculator.PositionBalance[] memory p = _positions(USD_SAFE, META_POOL, address(0));
        assertGt(p.length, 0);
        bool sawA;
        bool sawB;
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionId, abi.encode(META_POOL), "positionId = abi.encode(bytes32 poolId)");
            assertEq(p[i].protocolBrand, ProtocolIds.UNISWAP);
            assertEq(p[i].protocolId, ProtocolIds.UNISWAP_V4);
            assertEq(p[i].protocolSubId, ProtocolIds.UNISWAP_V4);
            assertFalse(p[i].isLocked);
            assertFalse(p[i].isDebt);
            assertGt(p[i].amount, 0, "zero amounts are not rows");
            if (p[i].positionInstanceId == bytes32(META_TOKEN_A)) sawA = true;
            if (p[i].positionInstanceId == bytes32(META_TOKEN_B)) sawB = true;
        }
        assertTrue(sawA, "tokenId 3214040 is valued");
        assertTrue(sawB, "tokenId 3270386 is valued, under the same positionId");
    }

    /// @notice The adapter is asked about the SAFE and answers with the SICKLE's book. That is the whole point.
    function test_queryingTheSafeReportsTheSicklesBook() public view {
        assertEq(IV4PositionManager(POSITION_MANAGER).balanceOf(USD_SAFE), 0, "the Safe holds no NFTs itself");
        assertGt(_positions(USD_SAFE, META_POOL, address(0)).length, 0, "yet its NAV sees the pool");
    }

    //
    // Valuation
    //

    /// @notice The slot derivation claim in {V4StateLibrary}'s header, checked against the PositionManager's own
    ///         answer: the position slot this layout points at holds exactly `getPositionLiquidity`'s number.
    function test_positionSlotHoldsTheSameLiquidityThePositionManagerReports() public view {
        (uint128 liquidity,,,) = _positionState(META_TOKEN_A);
        assertEq(liquidity, IV4PositionManager(POSITION_MANAGER).getPositionLiquidity(META_TOKEN_A));
        assertEq(uint256(liquidity), 653246746695797, "measured at block 90,186,157");
    }

    /// @notice Independent ground truth for the whole instance: principal split and full unclaimed fees, recomputed
    ///         inline from single-slot `extsload` reads, summed over both of the Sickle's positions in this pool.
    function test_amountsMatchAnIndependentRecompute() public view {
        uint256 expectedUsdg;
        uint256 expectedMeta;
        uint256 expectedFeeUsdg;
        uint256 expectedFeeMeta;
        // Both fixtures really are two positions of the SAME pool, which is what makes the sum below meaningful.
        (PoolKey memory kA,) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(META_TOKEN_A);
        (PoolKey memory kB,) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(META_TOKEN_B);
        assertEq(keccak256(abi.encode(kA)), META_POOL);
        assertEq(keccak256(abi.encode(kB)), META_POOL);
        assertEq(IV4PositionManager(POSITION_MANAGER).ownerOf(META_TOKEN_A), USD_SICKLE);
        assertEq(IV4PositionManager(POSITION_MANAGER).ownerOf(META_TOKEN_B), USD_SICKLE);

        {
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = _recompute(META_TOKEN_A);
            (uint256 b0, uint256 b1, uint256 g0, uint256 g1) = _recompute(META_TOKEN_B);
            expectedUsdg = a0 + b0;
            expectedMeta = a1 + b1;
            expectedFeeUsdg = f0 + g0;
            expectedFeeMeta = f1 + g1;
        }
        assertTrue(expectedUsdg > 0 || expectedMeta > 0, "the Sickle has live liquidity in this pool");
        assertGt(
            expectedFeeUsdg + expectedFeeMeta,
            0,
            "and accrued fees, so the fee branch is genuinely exercised rather than trivially zero"
        );

        uint256 usdgSup;
        uint256 metaSup;
        uint256 usdgFee;
        uint256 metaFee;
        INAVCalculator.PositionBalance[] memory p = _positions(USD_SAFE, META_POOL, address(0));
        for (uint256 i; i < p.length; ++i) {
            bool isFee = p[i].positionKind == PositionKind.Fees;
            if (p[i].balanceAsset.asset == USDG) {
                if (isFee) usdgFee += p[i].amount;
                else usdgSup += p[i].amount;
            } else if (p[i].balanceAsset.asset == META) {
                if (isFee) metaFee += p[i].amount;
                else metaSup += p[i].amount;
            } else {
                revert("unexpected asset in a USDG/META pool");
            }
        }

        assertEq(usdgSup, expectedUsdg, "USDG principal == independent inline recompute");
        assertEq(metaSup, expectedMeta, "META principal == independent inline recompute");
        assertEq(usdgFee, expectedFeeUsdg, "USDG fees == feeGrowthInside-derived recompute");
        assertEq(metaFee, expectedFeeMeta, "META fees == feeGrowthInside-derived recompute");
    }

    //
    // Native ether
    //

    /// @notice The adapter's sentinel is the same ERC-7528 literal the live NAV declares and registers, so the two
    ///         cannot disagree about what native ether is called.
    function test_nativeSentinelMatchesTheNav() public view {
        assertEq(meta.NATIVE_ADDRESS(), balances.NATIVE_ADDRESS());
        assertEq(meta.NATIVE_ADDRESS(), NATIVE);
    }

    /// @notice The live native pool: `currency0` is literally `address(0)` on chain, and the leg that reaches the
    ///         NAV must be the sentinel instead. Emitting the raw zero is what silently deleted the ether side of a
    ///         position from `getAccountNav` in Sep 2026.
    function test_nativePoolLegIsTheSentinelNotTheRawZero() public view {
        (PoolKey memory key,) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(NATIVE_TOKEN);
        assertEq(key.currency0, address(0), "the chain really does say zero here");
        assertEq(key.currency1, USDG);
        assertEq(keccak256(abi.encode(key)), NATIVE_POOL, "and that key hashes to the governed instance");

        INAVCalculator.PositionBalance[] memory p = _positions(ETH_SAFE, NATIVE_POOL, address(0));
        assertGt(p.length, 0, "the kRHETH Sickle holds a position in it");
        bool sawNative;
        for (uint256 i; i < p.length; ++i) {
            assertTrue(p[i].balanceAsset.asset != address(0), "a zero-address leg would be dropped unpriced");
            if (p[i].balanceAsset.asset == NATIVE) {
                sawNative = true;
                assertEq(p[i].balanceAsset.symbol, "ETH", "metadata comes from the NAV's native record");
                assertEq(p[i].balanceAsset.decimals, 18);
            }
        }
        assertTrue(sawNative, "the ether side of the position is reported");
    }

    //
    // Gates
    //

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory all = _positions(USD_SAFE, META_POOL, address(0));
        INAVCalculator.PositionBalance[] memory onlyUsdg = _positions(USD_SAFE, META_POOL, USDG);
        assertGt(onlyUsdg.length, 0);
        assertLt(onlyUsdg.length, all.length, "the filter drops the other currency's legs");
        for (uint256 i; i < onlyUsdg.length; ++i) {
            assertEq(onlyUsdg[i].balanceAsset.asset, USDG);
        }
        assertEq(_positions(USD_SAFE, META_POOL, address(this)).length, 0, "a filter matching neither currency");
    }

    /// @notice An unregistered currency drops the position whole: this harness registers only USDG and META, and the
    ///         Sickle's other six live positions are in pools whose second currency it has never heard of.
    function test_unregisteredCurrencyDropsTheInstance() public view {
        // USDG / 0xa30FA36D… 0.12%, tickSpacing 15 — tokenId 3270258, live, and unpriceable here.
        PoolKey memory key = PoolKey(USDG, 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344, 1200, 15, address(0));
        bytes32 poolId = keccak256(abi.encode(key));
        (PoolKey memory onChain,) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(3270258);
        assertEq(keccak256(abi.encode(onChain)), poolId, "the fixture names a pool that really exists");
        assertEq(IV4PositionManager(POSITION_MANAGER).ownerOf(3270258), USD_SICKLE, "and that the Sickle holds");

        assertEq(_positions(USD_SAFE, poolId, address(0)).length, 0, "both currencies registered, or nothing");
    }

    function test_unconfiguredInstanceAndEmptyAccount() public {
        assertEq(_positions(USD_SAFE, keccak256("no such v4 pool"), address(0)).length, 0);
        assertEq(_positions(makeAddr("nobody"), META_POOL, address(0)).length, 0);
    }

    //
    // Description
    //

    function test_instanceAssetsAndLabelsAfterRegisteringTheRealKeys() public {
        PoolKey[] memory keys = new PoolKey[](2);
        (keys[0],) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(META_TOKEN_A);
        (keys[1],) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(NATIVE_TOKEN);
        meta.registerPoolKeys(keys);

        address[] memory assets = meta.underlyingAssetsSupportedForInstances(_one(META_POOL));
        assertEq(assets.length, 2);
        assertEq(assets[0], USDG);
        assertEq(assets[1], META);

        string[] memory lbl = meta.positionLabels(abi.encode(META_POOL));
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "AMM Liquidity Pool");
        assertEq(lbl[1], "USDG/META");

        string[] memory nativeLbl = meta.positionLabels(abi.encode(NATIVE_POOL));
        assertEq(nativeLbl[1], "ETH/USDG", "the sentinel's symbol is only knowable from the NAV record");

        (address c0,) = meta.poolCurrencies(NATIVE_POOL);
        assertEq(c0, NATIVE, "currency0 is normalised on the way into the map too");
    }

    //
    // Independent recompute helpers (deliberately NOT using V4StateLibrary)
    //

    function _poolStateSlot(bytes32 poolId) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(poolId, bytes32(POOLS_SLOT))));
    }

    function _load(uint256 slot) private view returns (uint256) {
        return uint256(IExtsload(POOL_MANAGER).extsload(bytes32(slot)));
    }

    function _ticksOf(uint256 info) private pure returns (int24 lower, int24 upper) {
        lower = int24(uint24(info >> 8));
        upper = int24(uint24(info >> 32));
    }

    /// @dev `(liquidity, feeGrowthInside0Last, feeGrowthInside1Last, poolStateSlot)` straight out of storage.
    function _positionState(uint256 tokenId)
        private
        view
        returns (uint128 liquidity, uint256 last0, uint256 last1, uint256 stateSlot)
    {
        (PoolKey memory key, uint256 info) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
        (int24 lower, int24 upper) = _ticksOf(info);
        stateSlot = _poolStateSlot(keccak256(abi.encode(key)));
        bytes32 posKey = keccak256(abi.encodePacked(POSITION_MANAGER, lower, upper, bytes32(tokenId)));
        uint256 posSlot = uint256(keccak256(abi.encodePacked(posKey, bytes32(stateSlot + POSITIONS_OFFSET))));
        liquidity = uint128(_load(posSlot));
        last0 = _load(posSlot + 1);
        last1 = _load(posSlot + 2);
    }

    function _feeGrowthOutside(uint256 stateSlot, int24 tick) private view returns (uint256 f0, uint256 f1) {
        uint256 base = uint256(keccak256(abi.encodePacked(int256(tick), bytes32(stateSlot + TICKS_OFFSET))));
        f0 = _load(base + 1);
        f1 = _load(base + 2);
    }

    /// @dev One position's expected four amounts, from storage the adapter's library never touched.
    function _recompute(uint256 tokenId)
        private
        view
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
    {
        (, uint256 info) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
        (int24 lower, int24 upper) = _ticksOf(info);
        (uint128 liquidity, uint256 last0, uint256 last1, uint256 stateSlot) = _positionState(tokenId);

        uint256 slot0 = _load(stateSlot);
        uint160 sqrtPriceX96 = uint160(slot0);
        int24 tickCurrent = int24(uint24(slot0 >> 160));

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            IV4PositionManager(POSITION_MANAGER).getPositionLiquidity(tokenId)
        );

        (uint256 lo0, uint256 lo1) = _feeGrowthOutside(stateSlot, lower);
        (uint256 up0, uint256 up1) = _feeGrowthOutside(stateSlot, upper);
        uint256 inside0;
        uint256 inside1;
        unchecked {
            if (tickCurrent < lower) {
                inside0 = lo0 - up0;
                inside1 = lo1 - up1;
            } else if (tickCurrent >= upper) {
                inside0 = up0 - lo0;
                inside1 = up1 - lo1;
            } else {
                inside0 = _load(stateSlot + 1) - lo0 - up0;
                inside1 = _load(stateSlot + 2) - lo1 - up1;
            }
            fee0 = liquidity == 0 ? 0 : Math.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fee1 = liquidity == 0 ? 0 : Math.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }
}
