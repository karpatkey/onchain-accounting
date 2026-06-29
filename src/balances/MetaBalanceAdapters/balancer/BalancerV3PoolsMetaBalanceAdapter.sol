// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IStablePool} from "src/balances/MetaBalanceAdapters/balancer/IBalancerV3.sol";
import {BalancerV3PoolLib} from "./BalancerV3PoolLib.sol";

/// @title Balancer V3 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) Balancer V3 pool liquidity
///         across *any* pool — the AMM-supplied LP only, no gauge staking and no rewards (those are the separate
///         BalancerV3GaugesMetaBalanceAdapter). The instance coordinate is the pool (BPT) address, widened to bytes32.
///         Emits one `Supply` leg per registered underlying pool token. See ADR 0010.
/// @dev Valuation = instantaneous on-chain amounts (ADR 0017): this adapter reports the position's current
///      pro-rata share of the pool's on-chain balances as per-token `amount`s, which NAVCalculator prices with
///      external oracles — it does NOT compute a manipulation-resistant "fair" value. Imbalancing the pool can
///      transiently move the reported amounts (a donation that arbitrage reverses within a block) but cannot be
///      monetised: NAV is a read-only oracle consumed by an asynchronous sub/redeem layer (no atomic on-chain
///      consumer). See docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed
///      synchronously on-chain.
contract BalancerV3PoolsMetaBalanceAdapter is MetaBalanceAdapter {
    using BalancerV3PoolLib for IStablePool;

    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.BALANCER;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.BALANCER_V3;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.BALANCER_V3_POOLS;

    /// @param protocolName_ Protocol identifier (e.g. "Balancer V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {}

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the pool (BPT) address. Emits one Supply leg per registered pool token for the account's
    ///      wallet BPT share. Skips unregistered tokens and respects assetFilter.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        IStablePool pool = IStablePool(_toAddress(instance));
        uint256 walletBpt = pool.balanceOf(account);
        if (walletBpt == 0) {
            return new INAVCalculator.PositionBalance[](0);
        }

        address[] memory tokens = pool.poolTokens();
        bytes memory positionId = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](tokens.length);
        uint256 count;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (assetFilter != address(0) && token != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(token);
            if (!found) continue;

            uint256 amount = pool.poolBalanceOfIndexed(walletBpt, i);
            if (amount == 0) continue;

            temp[count++] = INAVCalculator.PositionBalance({
                balanceAsset: assetInfo,
                balanceAdapter: address(this),
                amount: amount,
                isDebt: false,
                protocolBrand: PROTOCOL_BRAND,
                protocolId: PROTOCOL_ID,
                protocolSubId: PROTOCOL_SUB_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                isLocked: false,
                positionInstanceId: bytes32(0)
            });
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        return IStablePool(_toAddress(instance)).poolTokens();
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["AMM Liquidity Pool", "<sym0>/<sym1>/…"]` — the leaf is the pool's underlying token symbols
    ///      joined with "/" (e.g. "WETH/wstETH"). Per-token fail-open: a token whose `symbol()` reverts (or has no
    ///      code) contributes "?". A revert in the pool-token read fails open at the NAV layer (`_safeStringArray`).
    function positionLabels(bytes calldata positionId) external view virtual override returns (string[] memory) {
        address pool = abi.decode(positionId, (address));
        return _labels("AMM Liquidity Pool", _joinTokenSymbols(IStablePool(pool).poolTokens()));
    }
}
