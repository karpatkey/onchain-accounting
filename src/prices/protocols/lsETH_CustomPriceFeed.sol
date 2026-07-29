// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title lsETH Custom Price Oracle
/// @notice Returns the USD price of lsETH as `(lsETH/ETH) × (ETH/USD)` from a Chainlink lsETH/ETH feed and the NAV's
///         ETH/USD price.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins lsETH's rate feed and the NAV base asset, and gives the deployment its own named contract.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract lsETH_CustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param lsEth_ The lsETH token address.
    /// @param lsEthToEthFeed_ The lsETH/ETH Chainlink feed (rate).
    /// @param lsEthToEthHeartbeat_ Staleness threshold (seconds) for the lsETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address lsEth_, address lsEthToEthFeed_, uint256 lsEthToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(lsEth_, lsEthToEthFeed_, lsEthToEthHeartbeat_, nav_, baseAsset_)
    {}
}
