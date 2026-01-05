// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "src/errors.sol";

contract MorphoMarketTest is Test {
    uint256 public fork;
    uint256 public forkBlock;

    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public wsteth = (0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address mkr = address(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2);

    MorphoMarketBalanceOracle public oracle;
    IBalanceOracleCustom.PositionMetadata morphoMetadata =
        IBalanceOracleCustom.PositionMetadata({protocol: "Morpho", position: "Some market", positionType: "Supplied"});

    function setUp() public {
        fork = vm.createFork(vm.envString("MAINNET_URL"));
        vm.selectFork(fork);
    }

    function test_mainnet_balanceOf_supply_usdc() public {
        vm.rollFork(20_361_884);
        address user = address(0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B);
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, morphoMetadata);
        int256 balance = oracle.balanceOf(usdc, user);
        assertEq(balance, 25_066_203_870);
    }

    function test_mainnet_balanceOf_borrowUsdc() public {
        vm.rollFork(20_728_491);
        address user = address(0x06bF1e959eDad7e1F7003a9Fa122233F1Bd22f34);
        bytes32 id = 0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, morphoMetadata);

        int256 balanceUSDC = oracle.balanceOf(usdc, user);
        assertEq(balanceUSDC, -9_478_607_678_615);
    }

    function test_mainnet_balanceOf_collateralMKR() public {
        vm.rollFork(20_728_491);
        address user = address(0x06bF1e959eDad7e1F7003a9Fa122233F1Bd22f34);
        bytes32 id = 0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, morphoMetadata);

        int256 balanceMKR = oracle.balanceOf(mkr, user);
        assertEq(balanceMKR, 15_235_145_753_614_569_323_332);
    }

    function test_mainnet_balanceOf_unsupportedToken() public {
        vm.rollFork(20_728_491);
        address user = address(0x06bF1e959eDad7e1F7003a9Fa122233F1Bd22f34);
        bytes32 id = 0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, morphoMetadata);

        vm.expectRevert(InvalidArguments.selector);
        oracle.balanceOf(address(0), user);
    }

    function test_underlyingAssetsSupported() public {
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, morphoMetadata);
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], wsteth);
        assertEq(assets[1], usdc);
    }

    function test_collateralAndLoanTokens() public {
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, morphoMetadata);
        assertEq(oracle.collateralToken(), wsteth);
        assertEq(oracle.loanToken(), usdc);
    }
}
