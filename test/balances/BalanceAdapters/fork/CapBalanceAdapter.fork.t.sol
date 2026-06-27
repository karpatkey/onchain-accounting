// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {CapBalanceAdapter} from "src/balances/BalanceAdapters/CapBalanceAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title CapBalanceAdapter fork tests
/// @notice Tests using real Cap Finance contracts on Ethereum mainnet
contract CapBalanceAdapterForkTest is BalanceAdapterTestBase {
    // Cap Finance contract addresses (Ethereum mainnet)
    address public constant CUSD = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;
    address public constant STCUSD = 0x88887bE419578051FF9F4eb6C858A951921D8888;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Fork block where the SAFE holds known cUSD + stcUSD positions
    uint256 public constant FORK_BLOCK = 24_299_555;

    // karpatkey Safe with cUSD and stcUSD at fork block
    address public constant SAFE = 0xc84718C87B80b45471Ed274c81399f1095971165;

    // Expected values (from source adapter test at the same block)
    uint256 public constant EXPECTED_CUSD_BALANCE = 15_418_901_322_365_792_211_158;
    uint256 public constant EXPECTED_STCUSD_BALANCE = 14_477_229_622_350_858_108_721;
    uint256 public constant EXPECTED_USDC_AMOUNT = 30_554_823_916;

    // address(0xdead) may hold Cap dust shares — use a deterministic address with no history
    address internal unknownAccount;

    CapBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();
        unknownAccount = makeAddr("unknownAccount");
        _setupAdapter();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupAdapter() internal {
        balances = _deployBalancesForAdapter(USDC);
        adapter = new CapBalanceAdapter(CUSD, STCUSD, USDC, address(balances));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], USDC);
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getAdapterBalanceForAsset_safe() public view {
        // Confirm the SAFE holds the expected cUSD and stcUSD at the fork block
        assertEq(IERC20(CUSD).balanceOf(SAFE), EXPECTED_CUSD_BALANCE, "cUSD balance mismatch at fork block");
        assertEq(IERC20(STCUSD).balanceOf(SAFE), EXPECTED_STCUSD_BALANCE, "stcUSD balance mismatch at fork block");

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(SAFE, USDC);

        assertEq(amount, EXPECTED_USDC_AMOUNT, "Adapter USDC output should match expected");
        assertFalse(isDebt, "Cap positions are always credit");
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(SAFE, address(0xdead));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(unknownAccount, USDC);
        assertEq(amount, 0);
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getAdapterBalances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(SAFE);

        assertEq(assets.length, 1, "Should have one position");
        assertEq(assets[0], USDC);
        assertEq(amounts[0], EXPECTED_USDC_AMOUNT, "USDC amount should match expected");
        assertFalse(isDebt[0]);
        assertEq(assets.length, amounts.length);
        assertEq(assets.length, isDebt.length);
    }

    function test_getAdapterBalances_unknownAccount() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(unknownAccount);
        assertEq(assets.length, 0);
    }

    function test_getAdapterPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(SAFE, address(0));

        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].balanceAsset.asset, USDC);
        assertEq(positions[0].amount, EXPECTED_USDC_AMOUNT, "Position amount should match expected");
        assertFalse(positions[0].isDebt);
    }

    function test_getAdapterPositions_withAssetFilter() public view {
        // Filter by USDC — should return the position
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(SAFE, USDC);
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, EXPECTED_USDC_AMOUNT);

        // Filter by unrelated asset — should return empty
        INAVCalculator.PositionBalance[] memory empty = adapter.getAdapterPositions(SAFE, address(0xdead));
        assertEq(empty.length, 0);
    }
}
