// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    PancakeSwapV3PoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/PancakeSwapV3PoolsAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal PancakeSwap V3 NonfungiblePositionManager interface for id discovery + the ground-truth check.
interface IPancakeNPM {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @title PancakeSwapV3PoolsAssistedBalanceForkTest (mainnet, active positions)
/// @notice Verifies the PancakeSwap V3 pools assisted adapter against a real mainnet holder with an active in-wallet
///         (liquidity > 0) position. PancakeSwap V3 is a byte-for-byte Uniswap V3 fork; since ADR 0017 the adapter
///         values each position from the pool's live `slot0` (instantaneous on-chain amounts). PancakeSwap V3's
///         `slot0().feeProtocol` is `uint32` (Uniswap packs it as `uint8`), so this fork genuinely exercises the
///         PancakeSwap `_slot0` override against a real PCS V3 pool — a position is valued here without reverting,
///         which the inherited `uint8` decode could not do. All other valuation math is inherited from the verified
///         UniswapV3PoolsAssistedBalanceAdapter. The holder's WETH/USDT 0.05% NFT tokenIds are discovered off the NPM and
///         fed to the adapter via `submitTokenIds` (as the off-chain assistant would).
///
///         The ground-truth test burns each position's liquidity via the real NPM and asserts the adapter's reported
///         principal == the protocol's own settlement amounts — same NPM, same `slot0`, same archive state, same EVM.
contract PancakeSwapV3PoolsAssistedBalanceForkTest is BalanceAdapterTestBase {
    address public constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant HOLDER = 0x783C3255340f8Ba524452A9BE5d12a77e9Ce1F53;
    uint24 public constant POOL_FEE = 500; // WETH/USDT 0.05%
    address public constant POOL = 0x6CA298D2983aB03Aa1dA7679389D955A4eFEE15C; // WETH/USDT 0.05% (the holder's pool)
    // Selected block — same block the dev-anvil dashboard pins at (script/development/test/pancakeswapV3/README.md).
    // HOLDER has at least one active (liquidity > 0) WETH/USDT 0.05% position here.
    uint256 public constant FORK_BLOCK = 25_274_483;

    PancakeSwapV3PoolsAssistedBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp(); // dispatches to the _setupFork() override below — no need to call it again
        balances = _deployBalancesForAdapter(_assets());
        // admin + assistant = this test, so it can submit the holder's tokenIds.
        adapter = new PancakeSwapV3PoolsAssistedBalanceAdapter(
            NPM, "PancakeSwap V3", address(balances), address(this), address(this)
        );
        _submitHolderPoolTokenIds();
    }

    /// @notice Discover the holder's WETH/USDT 0.05% NFT tokenIds off the NPM and submit them, mirroring the
    ///         off-chain assistant. Restricting to the target pool keeps the ground-truth settlement comparison
    ///         exact (the adapter values every submitted NFT whose tokens are registered, regardless of pool).
    function _submitHolderPoolTokenIds() internal {
        uint256[] memory ids = _holderPoolTokenIds();
        if (ids.length > 0) adapter.submitTokenIds(HOLDER, ids);
    }

    /// @dev The holder's NFT tokenIds in the WETH/USDT 0.05% pool (any liquidity).
    function _holderPoolTokenIds() internal view returns (uint256[] memory ids) {
        uint256 n = IPancakeNPM(NPM).balanceOf(HOLDER);
        uint256[] memory tmp = new uint256[](n);
        uint256 c;
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = IPancakeNPM(NPM).tokenOfOwnerByIndex(HOLDER, i);
            (,, address t0, address t1, uint24 fee,,,,,,,) = IPancakeNPM(NPM).positions(tokenId);
            bool isPool = fee == POOL_FEE && (t0 == WETH || t0 == USDT) && (t1 == WETH || t1 == USDT);
            if (isPool) tmp[c++] = tokenId;
        }
        ids = new uint256[](c);
        for (uint256 i = 0; i < c; i++) {
            ids[i] = tmp[i];
        }
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = WETH;
        a[1] = USDT;
    }

    /// @dev Sum amounts for a token from a pre-fetched position set, optionally restricted to one PositionKind
    ///      (Supplied = principal). Callers fetch positions once and reuse, avoiding repeat adapter queries.
    function _sumFrom(INAVCalculator.PositionBalance[] memory p, address token, bool onlyPrincipal)
        internal
        pure
        returns (uint256 sum)
    {
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset != token) continue;
            if (onlyPrincipal && p[i].positionKind != PositionKind.Supplied) continue;
            sum += p[i].amount;
        }
    }

    /// @notice An active position yields non-zero principal on both tokens (the split is driven by the pool's live
    ///         `slot0` `sqrtPriceX96` feeding `getAmountsForLiquidity`). Valuing it at all requires the PancakeSwap
    ///         `_slot0` override to decode the real pool's `uint32 feeProtocol` without reverting.
    function test_activePositionNonZero() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertGt(_sumFrom(p, WETH, false), 0, "WETH total should be non-zero for active positions");
        assertGt(_sumFrom(p, USDT, false), 0, "USDT total should be non-zero for active positions");
        assertGt(_sumFrom(p, WETH, true), 0, "WETH principal should be non-zero");
        assertGt(_sumFrom(p, USDT, true), 0, "USDT principal should be non-zero");
    }

    /// @notice Identity is derived on-chain: positionId = the pool address; NFT id in positionInstanceId; slug = pancakeswap-v3.
    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertGt(p.length, 0, "expected at least one leg");
        for (uint256 i = 0; i < p.length; i++) {
            address pool = abi.decode(p[i].positionId, (address));
            assertTrue(pool != address(0), "positionId = non-zero pool address");
            assertGt(pool.code.length, 0, "positionId resolves to a deployed pool");
            string[] memory lbl = adapter.positionLabels(p[i].positionId);
            assertEq(lbl.length, 2, "static breadcrumb = [category, pool]");
            assertTrue(p[i].positionInstanceId != bytes32(0), "NFT id rides in positionInstanceId");
            assertEq(p[i].protocolSubId, ProtocolIds.PANCAKESWAP_V3, "protocolId = pancakeswap-v3");
            assertEq(p[i].protocolId, ProtocolIds.PANCAKESWAP_V3);
        }
    }

    /// @notice Ground truth: the adapter's reported Supplied principal == the protocol's own settlement.
    ///         Burning each NFT's liquidity via the real NPM returns (amount0, amount1) = the principal the holder
    ///         would receive at the pool's current `slot0` price. ADR 0017: the adapter values the split at the SAME
    ///         live `slot0` `sqrtPriceX96` (no oracle reconstruction), so the two now agree to within 1 wei rounding.
    function test_groundTruth_principalEqualsNpmSettlement() public {
        // Adapter's principal BEFORE mutating state (fetch once, reuse for both tokens).
        INAVCalculator.PositionBalance[] memory adapterPositions = adapter.getAdapterPositions(HOLDER, address(0));
        uint256 adapterWeth = _sumFrom(adapterPositions, WETH, true);
        uint256 adapterUsdt = _sumFrom(adapterPositions, USDT, true);

        // Burn the same WETH/USDT 0.05% positions that were submitted, summing the protocol's settlement amounts.
        uint256[] memory ids = _holderPoolTokenIds();
        uint256 settledWeth;
        uint256 settledUsdt;
        uint256 active;
        for (uint256 i = 0; i < ids.length; i++) {
            (,, address t0, address t1,,,, uint128 liquidity,,,,) = IPancakeNPM(NPM).positions(ids[i]);
            if (liquidity == 0) continue;
            active++;

            IPancakeNPM.DecreaseLiquidityParams memory params = IPancakeNPM.DecreaseLiquidityParams({
                tokenId: ids[i], liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });
            vm.prank(HOLDER);
            (uint256 amount0, uint256 amount1) = IPancakeNPM(NPM).decreaseLiquidity(params);

            if (t0 == WETH) settledWeth += amount0;
            if (t1 == WETH) settledWeth += amount1;
            if (t0 == USDT) settledUsdt += amount0;
            if (t1 == USDT) settledUsdt += amount1;
        }

        assertGt(active, 0, "holder should have at least one active position");
        // Same live `slot0` price drives both the adapter split and the NPM burn, so they agree to within 1 wei
        // per position (the only gap is rounding direction in getAmountsForLiquidity vs the pool's burn).
        assertApproxEqAbs(adapterWeth, settledWeth, active, "adapter WETH principal != NPM settlement");
        assertApproxEqAbs(adapterUsdt, settledUsdt, active, "adapter USDT principal != NPM settlement");
    }
}
