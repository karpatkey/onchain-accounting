// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title syrupUSDC Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC as `(USDC/USD) × (USDC per syrupUSDC share)`, the vault's live
///         ERC-4626 exchange rate times Chainlink's USDC/USD quote.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the syrupUSDC vault, the USDC/USD feed, and its heartbeat.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract syrupUSDC_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param syrupUsdc_ Address of the syrupUSDC vault contract.
    /// @param usdcToUsdChainlinkAddress_ Address of the USDC to USD Chainlink oracle.
    /// @param usdcToUsdChainlinkHeartbeat_ Seconds after which the USDC/USD price is considered stale if not updated.
    constructor(address syrupUsdc_, address usdcToUsdChainlinkAddress_, uint256 usdcToUsdChainlinkHeartbeat_)
        ERC4626VaultRatePriceFeed(syrupUsdc_, usdcToUsdChainlinkAddress_, usdcToUsdChainlinkHeartbeat_)
    {}
}
