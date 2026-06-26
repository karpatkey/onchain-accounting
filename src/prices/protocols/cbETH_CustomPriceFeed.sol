// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title cbETH Custom Price Oracle
/// @notice USD price of cbETH = `cbETH.exchangeRate()` (ETH per cbETH, 18 dec) × Chainlink ETH/USD.
/// @dev Shared skeleton (staleness, decimals, latestRoundData, the `rate × ETH/USD / 1e18` math) lives in
///      BaseCustomPriceFeed; this feed supplies only the cbETH exchange rate via `_rate()`.
/// @author kpk
/* solhint-disable contract-name-camelcase */
contract cbETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param cbEth_ The address of the cbETH token.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address cbEth_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_)
        BaseCustomPriceFeed(cbEth_, ethToUsdChainlinkOracle_, ethToUsdChainlinkHeartbeat_)
    {}

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return IcbETH(UNDERLYING).exchangeRate();
    }
}

interface IcbETH {
    /// @notice Get the exchange rate of cbETH to ETH (18 decimals).
    function exchangeRate() external view returns (uint256);
}
