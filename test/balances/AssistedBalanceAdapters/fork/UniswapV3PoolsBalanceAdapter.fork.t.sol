// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {UniswapV3PoolsBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {
    INonfungiblePositionManager,
    UniswapV3PoolLib
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @dev Minimal pool `slot0` read used by the test to recompute the expected split/fees from the SAME data the
///      adapter reads on-chain (ADR 0017 — the adapter reads `slot0` directly; this test mirrors that read instead
///      of feeding the adapter an oracle-reconstructed price).
interface IPoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @title UniswapV3PoolsBalanceForkTest
/// @notice Fork tests for the Uniswap V3 pools assisted adapter against real mainnet contracts, against the real
///         WBTC/WETH 0.3% pool and a real NFT holder. The holder's NFT tokenIds are discovered off the NPM's
///         ERC721Enumerable surface and fed to the adapter via `submitTokenIds` (as the off-chain assistant would).
///         Since ADR 0017 the adapter values each position from the pool's live `slot0` (instantaneous on-chain
///         amounts) — so the test recomputes the expected amounts off the same `slot0` rather than feeding the
///         adapter a reconstructed oracle price.
contract UniswapV3PoolsBalanceForkTest is BalanceAdapterTestBase {
    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant POOL = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD; // WBTC/WETH 0.3%
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant HOLDER = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;
    uint256 public constant FORK_BLOCK = 24_987_608;

    UniswapV3PoolsBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();
        balances = _deployBalancesForAdapter(_assets());
        // admin + assistant = this test, so it can submit the holder's tokenIds.
        adapter = new UniswapV3PoolsBalanceAdapter(NPM, "Uniswap V3", address(balances), address(this), address(this));
        _submitHolderTokenIds();
    }

    /// @notice Discover the holder's NFT tokenIds off the NPM (ERC721Enumerable) and submit them, mirroring the
    ///         off-chain assistant. All enumerated ids are owned by HOLDER, so submitTokenIds never reverts.
    function _submitHolderTokenIds() internal {
        uint256 bal = INonfungiblePositionManager(NPM).balanceOf(HOLDER);
        uint256[] memory ids = new uint256[](bal);
        for (uint256 i = 0; i < bal; i++) {
            ids[i] = INonfungiblePositionManager(NPM).tokenOfOwnerByIndex(HOLDER, i);
        }
        if (ids.length > 0) adapter.submitTokenIds(HOLDER, ids);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = WBTC;
        a[1] = WETH;
    }

    function _token(address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, token);
        for (uint256 i = 0; i < p.length; i++) {
            sum += p[i].amount;
        }
    }

    function test_balance_perToken() public view {
        uint256 wbtc = _token(WBTC);
        uint256 weth = _token(WETH);
        assertTrue(wbtc > 0 || weth > 0, "holder should have a non-zero position");
    }

    function test_identityDerivedOnChain() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            // positionId = the pool contract address.
            address pool = abi.decode(p[i].positionId, (address));
            assertTrue(pool != address(0), "positionId = non-zero pool address");
            assertGt(pool.code.length, 0, "positionId resolves to a deployed pool");
            // NFT id is the last label segment.
            assertEq(p[i].labels.length, 3, "labels = [category, pool, NFT id]");
            assertEq(p[i].labels[0], "Liquidity Pool");
            assertEq(bytes(p[i].labels[2]).length > 0, true, "NFT id label present");
        }
    }

    /// @notice Ground truth: the adapter reads the pool's live `slot0` (ADR 0017), so recomputing the in-range split
    ///         and FULL unclaimed fees off the SAME `slot0` via `UniswapV3PoolLib` must reproduce the adapter's
    ///         reported amounts exactly — and the recomputed fees include the accruing-since-poke component (>=
    ///         tokensOwed), proving the adapter no longer reports settled `tokensOwed` alone.
    function test_amountsMatchLiveSlot0Recompute() public view {
        (uint160 sp, int24 tick,,,,,) = IPoolSlot0(POOL).slot0();

        // Aggregate the adapter's WBTC/WETH split (Supplied) and fees (Fees) for the holder's WBTC/WETH 0.3% NFTs.
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        uint256 adapterLiqWbtc;
        uint256 adapterLiqWeth;
        uint256 adapterFeeWbtc;
        uint256 adapterFeeWeth;
        for (uint256 i = 0; i < p.length; i++) {
            // Only the WBTC/WETH 0.3% pool legs (positionId == POOL).
            if (abi.decode(p[i].positionId, (address)) != POOL) continue;
            bool isFee = p[i].positionKind == PositionKind.Fees;
            if (p[i].balanceAsset.asset == WBTC) {
                if (isFee) adapterFeeWbtc += p[i].amount;
                else adapterLiqWbtc += p[i].amount;
            } else if (p[i].balanceAsset.asset == WETH) {
                if (isFee) adapterFeeWeth += p[i].amount;
                else adapterLiqWeth += p[i].amount;
            }
        }

        // Recompute off the same slot0 across the holder's NFTs in the WBTC/WETH 0.3% pool.
        (uint256 liq0, uint256 liq1, uint256 fee0, uint256 fee1) =
            UniswapV3PoolLib.accountAggregates(POOL, NPM, HOLDER, sp, tick);

        // Pool token0 = WBTC, token1 = WETH (sorted by address). The adapter emits per-token; match accordingly.
        assertEq(adapterLiqWbtc, liq0, "WBTC principal == live-slot0 recompute");
        assertEq(adapterLiqWeth, liq1, "WETH principal == live-slot0 recompute");
        assertEq(adapterFeeWbtc, fee0, "WBTC fee == full unclaimed (feeGrowth + tokensOwed)");
        assertEq(adapterFeeWeth, fee1, "WETH fee == full unclaimed (feeGrowth + tokensOwed)");
    }
}
