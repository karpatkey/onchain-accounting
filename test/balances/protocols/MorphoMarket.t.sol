// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";

import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract MorphoMarketTest is TestEnvConfigurator, TestSetupHelpers {
    uint256 public fork;
    uint256 public forkBlock;

    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public wsteth = (0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address mkr = address(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2);

    MorphoMarketBalanceOracle public oracle;
    MockBalances mockBalances;
    BalancesHarnessForFork public balances;

    // Global user addresses with positions in Morpho
    address public supplyUsdcUser;
    address public borrowUsdcUser;

    function setUp() public {
        mockBalances = new MockBalances();

        // Set global user addresses - use addresses that have positions
        supplyUsdcUser = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;
        borrowUsdcUser = 0x06bF1e959eDad7e1F7003a9Fa122233F1Bd22f34;
    }

    function test_mainnet_balanceOf_supply_usdc() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_361_884);
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assets = new address[](2);
        assets[0] = wsteth;
        assets[1] = usdc;
        balances = deployBalancesInFork(assets);

        oracle =
            new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, "Morpho", "Some market", address(balances));
        int256 balance = oracle.getOracleBalanceForAsset(supplyUsdcUser, usdc);
        assertGt(balance, 0, "User should have USDC supply position");
    }

    function test_mainnet_balanceOf_borrowUsdc() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_728_491);
        bytes32 id = 0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assets = new address[](3);
        assets[0] = usdc;
        assets[1] = dai;
        assets[2] = mkr;
        balances = deployBalancesInFork(assets);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, "Morpho", "Some market", address(balances));

        int256 balanceUsdc = oracle.getOracleBalanceForAsset(borrowUsdcUser, usdc);
        assertLt(balanceUsdc, 0, "User should have USDC borrow position");
    }

    function test_mainnet_balanceOf_collateralMKR() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_728_491);
        bytes32 id = 0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assets = new address[](3);
        assets[0] = usdc;
        assets[1] = dai;
        assets[2] = mkr;
        balances = deployBalancesInFork(assets);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, "Morpho", "Some market", address(balances));

        int256 balanceMkr = oracle.getOracleBalanceForAsset(borrowUsdcUser, mkr);
        assertGt(balanceMkr, 0, "User should have MKR collateral position");
    }

    function test_mainnet_balanceOf_unsupportedToken() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_728_491);
        bytes32 id = 0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assets = new address[](3);
        assets[0] = usdc;
        assets[1] = dai;
        assets[2] = mkr;
        balances = deployBalancesInFork(assets);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, "Morpho", "Some market", address(balances));

        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(borrowUsdcUser, address(0));
        assertEq(balance, 0);
    }

    function test_underlyingAssetsSupported() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_361_884);
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assetsToRegister = new address[](2);
        assetsToRegister[0] = wsteth;
        assetsToRegister[1] = usdc;
        balances = deployBalancesInFork(assetsToRegister);

        oracle =
            new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, "Morpho", "Some market", address(balances));
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], wsteth);
        assertEq(assets[1], usdc);
    }

    function test_collateralAndLoanTokens() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_361_884);
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assetsToRegister = new address[](2);
        assetsToRegister[0] = wsteth;
        assetsToRegister[1] = usdc;
        balances = deployBalancesInFork(assetsToRegister);

        oracle =
            new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, "Morpho", "Some market", address(balances));
        assertEq(oracle.COLLATERAL_TOKEN(), wsteth);
        assertEq(oracle.LOAN_TOKEN(), usdc);
    }
}
