// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {FluidFTokensMetaBalanceAdapter} from "src/balances/protocols/FluidFTokensMeta.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @notice Minimal ERC4626-shaped Fluid fToken mock with a share→asset rate and an on-chain symbol.
contract MockFToken {
    string public symbol;
    address private _asset;
    uint256 private _rate;
    mapping(address => uint256) public balanceOf;

    constructor(string memory symbol_, address asset_, uint256 rate_) {
        symbol = symbol_;
        _asset = asset_;
        _rate = rate_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * _rate) / 1e18;
    }

    function setBalance(address a, uint256 s) external {
        balanceOf[a] = s;
    }
}

contract FTok {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @title FluidFTokensMetaBalanceAdapter unit tests (no fork)
contract FluidFTokensMetaBalanceAdapterTest is Test {
    using Strings for address;

    Mock_NAVCalculator nav;
    FluidFTokensMetaBalanceAdapter meta;
    FTok usdc;
    FTok weth;
    MockFToken fUSDC;
    MockFToken fWETH;

    address alice = makeAddr("alice");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        usdc = new FTok("USDC", 6);
        weth = new FTok("WETH", 18);
        nav.registerAsset(address(usdc), 6, "USDC");
        nav.registerAsset(address(weth), 18, "WETH");

        fUSDC = new MockFToken("fUSDC", address(usdc), 11e17); // 1 share = 1.1 USDC
        fWETH = new MockFToken("fWETH", address(weth), 1e18);
        fUSDC.setBalance(alice, 100e6);
        fWETH.setBalance(alice, 3e18);

        meta = new FluidFTokensMetaBalanceAdapter("Fluid", address(nav));
    }

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(fUSDC))));
        ins[1] = bytes32(uint256(uint160(address(fWETH))));
    }

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(meta.getOraclePositions(alice, address(0)).length, 0);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_fanOut_supplyLegsAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 2);
        assertEq(p[0].underlyingAsset.asset, address(usdc));
        assertEq(p[0].amount, 110e6); // 100 * 1.1
        assertFalse(p[0].isDebt);
        assertEq(p[0].positionId, address(fUSDC).toHexString());
        assertEq(p[0].protocol, "Fluid");
        assertEq(
            p[0].positionDetail,
            "{\"protocol\":\"Fluid\",\"product\":\"Lending\",\"name\":\"fUSDC\",\"type\":\"Supply\"}"
        );
        assertEq(p[1].underlyingAsset.asset, address(weth));
        assertEq(p[1].amount, 3e18);
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p =
            meta.getOraclePositionsForInstances(alice, _instances(), address(weth));
        assertEq(p.length, 1);
        assertEq(p[0].underlyingAsset.asset, address(weth));
    }

    function test_unregisteredAsset_skipped() public {
        nav.unregisterAssetHelper(address(usdc));
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].underlyingAsset.asset, address(weth));
    }

    function test_zeroBalance_skipped() public {
        fUSDC.setBalance(alice, 0);
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, _instances(), address(0));
        assertEq(p.length, 1);
        assertEq(p[0].underlyingAsset.asset, address(weth));
    }

    function test_badInstance_isolated() public view {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = bytes32(uint256(uint160(address(0xdead))));
        ins[1] = bytes32(uint256(uint160(address(fWETH))));
        INAVCalculator.PositionBalance[] memory p = meta.getOraclePositionsForInstances(alice, ins, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 3e18);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2);
        assertEq(a[0], address(usdc));
        assertEq(a[1], address(weth));
    }
}
