// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "src/balances/MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";
import {BalancerV2PoolLib, IBalancerV2Pool} from "src/balances/protocols/balancer/BalancerV2PoolLib.sol";

/// @title Balancer V2 Pools Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) Balancer V2 pool liquidity
///         across *any* pool — the AMM-supplied LP only (gauge-staked LP + rewards are the separate
///         BalancerV2GaugesMeta adapter). The instance coordinate is the pool's **`bytes32` poolId, used directly**
///         (configured via `metaInstancesRaw`), since V2 identifies pools by poolId (the BPT address is its top
///         160 bits). Emits one `Supply` leg per underlying pool token. The Balancer V2 Vault is the chain-level
///         constant pinned in the constructor. Identity derived on-chain (positionId = BPT address; name = BPT
///         `name()`). See ADR 0010.
contract BalancerV2PoolsMetaBalanceAdapter is MetaBalanceOracle {
    using Strings for address;
    using BalancerV2PoolLib for bytes32;

    /// @notice The Balancer V2 Vault (custodies every pool's tokens; chain-level constant).
    address public immutable VAULT;

    /// @param vault_ The Balancer V2 Vault address.
    /// @param protocol_ Protocol identifier (e.g. "Balancer V2").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address vault_, string memory protocol_, address navCalculator_)
        MetaBalanceOracle(protocol_, navCalculator_)
    {
        require(vault_.code.length > 0, "Vault must be a contract");
        VAULT = vault_;
    }

    /// @inheritdoc MetaBalanceOracle
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

        string memory positionId = bpt.toHexString();
        string memory detail = PositionType.withType(_detailBase(bpt), PositionType.SUPPLY);

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](tokens.length);
        uint256 count;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] == 0) continue;
            if (assetFilter != address(0) && tokens[i] != assetFilter) continue;
            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(tokens[i]);
            if (!found) continue;
            temp[count++] = INAVCalculator.PositionBalance({
                underlyingAsset: assetInfo,
                balanceOracle: address(this),
                amount: amounts[i],
                isDebt: false,
                protocol: _protocol,
                positionDetail: detail,
                positionId: positionId
            });
        }

        INAVCalculator.PositionBalance[] memory positions = new INAVCalculator.PositionBalance[](count);
        for (uint256 i = 0; i < count; i++) {
            positions[i] = temp[i];
        }
        return positions;
    }

    /// @inheritdoc MetaBalanceOracle
    function _instanceAssets(bytes32 instance) internal view override returns (address[] memory) {
        return BalancerV2PoolLib.poolTokens(VAULT, instance, BalancerV2PoolLib.bptOf(instance));
    }

    /// @notice positionDetail JSON base (no closing `}`); name derived on-chain from the BPT token name.
    function _detailBase(address bpt) private view returns (string memory) {
        string memory name;
        try IERC20Metadata(bpt).name() returns (string memory n) {
            name = bytes(n).length == 0 ? bpt.toHexString() : n;
        } catch {
            name = bpt.toHexString();
        }
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"LP\",\"name\":\"", name, "\"");
    }
}
