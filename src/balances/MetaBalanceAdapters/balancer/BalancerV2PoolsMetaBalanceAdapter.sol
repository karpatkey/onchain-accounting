// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {MetaBalanceAdapter} from "src/balances/MetaBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {BalancerV2PoolLib, IBalancerV2Pool} from "src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol";

/// @title Balancer V2 Pools Meta Balance Adapter
/// @author KPK
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) Balancer V2 pool liquidity
///         across *any* pool — the AMM-supplied LP only (gauge-staked LP + rewards are the separate
///         BalancerV2GaugesMeta adapter). The instance coordinate is the pool's **`bytes32` poolId, used directly**
///         (configured via `metaInstancesRaw`), since V2 identifies pools by poolId (the BPT address is its top
///         160 bits). Emits one `Supply` leg per underlying pool token. The Balancer V2 Vault is the chain-level
///         constant pinned in the constructor. Identity derived on-chain (positionId = abi.encode(bytes32 poolId);
///         name = BPT `name()`). See ADR 0010.
contract BalancerV2PoolsMetaBalanceAdapter is MetaBalanceAdapter {
    using BalancerV2PoolLib for bytes32;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.BALANCER_V2_POOL;

    /// @notice The Balancer V2 Vault (custodies every pool's tokens; chain-level constant).
    address public immutable VAULT;

    /// @param vault_ The Balancer V2 Vault address.
    /// @param protocolName_ Protocol identifier (e.g. "Balancer V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vault_, string memory protocolName_, address navCalculator_)
        MetaBalanceAdapter(protocolName_, navCalculator_)
    {
        require(vault_.code.length > 0, "Vault must be a contract");
        VAULT = vault_;
    }

    /// @inheritdoc MetaBalanceAdapter
    /// @dev `instance` is the pool's `bytes32` poolId (used directly, not an address). Emits one `Supply` leg per
    ///      registered underlying pool token for the account's wallet BPT share. Skips unregistered/filtered tokens.
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
            temp[count++] = INAVCalculator.PositionBalance({
                balanceAsset: assetInfo,
                balanceAdapter: address(this),
                amount: amounts[i],
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied,
                labels: _legLabels(positionId)
            });
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

    /// @dev Per-leg display labels, filled on every emitted PositionBalance.labels.
    /// @dev Returns `["Liquidity Pool", <BPT name>]`; the leaf is "" if the BPT's `name()` reverts.
    function _legLabels(bytes memory positionId) private view returns (string[] memory) {
        bytes32 poolId = abi.decode(positionId, (bytes32));
        address bpt = address(uint160(uint256(poolId) >> 96));
        string memory leaf;
        try IERC20Metadata(bpt).name() returns (string memory n) {
            leaf = n;
        } catch {
            leaf = "";
        }
        return _labels("Liquidity Pool", leaf);
    }
}
