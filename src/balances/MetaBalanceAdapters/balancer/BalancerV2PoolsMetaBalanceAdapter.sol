// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {BalancerV2PoolLib, IBalancerV2Pool} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol";

/// @title Balancer V2 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) Balancer V2 pool liquidity
///         across *any* pool — the AMM-supplied LP only (gauge-staked LP + rewards are the separate
///         `BalancerV2GaugesMetaBalanceAdapter`). The instance coordinate is the pool's **`bytes32` poolId, used
///         directly** (configured via the `instancesRaw` config key), since V2 identifies pools by poolId (the BPT
///         address is its top 160 bits). Emits one `Supplied` leg per underlying pool token. The Balancer V2 Vault is the chain-level
///         constant pinned in the constructor. Identity derived on-chain (positionId = abi.encode(bytes32 poolId);
///         label leaf = the pool's underlying token symbols joined with "/"). See ADR 0010.
/// @dev Valuation = instantaneous on-chain amounts (ADR 0017): this adapter reports the position's current
///      pro-rata share of the pool's on-chain Vault balances as per-token `amount`s, which NAVCalculator prices
///      with external oracles — it does NOT compute a manipulation-resistant "fair" value. Imbalancing the pool
///      can transiently move the reported amounts (a donation that arbitrage reverses within a block) but cannot
///      be monetised: NAV is a read-only oracle consumed by an asynchronous sub/redeem layer (no atomic on-chain
///      consumer). See docs/decisions/0017-lp-valuation-instantaneous-amounts.md; revisit if NAV is ever consumed
///      synchronously on-chain.
contract BalancerV2PoolsMetaBalanceAdapter is MetaBalanceAdapter {
    using BalancerV2PoolLib for bytes32;

    /// @notice The Balancer V2 Vault (custodies every pool's tokens; chain-level constant).
    address public immutable VAULT;

    /// @param vault_ The Balancer V2 Vault address.
    /// @param protocolName_ Protocol identifier (e.g. "Balancer V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vault_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        AddressCheckLib.requireContract(vault_, "Vault");
        VAULT = vault_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the pool's `bytes32` poolId (used directly, not an address). Emits one `Supplied` leg per
    ///      registered underlying pool token for the account's wallet BPT share. Returns an empty array when the
    ///      account holds no BPT. Skips zero-share, filtered (non-`assetFilter`), and unregistered tokens.
    function _instancePositions(address account, bytes32 instance, address assetFilter)
        internal
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        bytes32 poolId = instance;
        address bpt = BalancerV2PoolLib.bptOf(poolId);
        uint256 walletBpt = IBalancerV2Pool(bpt).balanceOf(account);
        if (walletBpt == 0) return new INAVCalculator.PositionBalance[](0);

        (address[] memory tokens, uint256[] memory amounts) = BalancerV2PoolLib.shares(VAULT, poolId, bpt, walletBpt);

        bytes memory positionId = _instancePositionId(instance);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](tokens.length);
        uint256 count;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] == 0) continue;
            if (assetFilter != address(0) && tokens[i] != assetFilter) continue;
            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(tokens[i]);
            if (!found) continue;
            temp[count++] = _leg(assetInfo, amounts[i], false, positionId, PositionKind.Supplied);
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Balancer V2 pool instance is a raw bytes32 poolId, not an address.
    function _instancePositionId(bytes32 instance) internal pure override returns (bytes memory) {
        return abi.encode(instance);
    }

    /// @inheritdoc MetaBalanceAdapter
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        return BalancerV2PoolLib.poolTokens(VAULT, instance, BalancerV2PoolLib.bptOf(instance));
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev Returns `["AMM Liquidity Pool", "<sym0>/<sym1>/…"]` — the leaf is the pool's underlying token symbols
    ///      joined with "/" (e.g. "USDC/USDT/DAI"), excluding the pool's own pre-minted BPT (composable-stable).
    ///      Per-token fail-open: a token whose `symbol()` reverts (or has no code) contributes "?". A revert in the
    ///      Vault pool-token read (e.g. a malformed/removed instance) is caught by the `try/catch` self-call and falls
    ///      open here to the category-only label `["AMM Liquidity Pool"]`. Returns an empty array for a
    ///      short/malformed `pid` (fewer than 32 bytes).
    function positionLabels(bytes calldata pid) external view virtual override returns (string[] memory) {
        if (pid.length < 32) return new string[](0);
        bytes32 poolId = abi.decode(pid, (bytes32));
        // External self-call so a revert in the Vault pool-token read (bad/removed poolId) fails open to the
        // category-only label — a faulty label must never revert the (verbose-only) labels read.
        try this.poolTokenSymbols(poolId) returns (string memory leaf) {
            return _labels("AMM Liquidity Pool", leaf);
        } catch {
            return _labels("AMM Liquidity Pool", "");
        }
    }

    /// @notice External wrapper (enables `try/catch` isolation in `positionLabels`): the pool's underlying token
    ///         symbols joined with "/" (BPT excluded for composable-stable pools). Reverts propagate only to the
    ///         `positionLabels` catch arm.
    function poolTokenSymbols(bytes32 poolId) external view returns (string memory) {
        address bpt = BalancerV2PoolLib.bptOf(poolId);
        return _joinTokenSymbols(BalancerV2PoolLib.poolTokens(VAULT, poolId, bpt));
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER_V2;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.BALANCER_V2_POOLS;
    }
}
