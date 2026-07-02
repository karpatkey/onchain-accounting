// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "../IBalanceAdapter.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title SingleAssetAssistedGetters
/// @author KPK
/// @notice Shared `IBalanceAdapter` single-asset getter triad for assisted adapters that report exactly ONE
///         underlying asset — the agent-fed withdrawal/exit/stake queues (ether.fi, StakeWise V3, Nexus Mutual).
///         Implements `underlyingAssetsSupported` / `getAdapterBalanceForAsset` / `getAdapterBalances` off one
///         {_owedAmount} hook. This mirrors {SingleAssetBalanceAdapterBase} (which serves the *plain* family) for the
///         assisted family, which cannot inherit it: the assisted adapters extend the AccessControl-based
///         {AssistantFedBalanceAdapter}, a different base hierarchy.
/// @dev A mix-in: a concrete adapter inherits this ALONGSIDE its cache base (e.g.
///      `is AssistedNftCacheAdapter, SingleAssetAssistedGetters, IPositionDescribable`) and implements only
///      {_owedAmount} plus the NAV `getAdapterPositions` path (which carries the per-position kinds / lock status)
///      and the {IPositionDescribable} hooks. `UNDERLYING_TOKEN` lives here (pinned once at construction); the
///      concrete adapter passes it to this constructor and references the inherited immutable everywhere else.
abstract contract SingleAssetAssistedGetters is IBalanceAdapter {
    /// @notice The single asset this adapter reports (the redeemed / claimable / staked underlying). Must be a
    ///         registered NAV asset for `getAdapterPositions` to count it; the balance getters below report it
    ///         regardless (registration-independent — they surface a holding NAV may not yet price).
    address public immutable UNDERLYING_TOKEN;

    /// @param underlyingToken_ The reported underlying asset. Must be non-zero.
    constructor(address underlyingToken_) {
        if (underlyingToken_ == address(0)) revert InvalidArguments();
        UNDERLYING_TOKEN = underlyingToken_;
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view virtual override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        virtual
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset != UNDERLYING_TOKEN || account == address(0)) return (0, false);
        return (_owedAmount(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        virtual
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        uint256 total = account == address(0) ? 0 : _owedAmount(account);
        if (total == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
    }

    /// @notice Total `UNDERLYING_TOKEN` currently owed to `account` (claimable + pending), 0 if none. Valued live
    ///         from on-chain reads; registration-independent. Implemented per adapter.
    function _owedAmount(address account) internal view virtual returns (uint256);
}
