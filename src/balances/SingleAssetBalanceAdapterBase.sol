// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterBase} from "./BalanceAdapterBase.sol";
import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title SingleAssetBalanceAdapterBase
/// @author KPK
/// @notice Base for plain balance adapters that report a SINGLE underlying asset — the LST/cooldown withdrawal-queue
///         adapters (Lido, Stader, Ethena). It pins `UNDERLYING_TOKEN` and implements the no-position getter triad
///         (`underlyingAssetsSupported` / `getAdapterBalanceForAsset` / `getAdapterBalances`) off one
///         `_owedAmount(account)` hook. Concrete adapters implement `_owedAmount`, the NAV `getAdapterPositions`
///         path (which carries the per-protocol position kinds / lock status), and the {IPositionDescribable} hooks.
/// @dev Multi-asset queue adapters (e.g. Kelp, which can owe several assets) do NOT use this base — they extend
///      {BalanceAdapterBase} directly and implement their own multi-asset getters.
abstract contract SingleAssetBalanceAdapterBase is BalanceAdapterBase {
    /// @notice The single asset this adapter reports (the redeemed/claimable underlying).
    address public immutable UNDERLYING_TOKEN;

    /// @param underlyingToken_ The reported underlying asset. Must be non-zero.
    constructor(address underlyingToken_) {
        if (underlyingToken_ == address(0)) revert InvalidArguments();
        UNDERLYING_TOKEN = underlyingToken_;
    }

    /// @inheritdoc IBalanceAdapter
    function underlyingAssetsSupported() external view override returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = UNDERLYING_TOKEN;
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        override
        returns (uint256 amount, bool isDebt)
    {
        if (asset == address(0) || asset != UNDERLYING_TOKEN) return (0, false);
        return (_owedAmount(account), false);
    }

    /// @inheritdoc IBalanceAdapter
    function getAdapterBalances(address account)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt)
    {
        if (account == address(0)) return (new address[](0), new uint256[](0), new bool[](0));
        uint256 total = _owedAmount(account);
        if (total == 0) return (new address[](0), new uint256[](0), new bool[](0));
        assets = new address[](1);
        amounts = new uint256[](1);
        isDebt = new bool[](1);
        assets[0] = UNDERLYING_TOKEN;
        amounts[0] = total;
    }

    /// @notice The total `UNDERLYING_TOKEN` currently owed to `account` (claimable + pending), 0 if none.
    function _owedAmount(address account) internal view virtual returns (uint256);
}
