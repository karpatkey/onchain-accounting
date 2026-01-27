// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";

import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Id, MarketParams, Market, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import "src/errors.sol";

/// @notice Mock Morpho that returns a single market's params, zero position, and zero market state for unit tests (no fork).
/// Implements only idToMarketParams, position, and market used by MorphoMarketBalanceOracle and MorphoBalancesLib.
contract MockMorpho {
    using MarketParamsLib for MarketParams;

    MarketParams private _marketParams;
    Id private _id;

    constructor(MarketParams memory marketParams) {
        _marketParams = marketParams;
        _id = marketParams.id();
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        require(Id.unwrap(id) == Id.unwrap(_id), "unknown market");
        return _marketParams;
    }

    function position(Id, address) external pure returns (Position memory) {
        return Position({supplyShares: 0, borrowShares: 0, collateral: 0});
    }

    function market(Id) external view returns (Market memory) {
        return Market({
            totalSupplyAssets: 0,
            totalSupplyShares: 0,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
    }
}

contract MorphoMarketTest is TestEnvConfigurator, TestSetupHelpers {
    uint256 public fork;
    uint256 public forkBlock;

    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public wsteth = (0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address mkr = address(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2);

    MorphoMarketBalanceOracle public oracle;
    BalancesHarnessForFork public balances;

    // Global user addresses with positions in Morpho
    address public supplyUsdcUser;
    address public borrowUsdcUser;

    function setUp() public {
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

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, "Morpho - wstETH/USDC", address(balances));
        int256 balance = oracle.getOracleBalanceForAsset(supplyUsdcUser, usdc);
        assertGt(balance, 0, "User should have USDC supply position (positive balance)");
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

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, "Morpho - USDC/DAI/MKR", address(balances));

        int256 balanceUsdc = oracle.getOracleBalanceForAsset(borrowUsdcUser, usdc);
        assertLt(balanceUsdc, 0, "User should have USDC borrow position (negative balance)");
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

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, "Morpho - USDC/DAI/MKR", address(balances));

        int256 balanceMkr = oracle.getOracleBalanceForAsset(borrowUsdcUser, mkr);
        assertGt(balanceMkr, 0, "User should have MKR collateral position (positive balance)");
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

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, id, "Morpho - USDC/DAI/MKR", address(balances));

        // MorphoMarket reverts InvalidArguments for unsupported or zero asset (same as unit test)
        vm.expectRevert(InvalidArguments.selector);
        oracle.getOracleBalanceForAsset(borrowUsdcUser, address(0));
    }

    function test_underlyingAssetsSupported() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), 20_361_884);
        bytes32 idWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

        address morphoMainnet = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

        address[] memory assetsToRegister = new address[](2);
        assetsToRegister[0] = wsteth;
        assetsToRegister[1] = usdc;
        balances = deployBalancesInFork(assetsToRegister);

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, "Morpho - wstETH/USDC", address(balances));
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

        oracle = new MorphoMarketBalanceOracle(morphoMainnet, idWsethUsdc, "Morpho - wstETH/USDC", address(balances));
        assertEq(oracle.COLLATERAL_TOKEN(), wsteth);
        assertEq(oracle.LOAN_TOKEN(), usdc);
    }
}

/// @title MorphoMarketBalanceOracleUnitTest
/// @notice Unit tests using MockMorpho (no fork).
contract MorphoMarketBalanceOracleUnitTest is BalanceAdapterTestBase {
    MorphoMarketBalanceOracle public oracle;
    MockMorpho public mockMorpho;
    bytes32 public marketId;

    function setUp() public override {
        super.setUp();
        MarketParams memory params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(weth),
            oracle: address(1),
            irm: address(0),
            lltv: 1e18
        });
        marketId = Id.unwrap(MarketParamsLib.id(params));
        mockMorpho = new MockMorpho(params);
        oracle = new MorphoMarketBalanceOracle(
            address(mockMorpho),
            marketId,
            "Morpho - Mock",
            address(balances)
        );
    }

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        int256 balance = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(balance, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedToken_reverts() public {
        address unsupported = address(1);
        vm.expectRevert(InvalidArguments.selector);
        oracle.getOracleBalanceForAsset(alice, unsupported);
    }

    function test_getOracleBalanceForAsset_zeroPosition_returnsZero() public view {
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(balanceUsdc, 0);
        int256 balanceWeth = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(balanceWeth, 0);
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth));
        assertEq(assets[1], address(usdc));
    }

    function test_collateralAndLoanTokens() public view {
        assertEq(oracle.COLLATERAL_TOKEN(), address(weth));
        assertEq(oracle.LOAN_TOKEN(), address(usdc));
    }

    function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, int256[] memory amounts) = oracle.getOracleBalance(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions =
            oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }
}
