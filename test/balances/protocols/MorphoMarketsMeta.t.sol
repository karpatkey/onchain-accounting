// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/protocols/MorphoMarketsMeta.sol";
import {MockMorpho} from "test/balances/protocols/MorphoMarket.t.sol";
import {Id, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title MorphoMarketsMetaBalanceAdapter unit tests (MockMorpho, no fork)
contract MorphoMarketsMetaUnitTest is BalanceAdapterTestBase {
    MorphoMarketsMetaBalanceAdapter public oracle;
    MockMorpho public mockMorpho;
    bytes32 public marketId;

    // 1 share = 1 asset on each side, so amounts equal share counts directly.
    uint128 internal constant TOTAL_SUPPLY_ASSETS = 1_000_000e6;
    uint128 internal constant TOTAL_SUPPLY_SHARES = 1_000_000e6;
    uint128 internal constant TOTAL_BORROW_ASSETS = 500_000e6;
    uint128 internal constant TOTAL_BORROW_SHARES = 500_000e6;

    function setUp() public override {
        super.setUp();
        // loan = USDC, collateral = WETH; irm = address(0) so expectedMarketBalances returns stored values.
        MarketParams memory params = MarketParams({
            loanToken: address(usdc), collateralToken: address(weth), oracle: address(1), irm: address(0), lltv: 1e18
        });
        marketId = Id.unwrap(MarketParamsLib.id(params));
        mockMorpho = new MockMorpho(params);
        mockMorpho.setMarket(TOTAL_SUPPLY_ASSETS, TOTAL_SUPPLY_SHARES, TOTAL_BORROW_ASSETS, TOTAL_BORROW_SHARES);

        oracle = new MorphoMarketsMetaBalanceAdapter(address(mockMorpho), "Morpho", address(balances));
    }

    function _ids() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = marketId;
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IMetaBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_empty() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        // No instances configured on the (mock) NAV registry, so the no-arg path returns empty.
        assertEq(oracle.getOraclePositions(alice, address(0)).length, 0);
        (address[] memory a,,) = oracle.getOracleBalances(alice);
        assertEq(a.length, 0);
    }

    function test_threeLegs_grossEmission() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 3);

        // Order: collateral, loan-supply, loan-borrow.
        assertEq(pos[0].balanceAsset.asset, address(weth));
        assertEq(pos[0].amount, 2e18);
        assertFalse(pos[0].isDebt);

        assertEq(pos[1].balanceAsset.asset, address(usdc));
        assertEq(pos[1].amount, 100e6);
        assertFalse(pos[1].isDebt);

        assertEq(pos[2].balanceAsset.asset, address(usdc));
        assertEq(pos[2].amount, 50e6);
        assertTrue(pos[2].isDebt);

        // Identity derived on-chain: marketId hex + collateral/loan symbols.
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceOracle, address(oracle));
        }
    }

    function test_assetFilter_loanToken_returnsSupplyAndBorrow() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _ids(), address(usdc));
        assertEq(pos.length, 2);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertFalse(pos[0].isDebt);
        assertEq(pos[1].balanceAsset.asset, address(usdc));
        assertTrue(pos[1].isDebt);
    }

    function test_assetFilter_collateral_returnsCollateralOnly() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(alice, _ids(), address(weth));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(weth));
    }

    function test_noPosition_empty() public view {
        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = oracle.underlyingAssetsSupportedForInstances(_ids());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth)); // collateral
        assertEq(assets[1], address(usdc)); // loan
    }
}
