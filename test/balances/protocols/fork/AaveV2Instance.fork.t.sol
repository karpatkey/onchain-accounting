// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveV2InstanceBalanceOracle} from "src/balances/protocols/AaveV2Instance.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title AaveV2InstanceBalanceOracleForkTest
/// @notice Fork tests for AaveV2InstanceBalanceOracle using real Mainnet Aave V2 contracts
/// @dev AaveV2Instance inherits from AaveV3Instance — V2's ProtocolDataProvider exposes the
/// same getAllReservesTokens() and getUserReserveData(asset, user) ABI as V3, so the V3 logic
/// applies unchanged. These tests verify that against real on-chain V2 state.
contract AaveV2InstanceBalanceOracleForkTest is BalanceAdapterTestBase {
    // Aave V2 Mainnet addresses
    address public constant AAVE_V2_DATA_PROVIDER = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;

    // Token addresses
    address public constant USDC = MAINNET_USDC;
    address public constant DAI = MAINNET_DAI;
    address public constant WETH = MAINNET_WETH;
    address public constant WBTC = MAINNET_WBTC;
    address public constant USDT = MAINNET_USDT;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // Fork block (recent, stable). V2 is mostly dormant so positions barely drift across blocks.
    uint256 public constant FORK_BLOCK = 25_000_000;

    // Oracle instance
    AaveV2InstanceBalanceOracle public oracle;

    // Real V2 holders at FORK_BLOCK (located by scanning aUSDC v2 transfers + probing
    // ProtocolDataProvider.getUserReserveData):
    //   PURE_USDC_SUPPLIER: ~47,449 USDC supplied, no debt
    //   STETH_SUPPLY_USDC_BORROW: ~0.0112 stETH supplied as collateral, ~14.47 USDC variable debt
    address public constant PURE_USDC_SUPPLIER = 0x32e8D4c9d1B711BC958d0Ce8D14b41F77Bb03a64;
    address public constant STETH_SUPPLY_USDC_BORROW = 0x434Dba149a4A2b9909A7FFeED08491Aed9d5b904;

    function setUp() public override {
        super.setUp();
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
    }

    function _v2Assets() internal pure returns (address[] memory assets) {
        assets = new address[](6);
        assets[0] = USDC;
        assets[1] = DAI;
        assets[2] = WETH;
        assets[3] = WBTC;
        assets[4] = USDT;
        assets[5] = STETH;
    }

    function _deployOracle() internal {
        balances = _deployBalancesForOracle(_v2Assets());
        oracle = new AaveV2InstanceBalanceOracle(AAVE_V2_DATA_PROVIDER, "Aave V2", address(balances));
    }

    // ============================================
    // Supported assets (discovered from V2 ProtocolDataProvider)
    // ============================================

    function test_underlyingAssetsSupported_returnsNonEmptyList() public {
        _deployOracle();
        address[] memory assets = oracle.underlyingAssetsSupported();
        // Aave V2 Mainnet has tens of reserves listed at FORK_BLOCK; assert it's a meaningful set.
        assertGt(assets.length, 5, "V2 reserve list should be non-trivial");
    }

    // ============================================
    // Pure supplier — non-zero USDC supply, no debt
    // ============================================

    function test_pureSupplier_usdc_isCredit() public {
        _deployOracle();
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(PURE_USDC_SUPPLIER, USDC);
        assertGt(amount, 0, "pure supplier should have non-zero USDC supply");
        assertFalse(isDebt, "supply should not be debt");
    }

    function test_pureSupplier_dai_isZero() public {
        _deployOracle();
        (uint256 amount,) = oracle.getOracleBalanceForAsset(PURE_USDC_SUPPLIER, DAI);
        assertEq(amount, 0, "pure supplier should have no DAI position");
    }

    // ============================================
    // Mixed holder — stETH collateral + USDC variable debt
    // ============================================

    function test_mixed_steth_isCredit() public {
        _deployOracle();
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(STETH_SUPPLY_USDC_BORROW, STETH);
        assertGt(amount, 0, "mixed holder should have stETH supply");
        assertFalse(isDebt, "stETH supply should not be debt");
    }

    function test_mixed_usdc_isDebt() public {
        _deployOracle();
        // Net (supply - debt) on USDC: this holder has 1 wei aUSDC + ~14.47 USDC variable debt,
        // so the netted position is debt-side.
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(STETH_SUPPLY_USDC_BORROW, USDC);
        assertGt(amount, 0, "USDC net amount should be non-zero");
        assertTrue(isDebt, "net USDC position should be a debt");
    }

    // ============================================
    // Aggregation views
    // ============================================

    function test_getOracleBalances_aggregatesPositions_pureSupplier() public {
        _deployOracle();
        (address[] memory resultAssets, uint256[] memory amounts, bool[] memory isDebt_) =
            oracle.getOracleBalances(PURE_USDC_SUPPLIER);
        assertEq(resultAssets.length, amounts.length, "assets/amounts length mismatch");
        assertEq(resultAssets.length, isDebt_.length, "assets/isDebt length mismatch");
        assertGe(resultAssets.length, 1, "pure supplier should report at least one position");
        for (uint256 i = 0; i < resultAssets.length; i++) {
            assertGt(amounts[i], 0, "every reported amount must be non-zero");
        }
    }

    function test_getOraclePositions_pureSupplier_buildsRegisteredOnly() public {
        _deployOracle();
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(PURE_USDC_SUPPLIER, address(0));
        assertGe(positions.length, 1, "should have at least one position");
        for (uint256 i = 0; i < positions.length; i++) {
            assertGt(positions[i].amount, 0, "amount must be positive");
            assertEq(positions[i].balanceOracle, address(oracle), "oracle attribution");
            assertEq(positions[i].protocol, "Aave V2", "protocol string");
        }
    }

    function test_getOraclePositions_mixedHolder_returnsBothLegs() public {
        _deployOracle();
        INAVCalculator.PositionBalance[] memory positions =
            oracle.getOraclePositions(STETH_SUPPLY_USDC_BORROW, address(0));
        assertGe(positions.length, 2, "should report supply and borrow legs");

        bool sawCredit = false;
        bool sawDebt = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isDebt) {
                sawDebt = true;
            } else {
                sawCredit = true;
            }
        }
        assertTrue(sawCredit, "should include the stETH supply leg");
        assertTrue(sawDebt, "should include the USDC borrow leg");
    }

    function test_getOraclePositions_assetFilter_restrictsResult() public {
        _deployOracle();
        INAVCalculator.PositionBalance[] memory positions =
            oracle.getOraclePositions(STETH_SUPPLY_USDC_BORROW, STETH);
        assertEq(positions.length, 1, "asset filter should yield a single asset's positions");
        assertEq(positions[0].underlyingAsset.asset, STETH, "filtered asset matches");
        assertFalse(positions[0].isDebt, "stETH leg is supply");
    }

    function test_getOraclePositions_zeroAccount_returnsEmpty() public {
        _deployOracle();
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }
}
