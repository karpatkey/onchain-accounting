// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {FluidFTokenBalanceOracle} from "src/balances/protocols/FluidFToken.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal ERC4626-shaped mock for the Fluid fToken interface (no real fToken needed)
contract MockFluidFToken {
    address private _asset;
    mapping(address => uint256) public balanceOf;
    uint256 public sharePriceNumerator = 1; // assets-per-share = numerator/denominator
    uint256 public sharePriceDenominator = 1;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * sharePriceNumerator / sharePriceDenominator;
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setSharePrice(uint256 numerator, uint256 denominator) external {
        sharePriceNumerator = numerator;
        sharePriceDenominator = denominator;
    }
}

/// @notice Minimal ERC20-shaped mock for the underlying asset
contract MockToken {
    string public symbol = "USDC";
    uint8 public decimals = 6;
}

/// @title FluidFTokenBalanceOracle unit tests (no fork)
contract FluidFTokenBalanceOracleTest is Test {
    MockBalances mockBalances;
    MockFluidFToken mockFToken;
    MockToken mockAsset;
    FluidFTokenBalanceOracle oracle;

    address alice = makeAddr("alice");

    function setUp() public {
        mockBalances = new MockBalances();
        mockAsset = new MockToken();
        mockFToken = new MockFluidFToken(address(mockAsset));
        oracle = new FluidFTokenBalanceOracle(address(mockFToken), "Fluid Lending", "{\"protocol\":\"Fluid\",\"product\":\"Lending\",\"name\":\"fUSDC\"", "0x0000000000000000000000000000000000000001", address(mockBalances));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroFToken() public {
        vm.expectRevert(InvalidArguments.selector);
        new FluidFTokenBalanceOracle(address(0), "Fluid Lending", "{\"protocol\":\"Fluid\",\"product\":\"Lending\",\"name\":\"fUSDC\"", "0x0000000000000000000000000000000000000001", address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractFToken() public {
        vm.expectRevert("fToken must be a contract");
        new FluidFTokenBalanceOracle(address(0xdead), "Fluid Lending", "{\"protocol\":\"Fluid\",\"product\":\"Lending\",\"name\":\"fUSDC\"", "0x0000000000000000000000000000000000000001", address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new FluidFTokenBalanceOracle(address(mockFToken), "Fluid Lending", "{\"protocol\":\"Fluid\",\"product\":\"Lending\",\"name\":\"fUSDC\"", "0x0000000000000000000000000000000000000001", address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(oracle.F_TOKEN()), address(mockFToken));
        assertEq(oracle.ASSET(), address(mockAsset));
        assertEq(address(oracle.NAV_CALCULATOR()), address(mockBalances));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockAsset));
    }

    // ============================================
    // getOracleBalanceForAsset Tests
    // ============================================

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(mockAsset));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_accountWithShares_oneToOne() public {
        mockFToken.setBalance(alice, 1_000e6);
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(mockAsset));
        assertEq(amount, 1_000e6);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_accountWithShares_appreciatedSharePrice() public {
        // Simulate fToken share price growth: 1 share -> 1.05 underlying
        mockFToken.setSharePrice(105, 100);
        mockFToken.setBalance(alice, 1_000e6);
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(mockAsset));
        assertEq(amount, 1_050e6);
        assertFalse(isDebt);
    }

    // ============================================
    // getOracleBalances Tests
    // ============================================

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_accountWithShares() public {
        mockFToken.setBalance(alice, 500e6);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockAsset));
        assertEq(amounts[0], 500e6);
        assertFalse(isDebt[0]);
    }

    // ============================================
    // getOraclePositions Tests
    // ============================================

    function test_getOraclePositions_unknownAccount_returnsEmpty() public view {
        // MockBalances.getRegisteredAssets() returns [], so intersection is empty
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
