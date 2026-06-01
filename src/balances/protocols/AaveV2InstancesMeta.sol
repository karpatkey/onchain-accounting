// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {
    AaveV3InstancesMetaBalanceAdapter,
    IAaveAddressesProviderSource
} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
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
    bytes32 private constant PROTOCOL_ID_V2 = ProtocolIds.AAVE_V2_LENDING;

    /// @param protocolName_ Human-readable protocol name (e.g. "Aave V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        AaveV3InstancesMetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc AaveV3InstancesMetaBalanceAdapter
    function _getProtocolId() internal view override returns (bytes32) {
        return PROTOCOL_ID_V2;
    }

    /// @inheritdoc AaveV3InstancesMetaBalanceAdapter
    /// @dev V2's LendingPoolAddressesProvider exposes `getLendingPool()` rather than V3's `getPool()`.
    function _poolOf(IProtocolDataProvider dp) internal view override returns (address) {
        return IAaveV2LendingPoolAddressesProvider(IAaveAddressesProviderSource(address(dp)).ADDRESSES_PROVIDER())
            .getLendingPool();
    }

    /// @inheritdoc AaveV3InstancesMetaBalanceAdapter
    function describePosition(bytes calldata pid) external view override returns (string memory) {
        if (pid.length < 64) return "";
        (, address reserve) = abi.decode(pid, (address, address));
        try IERC20Metadata(reserve).symbol() returns (string memory sym) {
            return string.concat(sym, " position");
        } catch {
            return "";
        }
    }
}

/// @notice Minimal Aave V2 LendingPoolAddressesProvider view for resolving the pool address.
interface IAaveV2LendingPoolAddressesProvider {
    function getLendingPool() external view returns (address);
}
