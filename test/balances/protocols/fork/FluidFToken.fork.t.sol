// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {FluidFTokenBalanceOracle} from "src/balances/protocols/FluidFToken.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title FluidFTokenBalanceOracle fork tests — fUSDC (Mainnet)
/// @notice Drives the adapter against the canonical Fluid Lending fUSDC contract on Ethereum.
///         We don't rely on a known external holder: we deal USDC to a test address, deposit it
///         into fUSDC, and assert the adapter returns the same amount that the fToken would
///         redeem for. This makes the test deterministic and resilient to holder churn.
contract FluidFTokenBalanceOracleForkTest_fUSDC is BalanceAdapterTestBase {
    // Fluid Lending fUSDC on Ethereum Mainnet
    IERC4626 public constant F_TOKEN = IERC4626(0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // A recent block; fUSDC has been live since well before this.
    uint256 public constant FORK_BLOCK = 23_641_970;

    address public alice = makeAddr("alice-fluid-flender");

    FluidFTokenBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(address(USDC));
        oracle = new FluidFTokenBalanceOracle(address(F_TOKEN), "Fluid Lending", "fUSDC", address(balances));
    }

    function _depositUsdcIntoFToken(address account, uint256 assets) internal returns (uint256 sharesMinted) {
        deal(address(USDC), account, assets);
        vm.startPrank(account);
        USDC.approve(address(F_TOKEN), assets);
        sharesMinted = F_TOKEN.deposit(assets, account);
        vm.stopPrank();
    }

    // ============================================
    // Interface Compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    // ============================================
    // underlyingAssetsSupported / metadata
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDC));
    }

    function test_storedAsset_matchesFTokenAsset() public view {
        assertEq(oracle.ASSET(), F_TOKEN.asset());
    }

    // ============================================
    // Real Balance Tests (deal-and-deposit pattern)
    // ============================================

    function test_getOracleBalanceForAsset_freshDeposit() public {
        uint256 depositAssets = 50_000e6; // 50,000 USDC

        _depositUsdcIntoFToken(alice, depositAssets);

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(USDC));
        // Must match what convertToAssets(balanceOf) returns at this block
        uint256 expected = F_TOKEN.convertToAssets(F_TOKEN.balanceOf(alice));
        assertEq(amount, expected);
        assertGt(amount, 0);
        // Within 1bp of the deposit amount (Fluid lending is non-fee, but rounding can shave 1 wei)
        assertApproxEqRel(amount, depositAssets, 1e14); // 0.01%
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0xdead), address(USDC));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public {
        _depositUsdcIntoFToken(alice, 10_000e6);
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(0xdead));
        assertEq(amount, 0);
    }

    // ============================================
    // Position Aggregation
    // ============================================

    function test_getOracleBalances_freshDeposit() public {
        _depositUsdcIntoFToken(alice, 25_000e6);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);

        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDC));
        assertGt(amounts[0], 0);
        assertFalse(isDebt[0]);
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(address(0xdead));
        assertEq(assets.length, 0);
    }

    function test_getOraclePositions_freshDeposit() public {
        _depositUsdcIntoFToken(alice, 10_000e6);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(USDC));
        assertGt(positions[0].amount, 0);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Fluid Lending");
        assertEq(positions[0].positionDetail, "fUSDC");
        assertEq(positions[0].balanceOracle, address(oracle));
    }

    function test_getOraclePositions_assetFilter() public {
        _depositUsdcIntoFToken(alice, 10_000e6);

        // USDC filter -> position present
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(USDC));
        assertEq(positions.length, 1);

        // Unrelated asset -> empty
        INAVCalculator.PositionBalance[] memory empty = oracle.getOraclePositions(alice, address(0xdead));
        assertEq(empty.length, 0);
    }

    function test_getOraclePositions_unregisteredAsset_droppedFromOutput() public {
        _depositUsdcIntoFToken(alice, 10_000e6);

        // Replace `balances` with an instance where USDC is *not* registered (only WETH is).
        // The adapter must emit zero positions for the user even though they hold fUSDC shares,
        // because the registry intersection between the adapter's supported assets ([USDC]) and
        // the registry's assets ([WETH]) is empty.
        balances = _deployBalancesForOracle(MAINNET_WETH);
        oracle = new FluidFTokenBalanceOracle(address(F_TOKEN), "Fluid Lending", "fUSDC", address(balances));

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
