// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AaveV3SafetyModuleBalanceOracleTest
/// @notice Unit tests for the hardcoded multi-token AaveV3SafetyModuleBalanceOracle.
/// @dev The adapter's stake-token addresses are compile-time constants pointing at Mainnet contracts.
///      Without a fork those addresses are EOAs — so any test path that reaches a live
///      `IStakeToken.balanceOf(...)` call must run as a fork test (see the .fork.t.sol companion).
///      Unit tests cover the surface that doesn't touch those externals: constructor guards,
///      ERC165, underlyingAssetsSupported (hardcoded list), and the zero-account / zero-asset
///      shortcuts in the IBalanceOracleAdapter methods.
contract AaveV3SafetyModuleBalanceOracleTest is BalanceAdapterTestBase {
    AaveV3SafetyModuleBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new AaveV3SafetyModuleBalanceOracle(address(balances), "Aave V3 Safety Module", "{\"protocol\":\"Aave V3\",\"product\":\"Safety Module\"", "0x0000000000000000000000000000000000000001");
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(oracle.NAV_CALCULATOR()), address(balances));
        assertEq(oracle.PROTOCOL(), "Aave V3 Safety Module");
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveV3SafetyModuleBalanceOracle(address(0), "x", "{\"p\":\"t\"", "0x0000000000000000000000000000000000000001");
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveV3SafetyModuleBalanceOracle(makeAddr("eoa"), "x", "{\"p\":\"t\"", "0x0000000000000000000000000000000000000001");
    }

    // ─── Hardcoded address table ──────────────────────────────────────────────

    function test_constants_pointAtMainnetAddresses() public view {
        assertEq(oracle.AAVE(), 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
        assertEq(oracle.GHO(), 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
        assertEq(oracle.ABPT(), 0x41A08648C3766F9F9d85598fF102a08f4ef84F84);
        assertEq(oracle.ABPT_V2(), 0x3de27EFa2F1AA663Ae5D458857e731c129069F29);
        assertEq(oracle.STK_AAVE(), 0x4da27a545c0c5B758a6BA100e3a049001de870f5);
        assertEq(oracle.STK_ABPT(), 0xa1116930326D21fB917d5A27F1E9943A9595fb47);
        assertEq(oracle.STK_ABPT_V2(), 0x9eDA81C21C273a82BE9Bbc19B6A6182212068101);
        assertEq(oracle.STK_GHO(), 0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    }

    // ─── underlyingAssetsSupported (pure, no external reads) ──────────────────

    function test_underlyingAssetsSupported_returnsFourDeduplicatedAssets() public view {
        // Four stake tokens, all paying AAVE rewards; dedup of (staked ∪ reward) gives:
        // AAVE, GHO, ABPT, ABPT_V2.
        address[] memory list = oracle.underlyingAssetsSupported();
        assertEq(list.length, 4);
        bool sawAave;
        bool sawGho;
        bool sawAbpt;
        bool sawAbptV2;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == oracle.AAVE()) sawAave = true;
            if (list[i] == oracle.GHO()) sawGho = true;
            if (list[i] == oracle.ABPT()) sawAbpt = true;
            if (list[i] == oracle.ABPT_V2()) sawAbptV2 = true;
        }
        assertTrue(sawAave);
        assertTrue(sawGho);
        assertTrue(sawAbpt);
        assertTrue(sawAbptV2);
    }

    // ─── Zero-account / zero-asset shortcuts ──────────────────────────────────

    function test_getOracleBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), oracle.AAVE());
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalances_returnsEmptyArraysForZeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAccount() public view {
        // Zero-account shortcut returns [] before touching NAV_CALCULATOR or any stake token.
        assertEq(oracle.getOraclePositions(address(0), address(0)).length, 0);
    }

    // ─── ERC165 ───────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }
}
