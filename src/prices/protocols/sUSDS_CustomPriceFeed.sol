// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sUSDS Custom Price Oracle
/// @notice Returns the USD price of sUSDS as `(USDS/USD) × (USDS per sUSDS share)`, the vault's live ERC-4626
///         exchange rate times Chainlink's USDS/USD quote.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sUSDS vault, the USDS/USD feed, and its heartbeat.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sUSDS_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sUsds_ Address of the Staked USDS (sUSDS) vault contract.
    /// @param usdsToUsdChainlinkAddress_ Address of the USDS to USD Chainlink oracle.
    /// @param usdsToUsdChainlinkHeartbeat_ Seconds after which the USDS/USD price is considered stale if not updated.
    constructor(address sUsds_, address usdsToUsdChainlinkAddress_, uint256 usdsToUsdChainlinkHeartbeat_)
        ERC4626VaultRatePriceFeed(sUsds_, usdsToUsdChainlinkAddress_, usdsToUsdChainlinkHeartbeat_)
    {}
}
