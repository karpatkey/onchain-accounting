// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title rETH Custom Price Oracle
/// @notice USD price of rETH = `rETH.getExchangeRate()` (ETH per rETH, 18 dec) × Chainlink ETH/USD.
/// @dev Shared skeleton (staleness, decimals, latestRoundData, the `rate × ETH/USD / 1e18` math) lives in
///      BaseCustomPriceFeed; this feed supplies only the rETH exchange rate via `_rate()`.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract rETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param rEth_ The address of the rETH token.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address rEth_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_)
        BaseCustomPriceFeed(rEth_, ethToUsdChainlinkOracle_, ethToUsdChainlinkHeartbeat_)
    {}

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return IrETH(UNDERLYING).getExchangeRate();
    }
}

interface IrETH {
    /// @notice Get amount of ETH backing 1 rETH (18 decimals).
    function getExchangeRate() external view returns (uint256);
}
