// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {SparkLendBalanceAdapter} from "src/balances/protocols/SparkLendBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title SparkLendBalanceAdapterForkTest
/// @notice Fork tests for SparkLendBalanceAdapter using real mainnet contracts
/// @dev Tests adapter behavior with real Spark protocol contracts and positions
/// @dev SparkLend inherits from AaveV3Instance, so it uses the same protocol structure
contract SparkLendBalanceAdapterForkTest is BalanceAdapterTestBase {
    // Spark contract addresses (mainnet)
    address public constant DATA_PROVIDER = 0xFc21d6d146E6086B8359705C8b28512a983db0cb;

    // Token addresses
    address public constant DAI = MAINNET_DAI;
    address public constant WBTC = MAINNET_WBTC;
    address public constant WETH = MAINNET_WETH;
    address public constant USDC = MAINNET_USDC;
    address public constant GNO = 0x6810e776880C02933D47DB1b9fc05908e5386b96;
    // Fork blocks
    uint256 public constant FORK_BLOCK_1 = 20_734_274;
    uint256 public constant FORK_BLOCK_2 = 17_772_457;

    // Adapter instance
    SparkLendBalanceAdapter public adapter;

    // Real user addresses with positions in Spark
    address public constant SUPPLY_DAI_WBTC_BORROW_WETH_USER = 0xB6875EC94bE06d159A28d627422b7c9388cc8861;
    address public constant SUPPLY_GNO_DEBT_DAI_USER = 0x849D52316331967b6fF1198e5E32A0eB168D039d;

    function setUp() public override {
        // Note: Fork setup is done per-test since different tests use different blocks
        super.setUp();
    }

    // ============================================
    // Real Position Tests - Block 1
    // ============================================

    function test_getAdapterBalanceForAsset_supply_dai() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](4);
        assets[0] = DAI;
        assets[1] = WBTC;
        assets[2] = WETH;
        assets[3] = USDC;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(SUPPLY_DAI_WBTC_BORROW_WETH_USER, DAI);
        assertGt(amount, 0, "User should have DAI supply position");
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_supply_wbtc() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](4);
        assets[0] = DAI;
        assets[1] = WBTC;
        assets[2] = WETH;
        assets[3] = USDC;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(SUPPLY_DAI_WBTC_BORROW_WETH_USER, WBTC);
        assertGt(amount, 0, "User should have WBTC supply position");
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_borrow_weth() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](4);
        assets[0] = DAI;
        assets[1] = WBTC;
        assets[2] = WETH;
        assets[3] = USDC;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(SUPPLY_DAI_WBTC_BORROW_WETH_USER, WETH);
        assertTrue(isDebt, "User should have WETH borrow position (negative balance)");
        assertGt(amount, 0, "User should have WETH debt amount");
    }

    // ============================================
    // Real Position Tests - Block 2
    // ============================================

    function test_getAdapterBalanceForAsset_supply_gnosis() public {
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_2);

        address[] memory assets = new address[](2);
        assets[0] = GNO;
        assets[1] = DAI;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(SUPPLY_GNO_DEBT_DAI_USER, GNO);
        assertGt(amount, 0, "User should have GNO supply position");
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_debt_dai() public {
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_2);

        address[] memory assets = new address[](2);
        assets[0] = GNO;
        assets[1] = DAI;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(SUPPLY_GNO_DEBT_DAI_USER, DAI);
        assertTrue(isDebt, "User should have DAI debt position (negative balance)");
        assertGt(amount, 0, "User should have DAI debt amount");
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getAdapterBalance_aggregatesPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](4);
        assets[0] = DAI;
        assets[1] = WBTC;
        assets[2] = WETH;
        assets[3] = USDC;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        (address[] memory resultAssets, uint256[] memory amounts,) =
            adapter.getAdapterBalances(SUPPLY_DAI_WBTC_BORROW_WETH_USER);

        // Should have at least DAI, WBTC, and WETH positions
        assertGe(resultAssets.length, 3, "Should have multiple positions");
        assertEq(resultAssets.length, amounts.length, "Arrays should match length");
    }

    function test_getAdapterPositions_returnsCorrectPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](4);
        assets[0] = DAI;
        assets[1] = WBTC;
        assets[2] = WETH;
        assets[3] = USDC;
        balances = _deployBalancesForAdapter(assets);

        adapter = new SparkLendBalanceAdapter(address(DATA_PROVIDER), address(balances));

        INAVCalculator.PositionBalance[] memory positions =
            adapter.getAdapterPositions(SUPPLY_DAI_WBTC_BORROW_WETH_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
