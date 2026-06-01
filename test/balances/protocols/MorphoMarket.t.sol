// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";

import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Id, MarketParams, Market, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Mock Morpho with configurable per-user `Position` and per-market `Market` state.
/// @dev Implements only `idToMarketParams`, `position`, and `market` — the surface used by
///      `MorphoMarketBalanceOracle` and `MorphoBalancesLib.expectedMarketBalances`. Constructor wires a single
///      market; `setPosition` / `setMarket` let individual tests exercise specific share/asset combinations.
///      Setting `marketParams.irm = address(0)` (default in the test setUp) makes
///      `expectedMarketBalances` skip the IRM accrual and return the stored `Market` values verbatim.
contract MockMorpho {
    using MarketParamsLib for MarketParams;

    MarketParams private _marketParams;
    Id private _id;
    Market private _market;
    mapping(address => Position) private _positions;

    constructor(MarketParams memory marketParams) {
        _marketParams = marketParams;
        _id = marketParams.id();
        _market.lastUpdate = uint128(block.timestamp);
    }

    function setPosition(address user, uint256 supplyShares, uint128 borrowShares, uint128 collateral) external {
        _positions[user] = Position({supplyShares: supplyShares, borrowShares: borrowShares, collateral: collateral});
    }

    function setMarket(
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares
    ) external {
        _market.totalSupplyAssets = totalSupplyAssets;
        _market.totalSupplyShares = totalSupplyShares;
        _market.totalBorrowAssets = totalBorrowAssets;
        _market.totalBorrowShares = totalBorrowShares;
        _market.lastUpdate = uint128(block.timestamp);
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        require(Id.unwrap(id) == Id.unwrap(_id), "unknown market");
        return _marketParams;
    }

    function position(Id, address user) external view returns (Position memory) {
        return _positions[user];
    }

    function market(Id) external view returns (Market memory) {
        return _market;
    }
}

/// @title MorphoMarketBalanceOracleUnitTest
/// @notice Unit tests using MockMorpho (no fork).
/// @dev The mock lets each test configure `Position` (per user) and `Market` (per market) independently
///      so we can exercise every combination of `{supplyShares, borrowShares, collateral}` non-zero legs
///      and confirm the adapter's gross emission shape.
contract MorphoMarketBalanceOracleUnitTest is BalanceAdapterTestBase {
    MorphoMarketBalanceOracle public oracle;
    MockMorpho public mockMorpho;
    bytes32 public marketId;

    // Share-vs-assets ratio used by tests: 1 share = 1 asset (totalShares == totalAssets on each side).
    // Keeps the arithmetic trivial so test amounts equal share counts directly.
    uint128 internal constant TOTAL_SUPPLY_ASSETS = 1_000_000e6;
    uint128 internal constant TOTAL_SUPPLY_SHARES = 1_000_000e6;
    uint128 internal constant TOTAL_BORROW_ASSETS = 500_000e6;
    uint128 internal constant TOTAL_BORROW_SHARES = 500_000e6;

    function setUp() public override {
        super.setUp();
        MarketParams memory params = MarketParams({
            loanToken: address(usdc), collateralToken: address(weth), oracle: address(1), irm: address(0), lltv: 1e18
        });
        marketId = Id.unwrap(MarketParamsLib.id(params));
        mockMorpho = new MockMorpho(params);
        mockMorpho.setMarket(TOTAL_SUPPLY_ASSETS, TOTAL_SUPPLY_SHARES, TOTAL_BORROW_ASSETS, TOTAL_BORROW_SHARES);

        oracle = new MorphoMarketBalanceOracle(address(mockMorpho), marketId, address(balances));
    }

    // ============================================
    // Pre-existing sanity / edge-case tests
    // ============================================

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

    // ============================================
    // Gross emission — single-leg cases
    // ============================================

    function test_getOraclePositions_supplyOnly_emitsOneLoanRow() public {
        // Alice supplies 100 USDC (the loan token), no borrow, no collateral
        mockMorpho.setPosition(alice, 100e6, 0, 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 1, "should emit exactly one row");
        assertEq(positions[0].balanceAsset.asset, address(usdc), "row asset is loan token");
        assertEq(positions[0].amount, 100e6, "amount = supplied assets");
        assertFalse(positions[0].isDebt, "supply row is credit");
    }

    function test_getOraclePositions_borrowOnly_emitsOneLoanRow() public {
        // Alice borrows 50 USDC, no supply, no collateral (synthetic — illegal on real Morpho but mock-OK)
        mockMorpho.setPosition(alice, 0, 50e6, 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 1, "should emit exactly one row");
        assertEq(positions[0].balanceAsset.asset, address(usdc), "row asset is loan token");
        assertEq(positions[0].amount, 50e6, "amount = borrowed assets");
        assertTrue(positions[0].isDebt, "borrow row is debt");
    }

    function test_getOraclePositions_collateralOnly_emitsOneCollateralRow() public {
        // Alice posts 2 WETH as collateral, no supply, no borrow
        mockMorpho.setPosition(alice, 0, 0, 2 ether);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 1, "should emit exactly one row");
        assertEq(positions[0].balanceAsset.asset, address(weth), "row asset is collateral token");
        assertEq(positions[0].amount, 2 ether, "amount = collateral");
        assertFalse(positions[0].isDebt, "collateral row is credit");
    }

    // ============================================
    // Gross emission — multi-leg cases (the headline fix)
    // ============================================

    function test_getOraclePositions_supplyAndBorrow_emitsTwoLoanRowsGross() public {
        // Alice simultaneously supplies 100 USDC AND borrows 30 USDC on the same market.
        // This is the case Morpho's old net emission collapsed into one row.
        // Expected: TWO separate loan-token rows distinguished only by `isDebt`.
        mockMorpho.setPosition(alice, 100e6, 30e6, 0);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 2, "should emit two loan-token rows (gross, not netted)");

        // Find the supply and borrow rows (order is supply-first per the adapter's emission)
        bool sawSupply;
        bool sawBorrow;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(usdc), "both rows are on the loan token");
            if (!positions[i].isDebt) {
                assertEq(positions[i].amount, 100e6, "supply row amount untouched (not netted)");
                sawSupply = true;
            } else {
                assertEq(positions[i].amount, 30e6, "borrow row amount untouched (not netted)");
                sawBorrow = true;
            }
        }
        assertTrue(sawSupply, "supply row present");
        assertTrue(sawBorrow, "borrow row present");
    }

    function test_getOraclePositions_collateralAndBorrow_emitsTwoRows() public {
        // The typical Morpho borrower: collateral + borrow, no supply
        mockMorpho.setPosition(alice, 0, 50e6, 1 ether);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 2, "should emit collateral + borrow rows");

        bool sawCollateral;
        bool sawBorrow;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAsset.asset == address(weth)) {
                assertFalse(positions[i].isDebt);
                assertEq(positions[i].amount, 1 ether);
                sawCollateral = true;
            } else if (positions[i].balanceAsset.asset == address(usdc)) {
                assertTrue(positions[i].isDebt);
                assertEq(positions[i].amount, 50e6);
                sawBorrow = true;
            }
        }
        assertTrue(sawCollateral, "collateral row present");
        assertTrue(sawBorrow, "borrow row present");
    }

    function test_getOraclePositions_allThreeLegs_emitsThreeRows() public {
        // Worst-case: collateral + supply + borrow all non-zero on the same market
        mockMorpho.setPosition(alice, 100e6, 30e6, 2 ether);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 3, "should emit three rows: collateral, supply, borrow");

        // Verify all three legs distinguishable
        bool sawCollateral;
        bool sawSupply;
        bool sawBorrow;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAsset.asset == address(weth) && !positions[i].isDebt) {
                assertEq(positions[i].amount, 2 ether);
                sawCollateral = true;
            } else if (positions[i].balanceAsset.asset == address(usdc) && !positions[i].isDebt) {
                assertEq(positions[i].amount, 100e6);
                sawSupply = true;
            } else if (positions[i].balanceAsset.asset == address(usdc) && positions[i].isDebt) {
                assertEq(positions[i].amount, 30e6);
                sawBorrow = true;
            }
        }
        assertTrue(sawCollateral, "collateral row present");
        assertTrue(sawSupply, "supply row present");
        assertTrue(sawBorrow, "borrow row present");
    }

    // ============================================
    // Asset filter behavior
    // ============================================

    function test_getOraclePositions_assetFilter_loanToken_returnsOnlyLoanRows() public {
        mockMorpho.setPosition(alice, 100e6, 30e6, 2 ether);

        // Filter to loan token only — should get supply + borrow but NOT collateral
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(usdc));

        assertEq(positions.length, 2, "filter to loan token returns supply + borrow");
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(usdc), "all filtered rows are loan token");
        }
    }

    function test_getOraclePositions_assetFilter_collateralToken_returnsOnlyCollateralRow() public {
        mockMorpho.setPosition(alice, 100e6, 30e6, 2 ether);

        // Filter to collateral token only — should get just the collateral row
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(weth));

        assertEq(positions.length, 1, "filter to collateral token returns one row");
        assertEq(positions[0].balanceAsset.asset, address(weth));
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].amount, 2 ether);
    }

    function test_getOraclePositions_assetFilter_unsupportedAsset_returnsEmpty() public {
        mockMorpho.setPosition(alice, 100e6, 30e6, 2 ether);

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0xdead));

        assertEq(positions.length, 0, "filter to unsupported asset returns empty");
    }

    // ============================================
    // Simple-getter back-compat: still nets the loan token
    // ============================================

    function test_getOracleBalanceForAsset_supplyAndBorrow_netsLoanToken_creditDirection() public {
        // 100 supplied, 30 borrowed → net 70 credit
        mockMorpho.setPosition(alice, 100e6, 30e6, 0);

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 70e6, "net = 100 - 30 = 70");
        assertFalse(isDebt, "net credit");
    }

    function test_getOracleBalanceForAsset_supplyAndBorrow_netsLoanToken_debtDirection() public {
        // 30 supplied, 100 borrowed → net 70 debt
        mockMorpho.setPosition(alice, 30e6, 100e6, 0);

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 70e6, "net = |30 - 100| = 70");
        assertTrue(isDebt, "net debt");
    }

    function test_getOracleBalances_supplyAndBorrow_returnsOneNetEntry() public {
        mockMorpho.setPosition(alice, 100e6, 30e6, 2 ether);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);

        // Simple getter returns one entry per asset (netted on loan token)
        // Expected: collateral entry (WETH) and netted loan entry (USDC)
        assertEq(assets.length, 2);
        assertEq(amounts.length, 2);
        assertEq(isDebt.length, 2);

        // Order matches `underlyingAssetsSupported()`: [collateral, loan]
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 2 ether);
        assertFalse(isDebt[0]);

        assertEq(assets[1], address(usdc));
        assertEq(amounts[1], 70e6, "loan token netted to 70");
        assertFalse(isDebt[1]);
    }
}
