// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {GearboxMarketsMetaBalanceAdapter} from "src/balances/protocols/GearboxMarketsMetaBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal ERC4626-shaped Gearbox market mock with a share→asset rate and on-chain name.
contract MockGearboxMarket {
    string public name;
    address private _asset;
    uint256 private _rate; // assets per share, 1e18-scaled
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, address asset_, uint256 rate_) {
        name = name_;
        _asset = asset_;
        _rate = rate_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * _rate) / 1e18;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }
}

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @title GearboxMarketsMetaBalanceAdapter unit tests (no fork)
contract GearboxMarketsMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    GearboxMarketsMetaBalanceAdapter meta;
    MockToken weth;
    MockToken wsteth;
    MockGearboxMarket marketA; // kpk WETH market
    MockGearboxMarket marketB; // kpk wstETH market

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        weth = new MockToken("WETH", 18);
        wsteth = new MockToken("wstETH", 18);
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(wsteth), 18, "wstETH");

        marketA = new MockGearboxMarket("kpk WETH market", address(weth), 11e17); // 1 share = 1.1 WETH
        marketB = new MockGearboxMarket("kpk wstETH market", address(wsteth), 1e18);
        marketA.setBalance(alice, 10e18); // 11 WETH
        marketB.setBalance(alice, 4e18); // 4 wstETH

        meta = new GearboxMarketsMetaBalanceAdapter("Gearbox", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(marketA))));
        ins[1] = bytes32(uint256(uint160(address(marketB))));
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

    function test_fanOut_supplyLegsAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 2);

        assertEq(p[0].balanceAsset.asset, address(weth));
        assertEq(p[0].amount, 11e18);
        assertFalse(p[0].isDebt);
        assertEq(p[0].balanceAdapter, address(meta));
        assertEq(p[0].positionId, abi.encode(address(marketA)));

        assertEq(p[1].balanceAsset.asset, address(wsteth));
        assertEq(p[1].amount, 4e18);
        assertEq(p[1].positionId, abi.encode(address(marketB)));
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(wsteth));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(wsteth));
    }

    function test_unregisteredAsset_skipped() public {
        nav.unregisterAssetHelper(address(weth));
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(wsteth));
    }

    function test_zeroBalance_skipped() public {
        marketA.setBalance(alice, 0);
        INAVCalculator.PositionBalance[] memory p =
            meta.getAdapterPositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].balanceAsset.asset, address(wsteth));
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(marketB))));
        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 4e18);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2);
        assertEq(a[0], address(weth));
        assertEq(a[1], address(wsteth));
    }
}
