// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol";
import {MockMorpho} from "test/balances/MetaBalanceAdapters/MorphoMocks.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Id, Market, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
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
        MorphoMarketsMetaBalanceAdapter a2 = new MorphoMarketsMetaBalanceAdapter(address(m2), address(balances));

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
        MorphoMarketsMetaBalanceAdapter a2 = new MorphoMarketsMetaBalanceAdapter(address(m2), address(balances));

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
        MorphoMarketsMetaBalanceAdapter a2 = new MorphoMarketsMetaBalanceAdapter(address(m2), address(balances));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Id.unwrap(MarketParamsLib.id(params));
        assertEq(
            a2.getAdapterPositionsForInstances(alice, ids, address(0)).length,
            1,
            "zero realised borrow must not suppress the collateral leg"
        );
    }

    /// @dev `positionLabels` is display-only and must never revert, and must never label a coordinate this adapter
    ///      never emitted. Both were reachable before: `abi.decode(pid, (address))` reverts on a word with dirty
    ///      upper 96 bits, and a `pid.length < 32` guard let a foreign MULTI-word coordinate through to be labelled
    ///      from its first word. The decode now goes through `MetaBalanceAdapter._pidWord`, whose own accept window is
    ///      pinned exhaustively in `test/balances/MetaBalanceAdapterPidGuards.t.sol`; this case pins that THIS
    ///      adapter routes through it.
    ///
    ///      The clean-coordinate assertion is what keeps the rest load-bearing. A shape-valid but unknown
    ///      coordinate still resolves to the category-only label (the fail-open leaf collapse), so a view that
    ///      rejected everything would fail here rather than pass the rejections trivially.

    function test_positionLabels_malformedPositionId_returnsEmpty() public view {
        // High bits deliberately SET. A Morpho marketId is a keccak hash, so essentially every real coordinate has
        // `raw >> 160 != 0` — which is exactly why this adapter uses `_pidWord` and not the range-checked
        // `_pidAddress`. Using a small word here instead would let a regression that swapped the two helpers pass.
        bytes32 coord = marketId;
        assertTrue(uint256(coord) >> 160 != 0, "a real marketId has bits above 160");

        assertGt(adapter.positionLabels(abi.encode(coord)).length, 0, "one full word is the accepted shape");

        assertEq(adapter.positionLabels("").length, 0, "empty");
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0, "truncated");
        assertEq(adapter.positionLabels(abi.encode(coord, uint256(1))).length, 0, "over-long");
    }

    /// @dev The real `Morpho.idToMarketParams` is a plain mapping getter: for an id with NO market it returns an
    ///      all-zero `MarketParams` and does NOT revert, so `positionLabels`' `catch` arm never fires. Without the
    ///      `loanToken != address(0)` gate both symbol reads fail open to "?" and the adapter answers
    ///      `["Market", "?/?"]` — a confident two-segment breadcrumb, byte-identical to a real market whose tokens
    ///      both have unreadable symbols, for a market that does not exist. That is precisely the over-claim the
    ///      positionId guards exist to prevent, reached one layer deeper.
    ///
    ///      `MockMorpho` cannot show this: it `require`s a known id, so it reverts and the `catch` arm hides the
    ///      path. This test therefore uses a getter-shaped mock that mirrors real Morpho.
    ///
    ///      Load-bearing: drop the existence gate and the first assertion sees 2 labels, not 1.
    function test_positionLabels_unknownMarketId_collapsesToCategory() public {
        MockMorphoZeroGetter zeroMorpho = new MockMorphoZeroGetter();
        MorphoMarketsMetaBalanceAdapter a = new MorphoMarketsMetaBalanceAdapter(address(zeroMorpho), address(balances));

        string[] memory unknown = a.positionLabels(abi.encode(bytes32(uint256(keccak256("nope")))));
        assertEq(unknown.length, 1, "an id with no market must not render a token pair");
        assertEq(unknown[0], "Market");

        // A market that DOES exist still renders its pair, so the collapse above is about the missing market and
        // not about the guard blanking every label.
        zeroMorpho.setMarket(bytes32(uint256(1)), address(weth), address(usdc));
        string[] memory known = a.positionLabels(abi.encode(bytes32(uint256(1))));
        assertEq(known.length, 2);
        assertEq(known[0], "Market");
    }

    /// @notice Params alone do not make a market: an id with a full `MarketParams` but `lastUpdate == 0` must
    ///         still collapse to the category.
    /// @dev This is the case that separates the enforced invariant from the practical one, and the reason the
    ///      gate reads `market(id).lastUpdate` rather than `loanToken != address(0)`. `createMarket` validates
    ///      only `isIrmEnabled`, `isLltvEnabled` and `lastUpdate == 0` — it never rejects a zero `loanToken` — so
    ///      "every real market has a loanToken" is a property of the markets that happen to exist, not one the
    ///      protocol guarantees. Stamping `lastUpdate` is what creation actually does.
    ///
    ///      Mutation check: restore the `loanToken != address(0)` gate and this returns 2 labels.
    function test_positionLabels_paramsWithoutCreation_collapsesToCategory() public {
        MockMorphoZeroGetter zeroMorpho = new MockMorphoZeroGetter();
        MorphoMarketsMetaBalanceAdapter a = new MorphoMarketsMetaBalanceAdapter(address(zeroMorpho), address(balances));

        zeroMorpho.setParamsWithoutCreating(bytes32(uint256(7)), address(weth), address(usdc));

        string[] memory out = a.positionLabels(abi.encode(bytes32(uint256(7))));
        assertEq(out.length, 1, "params without creation must not render a token pair");
        assertEq(out[0], "Market");
    }

    /// @notice A reverting existence read must degrade to the category, not propagate out of `positionLabels`.
    /// @dev The boundary is easy to get wrong and the mistake is silent in review: the body of a `try` executes in
    ///      the CALLER's frame, so an external call placed inside the success arm of another `try` is not covered
    ///      by that `try`'s `catch`. Written that way, a Morpho deployment not answering `market(Id)` would revert
    ///      this view instead of dropping one leaf. Each read gets its own boundary; this pins that.
    function test_positionLabels_revertingExistenceRead_failsOpen() public {
        MockMorphoNoMarketGetter broken = new MockMorphoNoMarketGetter();
        MorphoMarketsMetaBalanceAdapter a = new MorphoMarketsMetaBalanceAdapter(address(broken), address(balances));

        string[] memory out = a.positionLabels(abi.encode(bytes32(uint256(1))));
        assertEq(out.length, 1, "a reverting existence read must degrade, not revert the view");
        assertEq(out[0], "Market");
    }
}

/// @notice Morpho-shaped mock that answers `idToMarketParams` but reverts on `market(Id)`.
/// @dev Stands in for a deployment whose existence getter is unavailable. The adapter must treat that as "cannot
///      confirm the market exists" and drop the leaf, never as a reason to revert a display-only view.
contract MockMorphoNoMarketGetter {
    MarketParams private _params;

    constructor() {
        _params.collateralToken = address(1);
        _params.loanToken = address(2);
    }

    function idToMarketParams(Id) external view returns (MarketParams memory) {
        return _params;
    }

    function market(Id) external pure returns (Market memory) {
        revert("no market getter");
    }
}

/// @notice Morpho mock whose `idToMarketParams` behaves like the REAL one: a plain mapping getter that returns an
///         all-zero `MarketParams` for an unknown id instead of reverting.
/// @dev `MockMorpho` reverts on an unknown id, which routes the adapter into its `catch` arm and hides the
///      zero-struct path entirely. Only this shape exposes it.
contract MockMorphoZeroGetter {
    mapping(bytes32 => MarketParams) private _params;

    /// @dev Mirrors `createMarket`: stamping `lastUpdate` is what makes a market EXIST, and the adapter's label
    ///      path keys existence off that rather than off the params, so a mock that filled in params without it
    ///      would model a market Morpho cannot actually produce.
    mapping(bytes32 => uint128) private _lastUpdate;

    function setMarket(bytes32 id, address collateralToken, address loanToken) external {
        _params[id].collateralToken = collateralToken;
        _params[id].loanToken = loanToken;
        _lastUpdate[id] = 1;
    }

    /// @notice Params for a market that was never created — the all-zero-struct shape a plain mapping getter
    ///         returns, WITHOUT stamping `lastUpdate`. The combination Morpho itself permits but never creates.
    function setParamsWithoutCreating(bytes32 id, address collateralToken, address loanToken) external {
        _params[id].collateralToken = collateralToken;
        _params[id].loanToken = loanToken;
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _params[Id.unwrap(id)];
    }

    function market(Id id) external view returns (Market memory m) {
        m.lastUpdate = _lastUpdate[Id.unwrap(id)];
    }
}
