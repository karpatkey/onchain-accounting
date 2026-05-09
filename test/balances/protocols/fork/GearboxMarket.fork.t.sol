// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {GearboxMarketBalanceOracle} from "src/balances/protocols/GearboxMarket.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title GearboxMarketBalanceOracle fork tests — kpk WETH Market
/// @notice Tests using the real kpkWETH Gearbox V3 farming pool on Ethereum mainnet
contract GearboxMarketBalanceOracleForkTest_WETH is BalanceAdapterTestBase {
    // kpkWETH Gearbox V3 farming pool and underlying asset
    IERC4626 public constant MARKET = IERC4626(0x9396DCbf78fc526bb003665337C5E73b699571EF);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Fork block where SAFE holds a known position
    uint256 public constant FORK_BLOCK = 24_068_807;

    // karpatkey Safe holding kpkWETH market shares at fork block
    address public constant SAFE = 0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C;

    // address(0xdead) holds Gearbox dust shares — use a deterministic address with no history
    address internal unknownAccount;

    GearboxMarketBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        _setupFork();
        unknownAccount = makeAddr("unknownAccount");
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(address(WETH));
        oracle = new GearboxMarketBalanceOracle(
            address(MARKET),
            "Gearbox",
            "{\"protocol\":\"Gearbox\",\"product\":\"Market\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(WETH));
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_safe() public view {
        uint256 shares = MARKET.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE should hold kpkWETH shares at fork block");

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(SAFE, address(WETH));

        // Oracle result must exactly match convertToAssets(balanceOf(account)) — same calculation
        uint256 expected = MARKET.convertToAssets(shares);
        assertEq(amount, expected, "Oracle balance should match convertToAssets output");
        assertGt(amount, 0, "Balance should be positive");
        assertFalse(isDebt, "Market position is always credit");
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(unknownAccount, address(WETH));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, address(0xdead));
        assertEq(amount, 0);
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(SAFE);

        assertEq(assets.length, 1, "Should have one position");
        assertEq(assets[0], address(WETH));
        assertGt(amounts[0], 0, "Balance should be positive");
        assertFalse(isDebt[0]);
        assertEq(assets.length, amounts.length);
        assertEq(assets.length, isDebt.length);
    }

    function test_getOraclePositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(0));

        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].underlyingAsset.asset, address(WETH));
        assertGt(positions[0].amount, 0, "Position amount should be positive");
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Gearbox");
        assertEq(positions[0].positionDetail, "{\"protocol\":\"Gearbox\",\"product\":\"Market\",\"type\":\"Supply\"}");
    }

    function test_getOraclePositions_withAssetFilter() public view {
        // Filter by WETH — should return the position
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(WETH));
        assertEq(positions.length, 1);
        assertGt(positions[0].amount, 0);

        // Filter by unrelated asset — should return empty
        INAVCalculator.PositionBalance[] memory empty = oracle.getOraclePositions(SAFE, address(0xdead));
        assertEq(empty.length, 0);
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(unknownAccount);
        assertEq(assets.length, 0);
    }
}

/// @title GearboxMarketBalanceOracle fork tests — kpk wstETH Market
/// @notice Tests using the real kpkwstETH Gearbox V3 farming pool on Ethereum mainnet
contract GearboxMarketBalanceOracleForkTest_wstETH is BalanceAdapterTestBase {
    // kpkwstETH Gearbox V3 farming pool and underlying asset
    IERC4626 public constant MARKET = IERC4626(0xA9d17f6D3285208280a1Fd9B94479c62e0AABa64);
    IERC20 public constant WSTETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    // Fork block
    uint256 public constant FORK_BLOCK = 24_068_807;

    // karpatkey Safe — same Safe used for ETH Alpha Fund positions
    address public constant SAFE = 0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C;

    GearboxMarketBalanceOracle public oracle;

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
        balances = _deployBalancesForOracle(address(WSTETH));
        oracle = new GearboxMarketBalanceOracle(
            address(MARKET),
            "Gearbox",
            "{\"protocol\":\"Gearbox\",\"product\":\"Market\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_safe() public view {
        uint256 shares = MARKET.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE should hold kpkwstETH shares at fork block");

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(SAFE, address(WSTETH));

        uint256 expected = MARKET.convertToAssets(shares);
        assertEq(amount, expected, "Oracle balance should match convertToAssets output");
        assertGt(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOraclePositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(0));

        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(WSTETH));
        assertGt(positions[0].amount, 0);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Gearbox");
        assertEq(positions[0].positionDetail, "{\"protocol\":\"Gearbox\",\"product\":\"Market\",\"type\":\"Supply\"}");
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(WSTETH));
    }
}
