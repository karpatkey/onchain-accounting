// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {
    UniswapV2PoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/uniswap/UniswapV2PoolsMetaBalanceAdapter.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title PancakeSwap V2 Pools Meta Balance Adapter
/// @author KPK
/// @notice Meta-adapter for PancakeSwap V2 pairs. PancakeSwap V2 shares the Uniswap V2 Pair/Factory ABI and
///         pro-rata math, so this is a thin subclass of the Uniswap V2 pools meta-adapter. It differs in ONE
///         respect: PancakeSwap's protocol-fee fraction is not Uniswap's, so its `_mintFee` mints a different
///         amount of dilution LP to `feeTo` — overridden via `_mintFeeConstants` below. The protocol identifier
///         (e.g. "PancakeSwap V2") is set per deployment.
/// @dev Valuation = instantaneous on-chain amounts (ADR 0017): this adapter reports the position's current
///      pro-rata share of the pair's on-chain reserves as per-token `amount`s, which NAVCalculator prices with
///      external oracles — it does NOT compute a manipulation-resistant "fair" value. Imbalancing the pair can
///      transiently move the reported amounts (a donation that arbitrage reverses within a block) but cannot be
///      monetised: NAV is a read-only oracle consumed by an asynchronous sub/redeem layer (no atomic on-chain
///      consumer). See docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed
///      synchronously on-chain.
contract PancakeSwapV2PoolsMetaBalanceAdapter is UniswapV2PoolsMetaBalanceAdapter {
    /// @param protocolName_ Human-readable protocol name (e.g. "PancakeSwap V2").
    /// @param navCalculator_ NAVCalculator contract address.
    constructor(string memory protocolName_, address navCalculator_)
        UniswapV2PoolsMetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc UniswapV2PoolsMetaBalanceAdapter
    /// @dev Reports the `pancakeswap-v2` slug (vs the inherited `uniswap-v2`) so the typed reconciliation key
    ///      distinguishes PancakeSwap V2 LP from Uniswap V2 LP. Same positionId schema (address pair).
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.PANCAKESWAP_V2;
    }

    /// @inheritdoc UniswapV2PoolsMetaBalanceAdapter
    /// @dev PancakeSwap V2's `_mintFee` uses `liquidity = ts·(√k−√kLast)·8 / (17·√k + 8·√kLast)` — a larger
    ///      protocol-fee fraction than Uniswap's `(1, 5, 1)`. Using Uniswap's constants would understate the
    ///      dilution LP and slightly overstate the holder's reserve share whenever PancakeSwap's `feeTo` is set.
    function _mintFeeConstants()
        internal
        pure
        override
        returns (uint256 numFactor, uint256 rootKCoeff, uint256 rootKLastCoeff)
    {
        return (8, 17, 8);
    }
}
