// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {GmxBalanceOracle} from "src/balances/protocols/GMX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title GmxBalanceOracleForkTest
/// @notice Fork tests for GmxBalanceOracle using real Arbitrum contracts
/// @dev Tests adapter behavior with real GMX protocol contracts and positions
contract GmxBalanceOracleForkTest is BalanceAdapterTestBase {
    // Arbitrum token addresses
    IERC20 public constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 public constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 public constant BTC = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    address public constant SYN_BTC = 0x47904963fc8b2340414262125aF798B9655E58Cd;

    // Price feed addresses (Arbitrum)
    address public constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;

    // GMX Protocol addresses (Arbitrum)
    address public constant GMX_READER = 0x0537C767cDAC0726c76Bb89e92904fe28fd02fE1;
    address public constant GMX_REFERRAL_STORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;

    // Market addresses
    address public constant WETH_WETH_SHORT_MARKET = 0x450bb6774Dd8a756274E0ab4107953259d2ac541;
    address public constant WETH_USDC_LONG_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address public constant BTC_USDC_LONG_MARKET = 0x47c031236e19d024b42f8AE6780E44A573170703;

    // Fork blocks
    uint256 public constant FORK_BLOCK_DEFAULT = 339_673_828;
    uint256 public constant FORK_BLOCK_1 = 341_553_384;
    uint256 public constant FORK_BLOCK_2 = 340_833_501;
    uint256 public constant FORK_BLOCK_3 = 301_945_721;
    uint256 public constant FORK_BLOCK_4 = 341_593_396;

    // Oracle instance
    GmxBalanceOracle public oracle;

    // Real user addresses with positions in GMX
    address public constant TEST_USER = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    address public constant BTC_USER = 0x08c788aFdACF6cf81180D2bBBE42A7434D0C7A92;
    address public constant WHALE_USER1 = 0x91666112b851E33D894288A95846d14781e86cad;
    address public constant WHALE_USER2 = 0xe2823659bE02E0F48a4660e4Da008b5E1aBFdF29;

    function setUp() public override {
        // Note: Fork setup is done per-test since different tests use different blocks
        super.setUp();
    }

    // ============================================
    // Real Position Tests - WETH/USDC Short
    // ============================================

    function test_getOracleBalanceForAsset_WETH_WETH_Short_firstBlock() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_WETH_SHORT_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "WETH/USDC Short",
            address(balances)
        );

        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(TEST_USER, address(USDC));
        (uint256 amountWeth, bool isDebtWeth) = oracle.getOracleBalanceForAsset(TEST_USER, address(WETH));

        assertGt(amountUsdc, 0, "User should have positive USDC position");
        assertFalse(isDebtUsdc);
        assertGt(amountWeth, 0, "User should have WETH debt amount");
        assertTrue(isDebtWeth, "User should have WETH debt position (negative balance)");
    }

    function test_getOracleBalanceForAsset_WETH_WETH_Short_WithFees() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_2);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_WETH_SHORT_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "WETH/USDC Short",
            address(balances)
        );

        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(TEST_USER, address(USDC));
        (uint256 amountWeth, bool isDebtWeth) = oracle.getOracleBalanceForAsset(TEST_USER, address(WETH));

        assertGt(amountUsdc, 0, "User should have positive USDC position");
        assertFalse(isDebtUsdc);
        assertGt(amountWeth, 0, "User should have WETH debt amount");
        assertTrue(isDebtWeth, "User should have WETH debt position (negative balance)");
    }

    // ============================================
    // Real Position Tests - WETH/USDC Long
    // ============================================

    function test_getOracleBalanceForAsset_WETH_USDC_Long() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_3);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "WETH/USDC Long",
            address(balances)
        );

        (uint256 amountWeth, bool isDebtWeth) = oracle.getOracleBalanceForAsset(TEST_USER, address(WETH));
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(TEST_USER, address(USDC));

        assertGt(amountWeth, 0, "User should have positive WETH position");
        assertFalse(isDebtWeth);
        assertGt(amountUsdc, 0, "User should have USDC debt amount");
        assertTrue(isDebtUsdc, "User should have USDC debt position (negative balance)");
    }

    function test_getOracleBalanceForAsset_WETH_USDC_Long_Whale1() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_4);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "WETH/USDC Long",
            address(balances)
        );

        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(WHALE_USER1, address(USDC));
        (uint256 amountWeth, bool isDebtWeth) = oracle.getOracleBalanceForAsset(WHALE_USER1, address(WETH));

        assertTrue(isDebtUsdc, "User should have USDC debt position (negative balance)");
        assertGt(amountUsdc, 0, "User should have USDC debt amount");
        assertGt(amountWeth, 0, "User should have positive WETH position");
        assertFalse(isDebtWeth);
    }

    function test_getOracleBalanceForAsset_WETH_USDC_Long_Whale2() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_4);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "WETH/USDC Long",
            address(balances)
        );

        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(WHALE_USER2, address(USDC));
        (uint256 amountWeth, bool isDebtWeth) = oracle.getOracleBalanceForAsset(WHALE_USER2, address(WETH));

        assertTrue(isDebtUsdc, "User should have USDC debt position (negative balance)");
        assertGt(amountUsdc, 0, "User should have USDC debt amount");
        assertGt(amountWeth, 0, "User should have positive WETH position");
        assertFalse(isDebtWeth);
    }

    // ============================================
    // Real Position Tests - BTC/USDC Long
    // ============================================

    function test_getOracleBalanceForAsset_BTC_USDC_Long() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_2);

        address[] memory assets = new address[](2);
        assets[0] = address(BTC);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](4);
        feeds[0] = GmxBalanceOracle.TokenFeed(SYN_BTC, BTC_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);
        feeds[2] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);
        feeds[3] = GmxBalanceOracle.TokenFeed(address(BTC), BTC_USD);

        oracle = new GmxBalanceOracle(
            BTC_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "BTC/USDC Long",
            address(balances)
        );

        (uint256 amountBtc, bool isDebtBtc) = oracle.getOracleBalanceForAsset(BTC_USER, address(BTC));
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(BTC_USER, address(USDC));

        assertGt(amountBtc, 0, "User should have positive BTC position");
        assertFalse(isDebtBtc);
        assertTrue(isDebtUsdc, "User should have USDC debt position (negative balance)");
        assertGt(amountUsdc, 0, "User should have USDC debt amount");
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_DEFAULT);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](1);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);

        oracle = new GmxBalanceOracle(
            BTC_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "BTC/USDC Short",
            address(balances)
        );

        (uint256 amountWeth,) = oracle.getOracleBalanceForAsset(address(0), address(WETH));
        assertEq(amountWeth, 0);

        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(address(0), address(USDC));
        assertEq(amountUsdc, 0);
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalance_aggregatesPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_WETH_SHORT_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "WETH/USDC Short",
            address(balances)
        );

        (address[] memory resultAssets, uint256[] memory amounts,) = oracle.getOracleBalances(TEST_USER);

        // Should have at least WETH and USDC positions
        assertGe(resultAssets.length, 2, "Should have multiple positions");
        assertEq(resultAssets.length, amounts.length, "Arrays should match length");
    }

    function test_getOraclePositions_returnsCorrectPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("arb-mainnet"), FORK_BLOCK_1);

        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        balances = _deployBalancesForOracle(assets);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_WETH_SHORT_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "WETH/USDC Short",
            address(balances)
        );

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
