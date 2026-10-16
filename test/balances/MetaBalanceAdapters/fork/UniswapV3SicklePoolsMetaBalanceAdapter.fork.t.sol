// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    UniswapV3SicklePoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/UniswapV3SicklePoolsMetaBalanceAdapter.sol";
import {
    INonfungiblePositionManager,
    UniswapV3PoolLib
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {ISickle, ISickleFactory} from "src/balances/MetaBalanceAdapters/vfat/ISickleFactory.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal pool reads used to INDEPENDENTLY recompute the expected split/fees from the SAME on-chain state the
///      adapter reads. The recompute applies the Uniswap math itself (LiquidityAmounts + the three-way
///      feeGrowthInside formula + tokensOwed) rather than routing through `UniswapV3PoolLib.positionAmounts`, so a
///      bug in the lib's assembly of that math would be caught here. Same construction as the upstream Uniswap V3
///      fork test.
interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick)
        external
        view
        returns (uint128, int128, uint256 fgOut0, uint256 fgOut1, int56, uint160, uint32, bool);
}

/// @title UniswapV3SicklePoolsMetaBalanceForkTest
/// @notice Fork tests against Robinhood Chain (chain id 4663) and a REAL vfat Sickle: the kRHUSD Fund Avatar Safe
///         holds no Uniswap V3 NFT itself, its Sickle holds the whole book, and the adapter must report the
///         Sickle's legs when asked about the Avatar.
///
/// @dev **WHAT IS TRUE AT THE PINNED BLOCK** (all measured 16 Oct 2026 at block 90,186,157, chain head was
///      90,186,157 at the time of measurement):
///        - `SickleFactory.sickles(AVATAR) == SICKLE` and `ISickle(SICKLE).owner() == AVATAR` — the bidirectional
///          admission rule is satisfied, so the Sickle is admitted;
///        - `NPM.balanceOf(AVATAR) == 0` and `NPM.balanceOf(SICKLE) == 6` — every v3 position is behind the
///          indirection, which is exactly the shape that makes the base adapter alone report zero;
///        - of those six, tokenId 1306375 is the USDG/CRCL 0.3% position, range [230100, 232920], liquidity
///          5,996,123,152,822,473, and the pool's current tick is 231843 — **in range**, so both principal legs are
///          non-zero;
///        - `tokensOwed0 == tokensOwed1 == 0` on ALL SIX NFTs while their `feeGrowthInside*LastX128` lag the pools'
///          accumulators. These positions have never been poked, so the whole reported fee is the
///          `feeGrowthInside`-since-poke component. `test_feesAreNotTokensOwed` asserts exactly that.
contract UniswapV3SicklePoolsMetaBalanceForkTest is BalanceAdapterTestBase {
    /// @dev Chain 4663 addresses, from `ape-robinhood/ops/nav-adapters/config/rh-4663.json` (each entry there
    ///      records how it was verified on chain).
    address public constant NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address public constant SICKLE_FACTORY = 0x3575Aa02Ae85D8Cd2AaE6DCaA5D8750cFc9622e6;
    address public constant AVATAR = 0x01F18eadd996e41235A9155Ec9aF5878c6ED6294; // kRHUSD Fund Avatar Safe
    address public constant SICKLE = 0x6f94B45B68d9d446706436eB9D55E3a600a723Ba; // its vfat Sickle
    address public constant POOL = 0x654E4143e82a5824445Ade0824351C2A9ACD95a8; // USDG/CRCL 0.3%
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // token0, 6 decimals
    address public constant CRCL = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5; // token1
    uint256 public constant SICKLE_TOKEN_ID = 1_306_375;

    /// @dev Pinned at the measured head of 16 Oct 2026. Everything asserted below was read at this exact block;
    ///      a later block would re-centre the book (vfat burns and re-mints on every re-centre) and silently
    ///      change which tokenIds exist.
    uint256 public constant FORK_BLOCK = 90_186_157;

    UniswapV3SicklePoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        balances = _deployBalancesForAdapter(_assets());
        meta = new UniswapV3SicklePoolsMetaBalanceAdapter(NPM, address(balances), SICKLE_FACTORY);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("robinhood-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = USDG;
        a[1] = CRCL;
    }

    function _poolInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(POOL)));
    }

    function _read(address account) internal view returns (INAVCalculator.PositionBalance[] memory) {
        return meta.getAdapterPositionsForInstances(account, _poolInstance(), address(0));
    }

    /// @notice The ground truth this whole file rests on: the indirection is real and the admission rule accepts it.
    function test_sickleIndirection_isRealAndAdmitted() public view {
        assertEq(ISickleFactory(SICKLE_FACTORY).sickles(AVATAR), SICKLE, "forward map");
        assertEq(ISickle(SICKLE).owner(), AVATAR, "reverse attestation");
        assertEq(meta.sickleOf(AVATAR), SICKLE, "admitted on both directions agreeing");

        assertEq(INonfungiblePositionManager(NPM).balanceOf(AVATAR), 0, "the Avatar holds no NFT itself");
        assertGt(INonfungiblePositionManager(NPM).balanceOf(SICKLE), 0, "the Sickle holds the book");
    }

    /// @notice The account-scoped read sees the Sickle's legs. The base adapter alone would report nothing here,
    ///         because the Avatar's own NPM balance is zero.
    function test_accountScopedRead_seesTheSicklesLegs() public view {
        INAVCalculator.PositionBalance[] memory p = _read(AVATAR);
        assertEq(p.length, 4, "one in-range, never-poked NFT: 2 Supplied + 2 Fees");

        // Asking about the Sickle directly must give the identical answer (it is its own holder).
        INAVCalculator.PositionBalance[] memory q = _read(SICKLE);
        assertEq(q.length, p.length, "same legs whichever end of the indirection is queried");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].amount, q[i].amount);
            assertEq(p[i].balanceAsset.asset, q[i].balanceAsset.asset);
        }
    }

    /// @notice Identity on live legs: positionId is the pool, the NFT id rides in positionInstanceId.
    function test_identityOnLiveLegs() public view {
        INAVCalculator.PositionBalance[] memory p = _read(AVATAR);
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(abi.decode(p[i].positionId, (address)), POOL, "positionId = the governed pool");
            assertEq(p[i].positionInstanceId, bytes32(SICKLE_TOKEN_ID), "the Sickle's USDG/CRCL NFT");
            assertEq(p[i].balanceAdapter, address(meta));
            assertFalse(p[i].isDebt);
            assertFalse(p[i].isLocked);
        }
        string[] memory lbl = meta.positionLabels(p[0].positionId);
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "AMM Liquidity Pool");
        assertEq(lbl[1], "USDG/CRCL 0.3%");
    }

    /// @notice FEES ARE NOT `tokensOwed`. The Sickle's position has never been poked — `tokensOwed0` and
    ///         `tokensOwed1` are both zero on chain at this block — yet both Fees legs are non-zero, because the
    ///         whole accrual lives in `feeGrowthInside`. An adapter that reported `tokensOwed` would report zero.
    function test_feesAreNotTokensOwed() public view {
        UniswapV3PoolLib.Position memory pos = UniswapV3PoolLib.readPosition(NPM, SICKLE_TOKEN_ID);
        assertEq(pos.tokensOwed0, 0, "never poked");
        assertEq(pos.tokensOwed1, 0, "never poked");

        (uint256 feeUsdg, uint256 feeCrcl) = _adapterFees();
        assertGt(feeUsdg + feeCrcl, 0, "real fee income is reported despite tokensOwed being zero");
    }

    /// @notice Independent ground truth: recompute the in-range split and the full unclaimed fees off the same
    ///         on-chain state, applying the Uniswap math inline rather than through `UniswapV3PoolLib`.
    function test_amountsMatchIndependentRecompute() public view {
        (uint256 liqUsdg, uint256 liqCrcl) = _adapterPrincipal();
        (uint256 feeUsdg, uint256 feeCrcl) = _adapterFees();

        (uint256 e0, uint256 e1, uint256 f0, uint256 f1) = _recomputeInline();

        // Pool token0 = USDG, token1 = CRCL (sorted by address, measured at the pinned block).
        assertEq(IPool(POOL).token0(), USDG, "token0 = USDG");
        assertEq(IPool(POOL).token1(), CRCL, "token1 = CRCL");

        assertEq(liqUsdg, e0, "USDG principal == independent inline recompute");
        assertEq(liqCrcl, e1, "CRCL principal == independent inline recompute");
        assertEq(feeUsdg, f0, "USDG fee == independent inline recompute");
        assertEq(feeCrcl, f1, "CRCL fee == independent inline recompute");

        // The position is in range at this block, so BOTH principal legs are live, not just one side.
        assertGt(e0, 0, "USDG principal is non-zero (position in range)");
        assertGt(e1, 0, "CRCL principal is non-zero (position in range)");
    }

    /// @notice Both pool tokens must be registered or the whole instance is dropped — through the Sickle path too.
    ///         (The 4663 original had no registry gate at all.)
    function test_unregisteredToken_dropsTheInstance() public {
        address[] memory onlyUsdg = new address[](1);
        onlyUsdg[0] = USDG;
        UniswapV3SicklePoolsMetaBalanceAdapter half = new UniswapV3SicklePoolsMetaBalanceAdapter(
            NPM, address(_deployBalancesForAdapter(onlyUsdg)), SICKLE_FACTORY
        );
        assertEq(
            half.getAdapterPositionsForInstances(AVATAR, _poolInstance(), address(0)).length,
            0,
            "CRCL unregistered: the whole instance is dropped"
        );
    }

    function _adapterPrincipal() internal view returns (uint256 usdg, uint256 crcl) {
        INAVCalculator.PositionBalance[] memory p = _read(AVATAR);
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind != PositionKind.Supplied) continue;
            if (p[i].balanceAsset.asset == USDG) usdg += p[i].amount;
            else if (p[i].balanceAsset.asset == CRCL) crcl += p[i].amount;
        }
    }

    function _adapterFees() internal view returns (uint256 usdg, uint256 crcl) {
        INAVCalculator.PositionBalance[] memory p = _read(AVATAR);
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind != PositionKind.Fees) continue;
            if (p[i].balanceAsset.asset == USDG) usdg += p[i].amount;
            else if (p[i].balanceAsset.asset == CRCL) crcl += p[i].amount;
        }
    }

    /// @dev Walks the SICKLE's NFTs (the holder the mixin resolves to) and sums the USDG/CRCL ones. Kept as a thin
    ///      outer loop so each frame stays inside the stack window, exactly as the upstream V3 fork test does.
    function _recomputeInline() internal view returns (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) {
        (uint160 sp, int24 tickCurrent,,,,,) = IPool(POOL).slot0();
        uint256 bal = INonfungiblePositionManager(NPM).balanceOf(SICKLE);
        uint256 max = bal > meta.MAX_POSITIONS() ? meta.MAX_POSITIONS() : bal;
        for (uint256 i = 0; i < max; i++) {
            uint256 tokenId = INonfungiblePositionManager(NPM).tokenOfOwnerByIndex(SICKLE, i);
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = _recomputeOne(tokenId, sp, tickCurrent);
            liq0 += a0;
            liq1 += a1;
            fee0 += f0;
            fee1 += f1;
        }
    }

    /// @dev INDEPENDENT per-NFT recompute: a plain `positions()` read, the pool-triple filter, then
    ///      `LiquidityAmounts.getAmountsForLiquidity` and `_inlineFees` — never `UniswapV3PoolLib.positionAmounts`.
    function _recomputeOne(uint256 tokenId, uint160 sp, int24 tickCurrent)
        internal
        view
        returns (uint256 a0, uint256 a1, uint256 f0, uint256 f1)
    {
        UniswapV3PoolLib.Position memory p = UniswapV3PoolLib.readPosition(NPM, tokenId);
        if (p.token0 != IPool(POOL).token0() || p.token1 != IPool(POOL).token1() || p.fee != IPool(POOL).fee()) {
            return (0, 0, 0, 0);
        }
        if (p.liquidity == 0) {
            return (0, 0, p.tokensOwed0, p.tokensOwed1);
        }
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sp, TickMath.getSqrtRatioAtTick(p.tickLower), TickMath.getSqrtRatioAtTick(p.tickUpper), p.liquidity
        );
        (f0, f1) = _inlineFees(p, tickCurrent);
    }

    /// @dev Full unclaimed fee = (feeGrowthInside − feeGrowthInsideLast) · liquidity / 2^128 + tokensOwed, with the
    ///      three-way `feeGrowthInside` formula applied under `unchecked` (v3 fee accounting wraps).
    function _inlineFees(UniswapV3PoolLib.Position memory p, int24 tickCurrent)
        internal
        view
        returns (uint256 f0, uint256 f1)
    {
        uint256 fgGlobal0 = IPool(POOL).feeGrowthGlobal0X128();
        uint256 fgGlobal1 = IPool(POOL).feeGrowthGlobal1X128();
        (,, uint256 fgOutLower0, uint256 fgOutLower1,,,,) = IPool(POOL).ticks(p.tickLower);
        (,, uint256 fgOutUpper0, uint256 fgOutUpper1,,,,) = IPool(POOL).ticks(p.tickUpper);

        unchecked {
            uint256 fgInside0;
            uint256 fgInside1;
            if (tickCurrent < p.tickLower) {
                fgInside0 = fgOutLower0 - fgOutUpper0;
                fgInside1 = fgOutLower1 - fgOutUpper1;
            } else if (tickCurrent < p.tickUpper) {
                fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
                fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
            } else {
                fgInside0 = fgOutUpper0 - fgOutLower0;
                fgInside1 = fgOutUpper1 - fgOutLower1;
            }
            f0 = Math.mulDiv(fgInside0 - p.feeGrowthInside0LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed0;
            f1 = Math.mulDiv(fgInside1 - p.feeGrowthInside1LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed1;
        }
    }
}
