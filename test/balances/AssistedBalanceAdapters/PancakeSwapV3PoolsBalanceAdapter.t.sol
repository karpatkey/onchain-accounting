// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    PancakeSwapV3PoolsBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/PancakeSwapV3PoolsBalanceAdapter.sol";
import {UniswapV3PoolsBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockPositionManager,
    MockUniswapV3Pool,
    MockPancakeV3Pool,
    MockUniswapV3Factory,
    MockToken
} from "test/balances/AssistedBalanceAdapters/UniswapV3Mocks.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title PancakeSwapV3PoolsBalanceAdapter unit tests (no fork)
/// @notice The shared assisted tokenId cache / per-NFT principal+fee math / NAV filtering is verified by the Uniswap
///         V3 unit + fork tests and inherited unchanged. PancakeSwap V3 differs in exactly TWO ways: `_protocolId`
///         reports `pancakeswap-v3` (not the inherited `uniswap-v3`), and the `_slot0` override decodes PancakeSwap
///         V3's `uint32 feeProtocol` (Uniswap packs it as `uint8`) — exercised by
///         test_slot0_uint32FeeProtocol_decodesWithoutRevert.
contract PancakeSwapV3PoolsBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    MockUniswapV3Factory factory;
    MockUniswapV3Pool pool; // WETH/USDT 0.05%
    MockToken weth;
    MockToken usdt;
    PancakeSwapV3PoolsBalanceAdapter adapter;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        weth = new MockToken("WETH", 18);
        usdt = new MockToken("USDT", 6);
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdt), 6, "USDT");

        // Factory + pool so positionId resolves to the pool address.
        factory = new MockUniswapV3Factory();
        pool = new MockUniswapV3Pool(address(weth), address(usdt), 500, 10);
        factory.setPool(address(weth), address(usdt), 500, address(pool));
        npm.setFactory(address(factory));

        // ADR 0017: the adapter splits the principal at the pool's live `slot0`. Put the pool in range at
        // sqrtPrice == 2^96 (raw token1/token0 price 1.0, tick 0), keeping the [-100, 100] position in range.
        pool.setSlot0(uint160(1 << 96), 0);

        // NAV still needs the assets registered + priced (NAV, not the adapter, does the pricing).
        nav.setAssetPrice(address(weth), 1e18, 8);
        nav.setAssetPrice(address(usdt), 1e6, 8);

        npm.mint(
            alice,
            1,
            MockPositionManager.PositionData({
                token0: address(weth),
                token1: address(usdt),
                fee: 500,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 1_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 7,
                tokensOwed1: 99
            })
        );

        adapter = new PancakeSwapV3PoolsBalanceAdapter(
            address(npm), "PancakeSwap V3", address(nav), address(this), address(this)
        );
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        adapter.submitTokenIds(alice, ids);
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_nonZeroPrincipal() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertGt(p.length, 0, "legs emitted from the live slot0 split");
        uint256 supply;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind == PositionKind.Supplied) supply += p[i].amount;
        }
        assertGt(supply, 0, "non-zero in-range principal");
    }

    /// @notice The inherited Uniswap base adapter emits the same legs from the same live slot0 split on a PancakeSwap
    ///         NFT (the `MockUniswapV3Pool` here has a uint8 feeProtocol both decoders accept); the ONLY difference is
    ///         the protocol-id slug.
    function test_uniswapBase_sameLegs_onlyProtocolIdDiffers() public {
        UniswapV3PoolsBalanceAdapter base =
            new UniswapV3PoolsBalanceAdapter(address(npm), "Uniswap V3", address(nav), address(this), address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        base.submitTokenIds(alice, ids);

        INAVCalculator.PositionBalance[] memory bp = base.getAdapterPositions(alice, address(0));
        INAVCalculator.PositionBalance[] memory pp = adapter.getAdapterPositions(alice, address(0));
        assertGt(bp.length, 0);
        assertEq(bp.length, pp.length, "same legs from the same live slot0 split");
        for (uint256 i = 0; i < bp.length; i++) {
            assertEq(bp[i].protocolId, ProtocolIds.UNISWAP_V3, "base reports uniswap-v3");
            assertEq(pp[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "PCS reports pancakeswap-v3");
            assertEq(bp[i].amount, pp[i].amount, "identical amounts");
        }
    }

    /// @notice `_protocolId` override: every leg reports `pancakeswap-v3` (not the inherited `uniswap-v3`).
    function test_protocolId_isPancakeswapV3() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "protocolId == pancakeswap-v3");
            assertTrue(p[i].protocolId != ProtocolIds.UNISWAP_V3, "not the inherited uniswap-v3");
        }
    }

    /// @notice positionId schema + labels inherited unchanged: positionId = abi.encode(pool); labels end with NFT id.
    function test_identity_positionId_andLabel() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertGt(p.length, 0);
        assertEq(p[0].positionId, abi.encode(address(pool)));
        assertEq(p[0].labels.length, 3);
        assertEq(p[0].labels[0], "Liquidity Pool");
        assertEq(p[0].labels[1], Strings.toHexString(address(pool)));
        assertEq(p[0].labels[2], "NFT #1");
    }

    /// @notice ADR 0017 / the whole point of the `_slot0` override: a real PCS V3 pool packs `feeProtocol` as a
    ///         `uint32` with bits above byte 0 set (PCS routinely has `feeProtocol > 255`). The PancakeSwap adapter's
    ///         `_slot0` decodes that with the wider ABI, so valuing a position against such a pool does NOT revert.
    ///         As a control, the Uniswap base adapter's `uint8` decode of the SAME returndata reverts.
    function test_slot0_uint32FeeProtocol_decodesWithoutRevert() public {
        // Fresh factory/NPM/pool wired with a PancakeSwap-ABI pool whose feeProtocol overflows uint8.
        MockUniswapV3Factory pcsFactory = new MockUniswapV3Factory();
        MockPositionManager pcsNpm = new MockPositionManager();
        MockPancakeV3Pool pcsPool = new MockPancakeV3Pool(address(weth), address(usdt), 100, 1);
        pcsFactory.setPool(address(weth), address(usdt), 100, address(pcsPool));
        pcsNpm.setFactory(address(pcsFactory));

        // feeProtocol = 222825800 (> uint8.max = 255): high bits set, so a uint8 decode would revert.
        pcsPool.setSlot0(uint160(1 << 96), 0, 222_825_800);

        pcsNpm.mint(
            alice,
            1,
            MockPositionManager.PositionData({
                token0: address(weth),
                token1: address(usdt),
                fee: 100,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 1_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 7,
                tokensOwed1: 99
            })
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        // PancakeSwap adapter: the uint32 `_slot0` decode succeeds → legs emitted, non-zero principal.
        PancakeSwapV3PoolsBalanceAdapter pcs = new PancakeSwapV3PoolsBalanceAdapter(
            address(pcsNpm), "PancakeSwap V3", address(nav), address(this), address(this)
        );
        pcs.submitTokenIds(alice, ids);
        INAVCalculator.PositionBalance[] memory pp = pcs.getAdapterPositions(alice, address(0));
        assertGt(pp.length, 0, "PancakeSwap uint32 feeProtocol decoded without reverting");
        uint256 supply;
        for (uint256 i = 0; i < pp.length; i++) {
            if (pp[i].positionKind == PositionKind.Supplied) supply += pp[i].amount;
        }
        assertGt(supply, 0, "non-zero in-range principal off the PancakeSwap pool");

        // Control: the Uniswap base adapter's uint8 `slot0` decode of the SAME returndata reverts, so the position is
        // unvaluable. The per-NFT read is wrapped in try/catch on the slot0 call? No — `_slot0` is a direct call, so a
        // decode revert bubbles up through getAdapterPositions. Assert it reverts.
        UniswapV3PoolsBalanceAdapter base = new UniswapV3PoolsBalanceAdapter(
            address(pcsNpm), "Uniswap V3", address(nav), address(this), address(this)
        );
        base.submitTokenIds(alice, ids);
        vm.expectRevert();
        base.getAdapterPositions(alice, address(0));
    }
}
