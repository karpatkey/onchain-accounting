// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalanceOracleAdapter} from "./IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title IMetaBalanceOracleAdapter
/// @author kpk
/// @notice Interface for *meta* balance oracle adapters: a single immutable adapter that can report positions
///         for an arbitrary number of instances of one protocol (e.g. every Morpho vault, every Balancer pool).
/// @dev A meta-adapter is universal and instance-stateless — it holds no list of "active" instances and has no
///      admin/write functions. The set of instances to actually query lives on NAVCalculator (per-oracle,
///      MANAGER-gated) and is passed in at query time. This keeps adapters immutable while making the
///      governed "which instances" set mutable in the upgradeable, AccessControl-gated NAVCalculator.
///
///      Instances are identified by a `bytes32` coordinate. For most protocols this is an address widened to
///      bytes32 (vault / pool / market-instance address); the wider type also accommodates protocols whose
///      instance key is itself a bytes32 (e.g. Morpho market ids).
///
///      Because the inherited no-arg `IBalanceOracleAdapter` methods cannot know the instance set, a
///      meta-adapter returns EMPTY results from them. NAVCalculator detects the meta interface via ERC165 at
///      registration time and always routes through the instance-aware methods below.
interface IMetaBalanceOracleAdapter is IBalanceOracleAdapter {
    /// @notice Get all positions for an account across the supplied instances.
    /// @param account The account to query.
    /// @param instances The instance coordinates to query (e.g. vault addresses widened to bytes32).
    /// @param assetFilter Optional asset filter (address(0) for all assets).
    /// @return positions Array of balance-only PositionBalance structs aggregated across the instances.
    function getOraclePositionsForInstances(address account, bytes32[] calldata instances, address assetFilter)
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
