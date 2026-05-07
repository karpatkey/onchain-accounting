// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";

import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Id, MarketParams, Market, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
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

/// @title MorphoMarketBalanceOracleUnitTest
/// @notice Unit tests using MockMorpho (no fork).
contract MorphoMarketBalanceOracleUnitTest is BalanceAdapterTestBase {
    MorphoMarketBalanceOracle public oracle;
    MockMorpho public mockMorpho;
    bytes32 public marketId;

    function setUp() public override {
        super.setUp();
        MarketParams memory params = MarketParams({
            loanToken: address(usdc), collateralToken: address(weth), oracle: address(1), irm: address(0), lltv: 1e18
        });
        marketId = Id.unwrap(MarketParamsLib.id(params));
        mockMorpho = new MockMorpho(params);
        oracle = new MorphoMarketBalanceOracle(address(mockMorpho), marketId, "Morpho - Mock", "{\"protocol\":\"Morpho\",\"product\":\"Market\"", "0x0000000000000000000000000000000000000001", address(balances));
    }

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedToken_reverts() public {
        address unsupported = address(1);
        vm.expectRevert(InvalidArguments.selector);
        oracle.getOracleBalanceForAsset(alice, unsupported);
    }

    function test_getOracleBalanceForAsset_zeroPosition_returnsZero() public view {
        (uint256 amountUsdc,) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amountUsdc, 0);
        (uint256 amountWeth,) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amountWeth, 0);
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
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }
}
