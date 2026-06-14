// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalancerV3PoolsMetaBalanceAdapter} from "src/balances/protocols/balancer/BalancerV3PoolsMeta.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IStablePool} from "src/balances/protocols/balancer/IBalancerV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MockStablePool, MockBalToken} from "./BalancerMetaMocks.sol";

/// @title BalancerV3PoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Exercises the meta-framework behaviour and the wallet-BPT pool-share math. The full ERC4626-unwrap and
///         rate-scaled math is fork-tested against the original combined adapter; here we use a non-rate, 18-dec
///         mock pool so the per-token share reduces to `balancesLiveScaled18 * userBalance / totalSupply`.
contract BalancerV3PoolsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    BalancerV3PoolsMetaBalanceAdapter adapter;

    MockBalToken tokenX;
    MockBalToken tokenY;
    MockStablePool pool;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        tokenX = new MockBalToken("X", 18);
        tokenY = new MockBalToken("Y", 18);
        nav.registerAsset(address(tokenX), 18, "X");
        nav.registerAsset(address(tokenY), 18, "Y");

        // 100 X and 200 Y live (scaled18) backing 1000 BPT; no rate, scaling factor 1.
        pool = new MockStablePool("rETH/WETH BPT");
        pool.addToken(address(tokenX), 100e18, 1, 1e18);
        pool.addToken(address(tokenY), 200e18, 1, 1e18);
        pool.setTotalSupply(1000e18);

        adapter = new BalancerV3PoolsMetaBalanceAdapter("Balancer V3", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(pool))));
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public {
        pool.setBalance(alice, 100e18);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    function test_positionsForInstances_walletShare() public {
        pool.setBalance(alice, 100e18); // 10% of supply

        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));

        assertEq(pos.length, 2, "one Supply leg per pool token");

        assertEq(pos[0].balanceAsset.asset, address(tokenX));
        assertEq(pos[0].amount, 10e18); // 100e18 * 100e18 / 1000e18
        assertFalse(pos[0].isDebt);
        assertEq(pos[0].balanceAdapter, address(adapter));
        assertEq(pos[0].positionId, abi.encode(address(pool)));

        assertEq(pos[1].balanceAsset.asset, address(tokenY));
        assertEq(pos[1].amount, 20e18); // 200e18 * 100e18 / 1000e18
    }

    function test_zeroWalletBpt_empty() public view {
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 0);
    }

    function test_assetFilter_returnsOnlyMatchingToken() public {
        pool.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(tokenY));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(tokenY));
        assertEq(pos[0].amount, 20e18);
    }

    function test_unregisteredToken_skipped() public {
        // Drop tokenY from the registry; only tokenX survives.
        nav.unregisterAssetHelper(address(tokenY));
        pool.setBalance(alice, 100e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
    }

    function test_badInstance_isolated() public {
        pool.setBalance(alice, 100e18);
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead)))); // no code -> reverts internally, isolated
        ins[1] = bytes32(uint256(uint160(address(pool))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(pos.length, 2, "bad instance isolated, good pool returns both legs");
        assertEq(pos[0].balanceAsset.asset, address(tokenX));
    }

    function test_emptyInstances_returnsEmpty() public view {
        assertEq(adapter.getAdapterPositionsForInstances(alice, new bytes32[](0), address(0)).length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_instances());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokenX));
        assertEq(assets[1], address(tokenY));
    }
}
