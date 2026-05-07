// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";

/// @title Aave V2 Instance Balance Oracle
/// @author kpk
/// @notice This contract calculates a user's positions in Aave V2 by retrieving the user's
/// supplied and borrowed amounts for each supported reserve via the Protocol Data Provider.
/// The final balance is denominated in the underlying asset of the reserve.
/// @dev Inherits all logic from `AaveV3InstanceBalanceOracle`, which means:
/// - `getOracleBalanceForAsset` and `getOracleBalances` return the **net** of supply minus
///   variable debt per asset, with `isDebt` indicating the sign.
/// - `getOraclePositions` returns separate legs (Supply/Collateral and Borrow) per asset.
/// @dev Aave V2's `AaveProtocolDataProvider` exposes the same `getAllReservesTokens()` and
/// `getUserReserveData(asset, user)` ABI as Aave V3 (9 return values, identical types and order),
/// so the V3 adapter logic applies unchanged to V2.
/// @dev Stable-debt positions are not reported. Aave V2's stable borrow rate has been
/// governance-disabled across all reserves; new stable debt cannot be opened and any residual
/// stable-debt balance is rounding noise. If a non-trivial stable-debt position is ever
/// observed for a tracked account, this adapter must be replaced with a standalone
/// implementation that reads the third return value of `getUserReserveData`.
contract AaveV2InstanceBalanceOracle is AaveV3InstanceBalanceOracle {
    /// @param dataProvider_ The address of the Aave V2 Protocol Data Provider contract.
    /// @param protocol_ Protocol identifier (e.g., "Aave V2").
    /// @param positionDetail_ JSON metadata base without closing `}`.
    /// @param positionId_ Stable hex identifier for this adapter instance (Aave pool address).
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access.
    constructor(
        address dataProvider_,
        string memory protocol_,
        string memory positionDetail_,
        string memory positionId_,
        address navCalculator_
    ) AaveV3InstanceBalanceOracle(dataProvider_, protocol_, positionDetail_, positionId_, navCalculator_) {}
}
