// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IStablePool} from "src/balances/protocols/balancer/IBalancerV3.sol";
import {BalancerV3PoolLib} from "./BalancerV3PoolLib.sol";

/// @title Balancer V3 Pools Meta Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) Balancer V3 pool liquidity
///         across *any* pool — the AMM-supplied LP only, no gauge staking and no rewards (those are the separate
///         BalancerV3GaugesMetaBalanceAdapter). The instance coordinate is the pool (BPT) address, widened to bytes32.
///         Emits one `Supply` leg per registered underlying pool token. See ADR 0010.
contract BalancerV3PoolsMetaBalanceAdapter is MetaBalanceOracle {
    using BalancerV3PoolLib for IStablePool;

    bytes32 private constant PROTOCOL_ID = ProtocolIds.BALANCER_V3_POOL;

    /// @param protocolName_ Protocol identifier (e.g. "Balancer V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocolName_, address navCalculator_) MetaBalanceOracle(protocolName_, navCalculator_) {}

    /// @inheritdoc MetaBalanceOracle
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
        bytes memory positionId = abi.encode(address(pool));

        INAVCalculator.PositionBalance[] memory temp = new INAVCalculator.PositionBalance[](tokens.length);
        uint256 count;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (assetFilter != address(0) && token != assetFilter) continue;

            (INAVCalculator.Asset memory assetInfo, bool found) = _getAssetInfo(token);
            if (!found) continue;

            uint256 amount = pool.poolBalanceOf(walletBpt, token);
            if (amount == 0) continue;

            temp[count++] = INAVCalculator.PositionBalance({
                balanceAsset: assetInfo,
                balanceOracle: address(this),
                amount: amount,
                isDebt: false,
                protocolId: PROTOCOL_ID,
                positionId: positionId,
                positionKind: PositionKind.Supplied
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
        return IStablePool(_toAddress(instance)).poolTokens();
    }

    /// @inheritdoc MetaBalanceOracle
    function describePosition(bytes calldata positionId) external view override returns (string memory) {
        address pool = abi.decode(positionId, (address));
        try IERC20Metadata(pool).name() returns (string memory n) {
            return n;
        } catch {
            return "";
        }
    }
}
