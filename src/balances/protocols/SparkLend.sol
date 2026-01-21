// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";

/// @title Spark
/// @author kpk
/// @notice This contract calculates a user's net position in Spark Lend by:
/// 1. Retrieving the user's supplied and borrowed amounts for each supported reserve via the Protocol Data Provider
/// 2. Computing net balance as (supplied - borrowed)
/// 3. Fetching the user's accrued rewards for the asset via the Rewards Distributor
/// 4. Returning the sum of net balance and unclaimed rewards
/// The final balance is denominated in the underlying asset of the reserve.
contract SparkLendBalanceOracle is AaveV3InstanceBalanceOracle {
    /// @param dataProvider_ The address of the Spark Pool Data Provider contract.
    /// @param rewardsDistributor_ The address of the Spark Rewards Distributor contract.
    /// @param protocol_ Protocol identifier (e.g., "Spark").
    /// @param balances_ The address of the Balances contract for asset registry access.
    constructor(address dataProvider_, address rewardsDistributor_, string memory protocol_, address balances_)
        AaveV3InstanceBalanceOracle(dataProvider_, rewardsDistributor_, protocol_, balances_)
    {}
}
