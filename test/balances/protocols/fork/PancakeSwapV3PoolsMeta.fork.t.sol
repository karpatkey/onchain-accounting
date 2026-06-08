// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {PancakeSwapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @notice Minimal PancakeSwap V3 NonfungiblePositionManager interface for the ground-truth settlement check.
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

/// @title PancakeSwapV3PoolsMetaParityForkTest (mainnet, active positions)
/// @notice Verifies the PancakeSwap V3 pools meta-adapter against a real mainnet holder with two ACTIVE
///         (liquidity > 0) positions. PancakeSwap V3 is a byte-for-byte Uniswap V3 fork except `slot0().feeProtocol`
///         is `uint32` (Uniswap's `uint8`); the on-chain Solidity decoder reverts on a `uint8` read whenever the
///         high bits are set, which is the case on every active PCS pool (mainnet WETH/USDT 0.05% `feeProtocol`
///         is 222825800). The adapter's `_slot0` override is therefore the entire verification surface — all other
///         math is inherited from the already-verified UniswapV3PoolsMetaBalanceAdapter.
///
///         Unlike the Base companion test (closed position → only asserts no-revert), this test exercises the
///         override on the meaningful path: `_slot0` feeds `getAmountsForLiquidity`, so the principal amounts
///         depend on the correctly-decoded `sqrtPriceX96`. The ground-truth test then burns each position's
///         liquidity via the real NPM and asserts the adapter's reported principal equals the protocol's own
///         settlement amounts — same NPM, same archive state, same EVM, so no derivation drift is possible.
contract PancakeSwapV3PoolsMetaParityForkTest is BalanceAdapterTestBase {
    address public constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address public constant POOL = 0x6CA298D2983aB03Aa1dA7679389D955A4eFEE15C; // WETH/USDT 0.05%
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant HOLDER = 0x783C3255340f8Ba524452A9BE5d12a77e9Ce1F53;
    // Selected block — same block the dev-anvil dashboard pins at (script/development/test/pancakeswapV3/README.md).
    // HOLDER has at least one active (liquidity > 0) WETH/USDT 0.05% position here. The ground-truth test
    // discovers the holder's active positions dynamically rather than hardcoding tokenIds, since this pool's
    // NFTs churn between owners.
    uint256 public constant FORK_BLOCK = 25_274_483;

    PancakeSwapV3PoolsMetaBalanceAdapter public meta;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForOracle(_assets());
        meta = new PancakeSwapV3PoolsMetaBalanceAdapter(NPM, "PancakeSwap V3", address(balances));
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

    function _poolInstance() internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(POOL)));
    }

    /// @dev Sum adapter amounts for a token, optionally restricted to one PositionKind (Supplied = principal).
    function _sum(address token, bool onlyPrincipal) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(HOLDER, _poolInstance(), address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset != token) continue;
            if (onlyPrincipal && p[i].positionKind != PositionKind.Supplied) continue;
            sum += p[i].amount;
        }
    }

    /// @notice The slot0 uint32-feeProtocol override drives real principal: an active position yields non-zero
    ///         amounts on both tokens. A uint8 `slot0` read (the inherited Uniswap path) would revert here.
    function test_slot0Override_activePositionNonZero() public view {
        assertGt(_sum(WETH, false), 0, "WETH total should be non-zero for active positions");
        assertGt(_sum(USDT, false), 0, "USDT total should be non-zero for active positions");
        assertGt(_sum(WETH, true), 0, "WETH principal should be non-zero (override fed getAmountsForLiquidity)");
        assertGt(_sum(USDT, true), 0, "USDT principal should be non-zero (override fed getAmountsForLiquidity)");
    }

    /// @notice Identity is derived on-chain: positionId = abi.encode(NPM, tokenId).
    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(HOLDER, _poolInstance(), address(0));
        assertGt(p.length, 0, "expected at least one leg");
        for (uint256 i = 0; i < p.length; i++) {
            (address npm, uint256 tokenId) = abi.decode(p[i].positionId, (address, uint256));
            assertEq(npm, NPM, "positionId[0] = NonfungiblePositionManager");
            assertGt(tokenId, 0, "positionId[1] = non-zero tokenId");
            // PancakeSwap V3 reports its own slug, not the inherited uniswap-v3 (the _protocolId override).
            assertEq(p[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "protocolId = pancakeswap-v3");
        }
    }

    /// @notice Ground truth: the adapter's reported Supplied principal equals the protocol's own settlement.
    ///         Burning each NFT's liquidity via the real NPM returns (amount0, amount1) = the principal the
    ///         holder would receive; the adapter derives the same numbers from the same on-chain state via the
    ///         overridden `_slot0`. Exact equality (both use the same round-down SqrtPriceMath).
    function test_groundTruth_principalEqualsNpmSettlement() public {
        // Adapter's principal BEFORE mutating state.
        uint256 adapterWeth = _sum(WETH, true);
        uint256 adapterUsdt = _sum(USDT, true);

        // Discover the holder's active WETH/USDT 0.05% positions dynamically (the pool's NFTs churn owners).
        uint256 settledWeth;
        uint256 settledUsdt;
        uint256 active;
        uint256 n = IPancakeNPM(NPM).balanceOf(HOLDER);
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = IPancakeNPM(NPM).tokenOfOwnerByIndex(HOLDER, i);
            (,, address t0, address t1, uint24 fee,,, uint128 liquidity,,,,) = IPancakeNPM(NPM).positions(tokenId);
            bool isPool = fee == 500 && (t0 == WETH || t0 == USDT) && (t1 == WETH || t1 == USDT);
            if (!isPool || liquidity == 0) continue;
            active++;

            vm.prank(HOLDER);
            (uint256 amount0, uint256 amount1) = IPancakeNPM(NPM)
                .decreaseLiquidity(
                    IPancakeNPM.DecreaseLiquidityParams({
                        tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                    })
                );

            if (t0 == WETH) settledWeth += amount0;
            if (t1 == WETH) settledWeth += amount1;
            if (t0 == USDT) settledUsdt += amount0;
            if (t1 == USDT) settledUsdt += amount1;
        }

        assertGt(active, 0, "holder should have at least one active position");
        assertEq(adapterWeth, settledWeth, "adapter WETH principal != NPM settlement");
        assertEq(adapterUsdt, settledUsdt, "adapter USDT principal != NPM settlement");
    }
}
