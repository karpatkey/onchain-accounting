// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {PancakeSwapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMeta.sol";
import {UniswapV3PoolsMetaBalanceAdapter} from "src/balances/protocols/uniswap/UniswapV3PoolsMeta.sol";
import {TickMath} from "src/balances/protocols/uniswap/lib/TickMath.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockPositionManager, MockToken} from "test/balances/protocols/uniswap/UniswapV3Mocks.sol";
import {MockPancakeV3Pool} from "test/balances/protocols/pancakeswap/PancakeSwapV3Mocks.sol";

/// @title PancakeSwapV3PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Covers the two overrides PancakeSwap V3 adds on top of `UniswapV3PoolsMetaBalanceAdapter` — the shared
///         NFT discovery / principal+fee math / NAV filtering is verified by the Uniswap V3 unit + fork tests and
///         inherited unchanged:
///         - `_slot0`: PancakeSwap declares `slot0().feeProtocol` as `uint32`; a `uint8` decode reverts once the
///           high bits are set. The mock pool returns `feeProtocol = 222825800` (> 255), so the PancakeSwap
///           adapter decodes it (non-zero principal) while the inherited Uniswap adapter's `uint8` read reverts
///           and the meta isolates the instance to empty. This is the entire reason the override exists.
///         - `_protocolId`: reports `pancakeswap-v3` (not the inherited `uniswap-v3`).
contract PancakeSwapV3PoolsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    MockToken weth;
    MockToken usdt;
    MockPancakeV3Pool pool; // WETH/USDT 0.05%, slot0().feeProtocol = 222825800 (uint32 > 255)
    PancakeSwapV3PoolsMetaBalanceAdapter meta;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        weth = new MockToken("WETH", 18);
        usdt = new MockToken("USDT", 6);
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdt), 6, "USDT");

        pool = new MockPancakeV3Pool(address(weth), address(usdt), 500, 10);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0); // in-range for [-100, 100]

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

        meta = new PancakeSwapV3PoolsMetaBalanceAdapter(address(npm), "PancakeSwap V3", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(pool))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    /// @notice The `_slot0` override decodes a `uint32 feeProtocol > 255`: the adapter returns non-zero principal.
    function test_slot0_uint32FeeProtocol_decodes() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertGt(p.length, 0, "override decodes uint32 feeProtocol -> legs emitted");
        uint256 supply;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind == PositionKind.Supplied) supply += p[i].amount;
        }
        assertGt(supply, 0, "non-zero in-range principal");
    }

    /// @notice The inherited Uniswap adapter decodes `feeProtocol` as `uint8`; on the same `uint32` pool its
    ///         `_slot0` reverts, which the meta isolates per-instance -> empty. Exactly why PCS V3 overrides `_slot0`.
    function test_uniswapBase_revertsOnUint32_isolatedToEmpty() public {
        UniswapV3PoolsMetaBalanceAdapter base =
            new UniswapV3PoolsMetaBalanceAdapter(address(npm), "Uniswap V3", address(nav));
        INAVCalculator.PositionBalance[] memory p = base.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 0, "uint8 slot0 read reverts on feeProtocol > 255 -> instance isolated to empty");
    }

    /// @notice `_protocolId` override: every leg reports `pancakeswap-v3` (not the inherited `uniswap-v3`).
    function test_protocolId_isPancakeswapV3() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].protocolId, ProtocolIds.PANCAKESWAP_V3, "protocolId == pancakeswap-v3");
            assertTrue(p[i].protocolId != ProtocolIds.UNISWAP_V3, "not the inherited uniswap-v3");
        }
    }

    /// @notice positionId schema + identity are inherited unchanged: abi.encode(npm, tokenId), label "NFT #<id>".
    function test_identity_positionId_andLabel() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertGt(p.length, 0);
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(1)));
        assertEq(meta.describePosition(abi.encode(address(npm), uint256(1))), "NFT #1");
    }
}
