// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MorphoVaultBalanceOracle} from "src/balances/protocols/MorphoVault.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal ERC4626 vault mock for unit tests (no fork required)
contract MockMorphoVault {
    address private _asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity in unit tests
    }

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }
}

/// @notice Minimal ERC20 mock for the vault underlying asset
contract MockToken {
    string public symbol = "USDC";
    uint8 public decimals = 6;
}

/// @title MorphoVaultBalanceOracle unit tests (no fork)
contract MorphoVaultBalanceOracleTest is Test {
    MockBalances mockBalances;
    MockMorphoVault mockVault;
    MockToken mockAsset;
    MorphoVaultBalanceOracle oracle;

    address alice = makeAddr("alice");

    function setUp() public {
        mockBalances = new MockBalances();
        mockAsset = new MockToken();
        mockVault = new MockMorphoVault(address(mockAsset));
        oracle = new MorphoVaultBalanceOracle(address(mockVault), address(mockBalances));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_invalidArgs_zeroVault() public {
        vm.expectRevert(InvalidArguments.selector);
        new MorphoVaultBalanceOracle(address(0), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractVault() public {
        vm.expectRevert("Vault must be a contract");
        new MorphoVaultBalanceOracle(address(0xdead), address(mockBalances));
    }

    function test_constructor_invalidArgs_nonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new MorphoVaultBalanceOracle(address(mockVault), address(0xdead));
    }

    function test_constructor_stores_immutables() public view {
        assertEq(address(oracle.VAULT()), address(mockVault));
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

    function test_getOracleBalanceForAsset_accountWithShares() public {
        mockVault.setBalance(alice, 1_000e18);
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(mockAsset));
        // mock vault is 1:1, so amount == shares
        assertEq(amount, 1_000e18);
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
        mockVault.setBalance(alice, 500e18);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(mockAsset));
        assertEq(amounts[0], 500e18);
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
