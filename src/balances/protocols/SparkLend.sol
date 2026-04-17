// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";

/// @title Spark
/// @author kpk
/// @notice This contract calculates a user's positions in Spark Lend by:
/// 1. Retrieving the user's supplied and borrowed amounts for each supported reserve via the Protocol Data Provider
/// 2. Returning separate supply and borrow positions (no netting — supply and borrow are distinct PositionBalance entries)
/// The final balance is denominated in the underlying asset of the reserve.
contract SparkLendBalanceOracle is AaveV3InstanceBalanceOracle {
    /// @param dataProvider_ The address of the Spark Pool Data Provider contract.
    /// @param protocol_ Protocol identifier (e.g., "Spark").
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access.
    constructor(address dataProvider_, string memory protocol_, address navCalculator_)
        AaveV3InstanceBalanceOracle(dataProvider_, protocol_, navCalculator_)
    {}
}
