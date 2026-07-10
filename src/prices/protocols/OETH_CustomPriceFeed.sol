// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title OETH Custom Price Oracle
/// @notice Returns the USD price of OETH as `(OETH/ETH) × (ETH/USD)` from a Chainlink OETH/ETH feed and the NAV's
///         ETH/USD price.
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins OETH's rate feed and the NAV base asset, and gives the deployment its own named contract.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract OETH_CustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param oeth_ The OETH token address.
    /// @param oethToEthFeed_ The OETH/ETH Chainlink feed (rate).
    /// @param oethToEthHeartbeat_ Staleness threshold (seconds) for the OETH/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address oeth_, address oethToEthFeed_, uint256 oethToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(oeth_, oethToEthFeed_, oethToEthHeartbeat_, nav_, baseAsset_)
    {}
}
