// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalanceAdapter} from "./IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title IMetaBalanceAdapter
/// @author KPK
/// @notice Interface for *meta* balance adapters: a single immutable adapter that can report positions
///         for an arbitrary number of instances of one protocol (e.g. every Morpho vault, every Balancer pool).
/// @dev A meta-adapter is universal and instance-stateless — it holds no list of "active" instances and has no
///      admin/write functions. The set of instances to actually query lives on NAVCalculator (per-adapter,
///      MANAGER-gated). This keeps adapters immutable while making the governed "which instances" set mutable in
///      the upgradeable, AccessControl-gated NAVCalculator.
///
///      Instances are identified by a `bytes32` coordinate. For most protocols this is an address widened to
///      bytes32 (vault / pool / instance-DataProvider address); the wider type also accommodates protocols whose
///      instance key is itself a bytes32 (e.g. Morpho market ids).
///
///      Call path: NAVCalculator calls the inherited `getAdapterPositions(account, assetFilter)` on every adapter
///      uniformly (no ERC165 routing). A meta-adapter services it by reading its own NAV-configured set via
///      `getMetaInstances(address(this))` and fanning out over it — see `MetaBalanceAdapter`. The instance-aware
///      methods below take an explicit instance list for off-chain/explicit queries and per-instance breakdowns.
///      (The other no-arg `IBalanceAdapter` methods — `getAdapterBalances`/`getAdapterBalanceForAsset` —
///      are not used by the NAV path and return empty.)
interface IMetaBalanceAdapter is IBalanceAdapter {
    /// @notice Get all positions for an account across the supplied instances.
    /// @param account The account to query.
    /// @param instances The instance coordinates to query (e.g. vault addresses widened to bytes32).
    /// @param assetFilter Optional asset filter (address(0) for all assets).
    /// @return positions Array of balance-only PositionBalance structs aggregated across the instances.
    function getAdapterPositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions);

    /// @notice Returns the underlying assets supported across the supplied instances.
    /// @param instances The instance coordinates to inspect.
    /// @return underlyingAssets The list of underlying asset addresses (may contain duplicates across instances).
    function underlyingAssetsSupportedForInstances(bytes32[] calldata instances)
        external
        view
        returns (address[] memory underlyingAssets);
}
