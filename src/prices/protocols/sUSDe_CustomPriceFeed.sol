// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sUSDe Custom Price Oracle
/// @notice Returns the USD price of sUSDe as `(USDe/USD) × (USDe per sUSDe share)`, the vault's live ERC-4626
///         exchange rate times Chainlink's USDe/USD quote.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sUSDe vault, the USDe/USD feed, and its heartbeat.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sUSDe_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sUsde_ Address of the Staked USDe (sUSDe) vault contract.
    /// @param usdeToUsdChainlinkAddress_ Address of the USDe to USD Chainlink oracle.
    /// @param usdeToUsdChainlinkHeartbeat_ Seconds after which the USDe/USD price is considered stale if not updated.
    constructor(address sUsde_, address usdeToUsdChainlinkAddress_, uint256 usdeToUsdChainlinkHeartbeat_)
        ERC4626VaultRatePriceFeed(sUsde_, usdeToUsdChainlinkAddress_, usdeToUsdChainlinkHeartbeat_)
    {}
}
