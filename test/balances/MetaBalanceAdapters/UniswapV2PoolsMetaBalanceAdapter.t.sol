// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    UniswapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair, MockToken} from "test/balances/MetaBalanceAdapters/UniswapV2Mocks.sol";

/// @title UniswapV2PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Meta-framework behaviour and decomposition logic for UniswapV2PoolsMeta.
contract UniswapV2PoolsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MockUniswapV2Factory factory;
    UniswapV2PoolsMetaBalanceAdapter meta;

    MockToken dai;
    MockToken weth;
    MockToken usdc;
    MockUniswapV2Pair pairA; // DAI/WETH
    MockUniswapV2Pair pairB; // USDC/WETH

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        factory = new MockUniswapV2Factory();
        dai = new MockToken("DAI");
        weth = new MockToken("WETH");
        usdc = new MockToken("USDC");
        nav.registerAsset(address(dai), 18, "DAI");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdc), 18, "USDC");

        pairA = new MockUniswapV2Pair(address(dai), address(weth), address(factory));
        pairA.setReserves(1000e18, 10e18);
        pairA.setTotalSupply(100e18);
        pairA.setBalance(alice, 10e18); // 10% share -> 100 DAI, 1 WETH

        pairB = new MockUniswapV2Pair(address(usdc), address(weth), address(factory));
        pairB.setReserves(2000e18, 20e18);
        pairB.setTotalSupply(200e18);
        pairB.setBalance(alice, 10e18); // 5% share -> 100 USDC, 1 WETH

        meta = new UniswapV2PoolsMetaBalanceAdapter("Uniswap V2", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(pairA))));
        ins[1] = bytes32(uint256(uint160(address(pairB))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_values() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        assertEq(p.length, 2, "DAI + WETH supply legs");
        assertEq(p[0].balanceAsset.asset, address(dai));
        assertEq(p[0].amount, 100e18);
        assertEq(p[1].amount, 1e18);

        assertEq(p[0].positionId, abi.encode(address(pairA)));
    }

    function test_fanOut_acrossPairs() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 4, "2 legs per pair");
        assertEq(p[2].balanceAsset.asset, address(usdc));
        assertEq(p[2].amount, 100e18);
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(weth));
        assertEq(p.length, 2, "WETH leg from each pair");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(weth));
        }
    }

    function test_unregisteredToken_skipped() public {
        nav.unregisterAssetHelper(address(weth));
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(dai));
    }

    function test_zeroBalance_empty() public {
        pairA.setBalance(alice, 0);
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        assertEq(meta.getAdapterPositionsForInstances(alice, one, address(0)).length, 0);
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 2, "bad pair isolated, pairA legs returned");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 4);
        assertEq(a[0], address(dai));
        assertEq(a[1], address(weth));
        assertEq(a[2], address(usdc));
        assertEq(a[3], address(weth));
    }
}
