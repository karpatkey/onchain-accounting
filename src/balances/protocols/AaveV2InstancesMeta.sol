// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {
    AaveV3InstancesMetaBalanceAdapter,
    IAaveAddressesProviderSource
} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {IProtocolDataProvider} from "src/balances/protocols/AaveV3Instance.sol";

/// @title Aave V2 Instances Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's lending positions across *any* Aave V2 instance. The
///         instance coordinate is the instance's ProtocolDataProvider address. Aave V2's `AaveProtocolDataProvider`
///         exposes the same `getAllReservesTokens()` / `getUserReserveData()` ABI as V3, so this is a thin subclass
///         of `AaveV3InstancesMetaBalanceAdapter` — the only divergence is that V2's `LendingPoolAddressesProvider`
///         resolves the pool via `getLendingPool()` (not `getPool()`), overridden below for on-chain positionId
///         derivation. Stable debt is not reported (governance-disabled on V2, same as the per-instance adapter).
///         See ADR 0010.
contract AaveV2InstancesMetaBalanceAdapter is AaveV3InstancesMetaBalanceAdapter {
    /// @param protocol_ Protocol identifier (e.g. "Aave V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_)
        AaveV3InstancesMetaBalanceAdapter(protocol_, navCalculator_)
    {}

    /// @inheritdoc AaveV3InstancesMetaBalanceAdapter
    /// @dev V2's LendingPoolAddressesProvider exposes `getLendingPool()` rather than V3's `getPool()`.
    function _poolOf(IProtocolDataProvider dp) internal view override returns (address) {
        return IAaveV2LendingPoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER())
            .getLendingPool();
    }
}

/// @notice Minimal Aave V2 LendingPoolAddressesProvider view for resolving the pool address.
interface IAaveV2LendingPoolAddressesProvider {
    function getLendingPool() external view returns (address);
}
