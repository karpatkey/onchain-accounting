// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Spark
/// @author kpk
/// @notice This contract calculates a user's positions in Spark Lend by:
/// 1. Retrieving the user's supplied and borrowed amounts for each supported reserve via the Protocol Data Provider
/// 2. Returning separate supply and borrow positions (no netting — supply and borrow are distinct PositionBalance entries)
/// The final balance is denominated in the underlying asset of the reserve.
contract SparkLendBalanceOracle is AaveV3InstanceBalanceOracle {
    /// @param dataProvider_ The address of the Spark Pool Data Provider contract.
    /// @param navCalculator_ The address of the NAVCalculator contract for asset registry access.
    constructor(
        address dataProvider_,
        address navCalculator_
    ) AaveV3InstanceBalanceOracle(dataProvider_, navCalculator_) {}

    /// @inheritdoc AaveV3InstanceBalanceOracle
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.SPARK_LEND;
    }

    /// @notice Returns the human-readable protocol name.
    function protocolName() external pure override returns (string memory) {
        return "Spark";
    }
}
