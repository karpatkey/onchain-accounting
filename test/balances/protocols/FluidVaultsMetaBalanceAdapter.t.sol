// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {FluidVaultsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockFluidVaultT1, MockFluidVaultResolver, MockToken} from "test/balances/protocols/FluidVaultMocks.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title FluidVaultsMetaBalanceAdapter unit tests (no fork)
contract FluidVaultsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    MockFluidVaultResolver resolver;
    FluidVaultsMetaBalanceAdapter meta;

    MockToken wsteth;
    MockToken usdc;
    MockToken weeth;
    MockFluidVaultT1 vaultA; // wstETH/USDC
    MockFluidVaultT1 vaultB; // weETH/wstETH

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        wsteth = new MockToken("wstETH", 18);
        usdc = new MockToken("USDC", 6);
        weeth = new MockToken("weETH", 18);
        nav.registerAsset(address(wsteth), 18, "wstETH");
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weeth), 18, "weETH");

        vaultA = new MockFluidVaultT1();
        vaultA.setTokens(address(wsteth), address(usdc));
        vaultB = new MockFluidVaultT1();
        vaultB.setTokens(address(weeth), address(wsteth));

        resolver = new MockFluidVaultResolver();
        // alice: nft1 in vaultA (5 wstETH collateral, 1000 USDC debt); nft2 in vaultB (2 weETH, 1 wstETH debt).
        resolver.pushNft(alice, 1, address(vaultA), 5e18, 1000e6, false);
        resolver.pushNft(alice, 2, address(vaultB), 2e18, 1e18, false);

        meta = new FluidVaultsMetaBalanceAdapter(address(resolver), "Fluid", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(vaultA))));
        ins[1] = bytes32(uint256(uint160(address(vaultB))));
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

    function test_fanOut_collateralAndBorrow() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 4);

        // vaultA Collateral (wstETH)
        assertEq(p[0].balanceAsset.asset, address(wsteth));
        assertEq(p[0].amount, 5e18);
        assertFalse(p[0].isDebt);
        assertEq(p[0].positionId, abi.encode(address(vaultA)));

        // vaultA Borrow (USDC)
        assertEq(p[1].balanceAsset.asset, address(usdc));
        assertEq(p[1].amount, 1000e6);
        assertTrue(p[1].isDebt);

        // vaultB Collateral (weETH) + Borrow (wstETH)
        assertEq(p[2].balanceAsset.asset, address(weeth));
        assertEq(p[2].amount, 2e18);
        assertFalse(p[2].isDebt);
        assertEq(p[3].balanceAsset.asset, address(wsteth));
        assertEq(p[3].amount, 1e18);
        assertTrue(p[3].isDebt);
    }

    function test_liquidatedPosition_skipped() public {
        // A liquidated NFT contributes nothing.
        MockFluidVaultResolver r2 = new MockFluidVaultResolver();
        r2.pushNft(alice, 9, address(vaultA), 5e18, 1000e6, true);
        FluidVaultsMetaBalanceAdapter m2 = new FluidVaultsMetaBalanceAdapter(address(r2), "Fluid", address(nav));
        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(uint160(address(vaultA))));
        assertEq(m2.getAdapterPositionsForInstances(alice, one, address(0)).length, 0);
    }

    function test_assetFilter() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(usdc));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(usdc));
        assertTrue(p[0].isDebt);
    }

    function test_unregisteredAsset_skipped() public {
        nav.unregisterAssetHelper(address(usdc));
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        assertEq(p.length, 1, "only the registered collateral leg survives");
        assertEq(p[0].balanceAsset.asset, address(wsteth));
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = _instances()[1];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 2, "bad vault isolated, vaultB legs returned");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 4); // [wstETH, USDC, weETH, wstETH]
        assertEq(a[0], address(wsteth));
        assertEq(a[1], address(usdc));
        assertEq(a[2], address(weeth));
        assertEq(a[3], address(wsteth));
    }
}
