// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Id, MarketParams, Market, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";

// Mock contracts extracted from MorphoMarket.t.sol for use by MorphoMarketsMetaBalanceAdapter.t.sol

/// @notice Mock Morpho with configurable per-user `Position` and per-market `Market` state.
/// @dev Implements only `idToMarketParams`, `position`, and `market` — the surface used by
///      Morpho market mock for meta-adapter tests. Constructor wires a single
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
