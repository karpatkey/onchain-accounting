// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sXDAI Custom Price Oracle
/// @notice Returns the USD price of Gnosis sDAI as `(xDAI/USD) × (xDAI per sDAI share)`, the vault's live ERC-4626
///         exchange rate times Chainlink's xDAI/USD quote.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sDAI vault, the xDAI/USD feed, and its heartbeat.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sXDAI_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sDai_ Address of the Gnosis Staked DAI (sDAI) vault contract.
    /// @param xDaiToUsdChainlinkOracle_ Address of the xDAI to USD Chainlink oracle.
    /// @param xDaiToUsdChainlinkHeartbeat_ Seconds after which the xDAI/USD price is considered stale if not updated.
    constructor(address sDai_, address xDaiToUsdChainlinkOracle_, uint256 xDaiToUsdChainlinkHeartbeat_)
        ERC4626VaultRatePriceFeed(sDai_, xDaiToUsdChainlinkOracle_, xDaiToUsdChainlinkHeartbeat_)
    {}
}
