// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sGHO Custom Price Oracle
/// @notice Returns the USD price of sGHO as `(GHO/USD) × (GHO per sGHO share)`, the vault's live ERC-4626
///         exchange rate times Chainlink's GHO/USD quote.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sGHO vault, the GHO/USD feed, and its heartbeat.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sGHO_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sGho_ Address of the Savings GHO (sGHO) vault contract.
    /// @param ghoToUsdChainlinkAddress_ Address of the GHO to USD Chainlink oracle.
    /// @param ghoToUsdChainlinkHeartbeat_ Seconds after which the GHO/USD price is considered stale if not updated.
    constructor(address sGho_, address ghoToUsdChainlinkAddress_, uint256 ghoToUsdChainlinkHeartbeat_)
        ERC4626VaultRatePriceFeed(sGho_, ghoToUsdChainlinkAddress_, ghoToUsdChainlinkHeartbeat_)
    {}
}
