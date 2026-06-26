// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "src/balances/protocols/CompoundV3CometsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockCometRich, MockCompoundRewardsConfigurable} from "test/balances/protocols/CompoundV3Mocks.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

contract MetaTok {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @title CompoundV3CometsMetaBalanceAdapter unit tests (no fork)
/// @notice Meta-framework behaviour with static-index mock comets (accrual reduces to principal /
///         baseTrackingAccrued). The full accrual + reward math is fork-tested for parity vs the per-comet adapter.
contract CompoundV3CometsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    CompoundV3CometsMetaBalanceAdapter meta;
    MockCompoundRewardsConfigurable rewards;

    MetaTok usdc;
    MetaTok weth;
    MetaTok wbtc;
    MetaTok comp;
    MockCometRich cometA; // base USDC, collateral WBTC
    MockCometRich cometB; // base WETH, no collateral

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new MetaTok("USDC", 6);
        weth = new MetaTok("WETH", 18);
        wbtc = new MetaTok("WBTC", 8);
        comp = new MetaTok("COMP", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(wbtc), 8, "WBTC");
        nav.registerAsset(address(comp), 18, "COMP");

        rewards = new MockCompoundRewardsConfigurable(address(comp));

        address[] memory aCollats = new address[](1);
        aCollats[0] = address(wbtc);
        cometA = new MockCometRich(address(usdc), aCollats);
        cometB = new MockCometRich(address(weth), new address[](0));

        // alice in cometA: supply 100 USDC, 5 WBTC collateral, 7 COMP reward owed.
        cometA.setPrincipal(alice, int104(uint104(100e6)));
        cometA.setCollateral(alice, address(wbtc), 5e8);
        cometA.setBaseTrackingAccrued(alice, 7e18);
        // alice in cometB: borrow 50 WETH.
        cometB.setPrincipal(alice, -int104(uint104(50e18)));

        meta = new CompoundV3CometsMetaBalanceAdapter(address(rewards), address(comp), "Compound V3", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(cometA))));
        ins[1] = bytes32(uint256(uint160(address(cometB))));
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

    function test_fanOut_allLegTypes() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        // cometA: Supply(USDC) + Collateral(WBTC) + Rewards(COMP) = 3; cometB: Borrow(WETH) = 1 -> 4
        assertEq(p.length, 4);

        // cometA Supply (base USDC)
        assertEq(p[0].balanceAsset.asset, address(usdc));
        assertEq(p[0].amount, 100e6);
        assertFalse(p[0].isDebt);
        assertEq(p[0].positionId, abi.encode(address(cometA)));
        assertEq(uint256(p[0].positionKind), uint256(PositionKind.Supplied));
        // cometA Collateral (WBTC)
        assertEq(p[1].balanceAsset.asset, address(wbtc));
        assertEq(p[1].amount, 5e8);
        assertFalse(p[1].isDebt);
        // cometA Rewards (COMP)
        assertEq(p[2].balanceAsset.asset, address(comp));
        assertEq(p[2].amount, 7e18);
        // cometB Borrow (WETH)
        assertEq(p[3].balanceAsset.asset, address(weth));
        assertEq(p[3].amount, 50e18);
        assertTrue(p[3].isDebt);
        assertEq(p[3].positionId, abi.encode(address(cometB)));
    }

    function test_assetFilter() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(wbtc));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(wbtc));
    }

    function test_unregisteredAsset_skipped() public {
        nav.unregisterAssetHelper(address(comp)); // drop the reward token
        bytes32[] memory one = new bytes32[](1);
        one[0] = _instances()[0];
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, one, address(0));
        // cometA now: Supply(USDC) + Collateral(WBTC) = 2 (COMP reward dropped)
        assertEq(p.length, 2);
        for (uint256 i = 0; i < p.length; i++) {
            assertTrue(p[i].balanceAsset.asset != address(comp));
        }
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(cometB))));
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 1, "bad comet isolated, cometB borrow leg returned");
        assertEq(p[0].amount, 50e18);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        // cometA: [USDC, WBTC, COMP] + cometB: [WETH, COMP] = 5
        assertEq(a.length, 5);
        assertEq(a[0], address(usdc));
        assertEq(a[1], address(wbtc));
        assertEq(a[2], address(comp));
        assertEq(a[3], address(weth));
        assertEq(a[4], address(comp));
    }

    function _hasType(string memory detail, string memory typ) private pure returns (bool) {
        bytes memory h = bytes(detail);
        bytes memory n = bytes(string.concat("\"type\":\"", typ, "\"}"));
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
