// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {MockMorpho} from "test/balances/MetaBalanceAdapters/MorphoMocks.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Id, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title MorphoMarketsMetaBalanceAdapter unit tests (MockMorpho, no fork)
contract MorphoMarketsMetaUnitTest is BalanceAdapterTestBase {
    MorphoMarketsMetaBalanceAdapter public adapter;
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

        adapter = new MorphoMarketsMetaBalanceAdapter(address(mockMorpho), address(balances));
    }

    function _ids() internal view returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = marketId;
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_noArgMethods_empty() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        // No instances configured on the (mock) NAV registry, so the no-arg path returns empty.
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
        (address[] memory a,,) = adapter.getAdapterBalances(alice);
        assertEq(a.length, 0);
    }

    function test_threeLegs_grossEmission() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
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
            assertEq(pos[i].balanceAdapter, address(adapter));
        }
    }

    function test_assetFilter_loanToken_returnsSupplyAndBorrow() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(usdc));
        assertEq(pos.length, 2);
        assertEq(pos[0].balanceAsset.asset, address(usdc));
        assertFalse(pos[0].isDebt);
        assertEq(pos[1].balanceAsset.asset, address(usdc));
        assertTrue(pos[1].isDebt);
    }

    function test_assetFilter_collateral_returnsCollateralOnly() public {
        mockMorpho.setPosition(alice, 100e6, 50e6, 2e18);
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(alice, _ids(), address(weth));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(weth));
    }

    function test_noPosition_empty() public view {
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(alice, _ids(), address(0));
        assertEq(pos.length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(_ids());
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth)); // collateral
        assertEq(assets[1], address(usdc)); // loan
    }

    /// @dev A borrow the adapter cannot report (loan token not a registered asset) must suppress the whole
    ///      market position: emitting the collateral leg alone would count it as pure credit and over-report
    ///      NAV by the entire borrow.
    function test_unreportableLoanToken_suppressesWholePosition() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18); // deliberately NOT registered
        MarketParams memory params = MarketParams({
            loanToken: address(unregistered),
            collateralToken: address(weth),
            oracle: address(1),
            irm: address(0),
            lltv: 1e18
        });
        MockMorpho m2 = new MockMorpho(params);
        m2.setMarket(TOTAL_SUPPLY_ASSETS, TOTAL_SUPPLY_SHARES, TOTAL_BORROW_ASSETS, TOTAL_BORROW_SHARES);
        m2.setPosition(alice, 0, 1e18, 5e18); // borrowShares > 0, WETH collateral
        MorphoMarketsMetaBalanceAdapter a2 =
            new MorphoMarketsMetaBalanceAdapter(address(m2), "Morpho", address(balances));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Id.unwrap(MarketParamsLib.id(params));

        assertEq(
            a2.getAdapterPositionsForInstances(alice, ids, address(0)).length,
            0,
            "collateral must not be reported without the unreportable borrow"
        );
        assertEq(
            a2.getAdapterPositionsForInstances(alice, ids, address(weth)).length,
            0,
            "assetFilter must not resurrect the unoffset collateral leg"
        );
    }

    /// @dev The mirror case: with NO borrow, an unregistered loan token is harmless — the collateral leg is
    ///      still correct on its own and must keep being reported.
    function test_unreportableLoanToken_noBorrow_stillReportsCollateral() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18);
        MarketParams memory params = MarketParams({
            loanToken: address(unregistered),
            collateralToken: address(weth),
            oracle: address(1),
            irm: address(0),
            lltv: 1e18
        });
        MockMorpho m2 = new MockMorpho(params);
        m2.setMarket(TOTAL_SUPPLY_ASSETS, TOTAL_SUPPLY_SHARES, TOTAL_BORROW_ASSETS, TOTAL_BORROW_SHARES);
        m2.setPosition(alice, 0, 0, 5e18); // no borrow
        MorphoMarketsMetaBalanceAdapter a2 =
            new MorphoMarketsMetaBalanceAdapter(address(m2), "Morpho", address(balances));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Id.unwrap(MarketParamsLib.id(params));
        assertEq(a2.getAdapterPositionsForInstances(alice, ids, address(0)).length, 1, "collateral still reported");
    }

    /// @dev The suppression must key on a REALISED borrow, not raw shares: a degenerate market where
    ///      totalBorrowAssets is 0 while shares remain (bad-debt seizure) would otherwise erase a healthy
    ///      collateral position over a borrow of zero.
    function test_unreportableLoanToken_zeroRealisedBorrow_stillReportsCollateral() public {
        Mock_ERC20 unregistered = new Mock_ERC20("XYZ", 18);
        MarketParams memory params = MarketParams({
            loanToken: address(unregistered),
            collateralToken: address(weth),
            oracle: address(1),
            irm: address(0),
            lltv: 1e18
        });
        MockMorpho m2 = new MockMorpho(params);
        m2.setMarket(TOTAL_SUPPLY_ASSETS, TOTAL_SUPPLY_SHARES, 0, TOTAL_BORROW_SHARES); // 0 borrow assets
        m2.setPosition(alice, 0, 1e18, 5e18); // shares outstanding, realised borrow rounds to 0
        MorphoMarketsMetaBalanceAdapter a2 =
            new MorphoMarketsMetaBalanceAdapter(address(m2), "Morpho", address(balances));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Id.unwrap(MarketParamsLib.id(params));
        assertEq(
            a2.getAdapterPositionsForInstances(alice, ids, address(0)).length,
            1,
            "zero realised borrow must not suppress the collateral leg"
        );
    }
}
