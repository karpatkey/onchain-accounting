// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveUmbrellaBalanceOracle} from "src/balances/protocols/AaveUmbrella.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AaveUmbrellaBalanceOracleTest
/// @notice Unit tests for the hardcoded multi-token AaveUmbrellaBalanceOracle.
/// @dev The adapter's stake-token / waToken / aToken addresses are compile-time constants pointing at
///      Mainnet contracts. Without a fork those addresses are EOAs — so any test path that reaches a live
///      `IUmbrellaStakeToken.balanceOf(...)` or `IUmbrellaRewardsController.calculateCurrentUserRewards`
///      call must run as a fork test (see the .fork.t.sol companion). Unit tests cover the surface that
///      doesn't touch those externals: constructor guards, ERC165, the hardcoded address table,
///      `underlyingAssetsSupported`, and the zero-account / zero-asset shortcuts in IBalanceOracleAdapter
///      methods.
contract AaveUmbrellaBalanceOracleTest is BalanceAdapterTestBase {
    AaveUmbrellaBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new AaveUmbrellaBalanceOracle(address(balances), "Aave Umbrella");
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(oracle.NAV_CALCULATOR()), address(balances));
        assertEq(oracle.PROTOCOL(), "Aave Umbrella");
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceOracle(address(0), "x");
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceOracle(makeAddr("eoa"), "x");
    }

    // ─── Hardcoded address table ──────────────────────────────────────────────

    function test_constants_pointAtMainnetAddresses() public view {
        // Bare reserves
        assertEq(oracle.USDC(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(oracle.USDT(), 0xdAC17F958D2ee523a2206206994597C13D831ec7);
        assertEq(oracle.WETH(), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(oracle.GHO(), 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);

        // Stake tokens
        assertEq(oracle.STK_WA_USDC(), 0x6bf183243FdD1e306ad2C4450BC7dcf6f0bf8Aa6);
        assertEq(oracle.STK_WA_USDT(), 0xA484Ab92fe32B143AEE7019fC1502b1dAA522D31);
        assertEq(oracle.STK_WA_WETH(), 0xaAFD07D53A7365D3e9fb6F3a3B09EC19676B73Ce);
        assertEq(oracle.STK_GHO(), 0x4f827A63755855cDf3e8f3bcD20265C833f15033);

        // waToken intermediate wrappers
        assertEq(oracle.WA_USDC(), 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E);
        assertEq(oracle.WA_USDT(), 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8);
        assertEq(oracle.WA_WETH(), 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202);

        // Reward (aToken) addresses
        assertEq(oracle.A_USDC(), 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
        assertEq(oracle.A_USDT(), 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
        assertEq(oracle.A_WETH(), 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);

        // Umbrella infrastructure
        assertEq(oracle.REWARDS_CONTROLLER(), 0x4655Ce3D625a63d30bA704087E52B4C31E38188B);
    }

    // ─── underlyingAssetsSupported (pure, no external reads) ──────────────────

    function test_underlyingAssetsSupported_returnsFourBareReserves() public view {
        // Both legs (Staked + Rewards) emit positions in the bare reserve, since reward aTokens are
        // 1:1 value-equivalent with their underlying. So the supported set is just the bare reserves.
        address[] memory list = oracle.underlyingAssetsSupported();
        assertEq(list.length, 4);

        bool sawUsdc;
        bool sawUsdt;
        bool sawWeth;
        bool sawGho;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == oracle.USDC()) sawUsdc = true;
            if (list[i] == oracle.USDT()) sawUsdt = true;
            if (list[i] == oracle.WETH()) sawWeth = true;
            if (list[i] == oracle.GHO()) sawGho = true;
        }
        assertTrue(sawUsdc);
        assertTrue(sawUsdt);
        assertTrue(sawWeth);
        assertTrue(sawGho);
    }

    // ─── Zero-account / zero-asset shortcuts ──────────────────────────────────

    function test_getOracleBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), oracle.USDC());
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
