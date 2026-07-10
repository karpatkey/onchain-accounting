// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title stETH Custom Price Oracle
/// @notice Returns the USD price of stETH as `(stETH/ETH) × (ETH/USD)` from a Chainlink stETH/ETH feed and the NAV's
///         ETH/USD price.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins stETH's rate feed and the NAV base asset, and gives the deployment its own named contract.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract stETH_CustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param stEth_ The stETH token address.
    /// @param stEthToEthFeed_ The stETH/ETH Chainlink feed (rate).
    /// @param stEthToEthHeartbeat_ Staleness threshold (seconds) for the stETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address stEth_, address stEthToEthFeed_, uint256 stEthToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(stEth_, stEthToEthFeed_, stEthToEthHeartbeat_, nav_, baseAsset_)
    {}
}
