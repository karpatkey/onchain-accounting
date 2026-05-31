// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {MetaBalanceOracle} from "../../MetaBalanceOracle.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionType} from "src/utils/PositionType.sol";
import {IStablePool} from "../BalancerV3.sol";
import {BalancerV3PoolLib} from "./BalancerV3PoolLib.sol";

/// @title Meta Balancer V3 Pool Balance Adapter
/// @author kpk
/// @notice One immutable adapter that reports an account's **wallet-held** (unstaked) Balancer V3 pool liquidity
///         across *any* pool — the AMM-supplied LP only, no gauge staking and no rewards (those are the separate
///         MetaBalancerV3GaugeBalanceAdapter). The instance coordinate is the pool (BPT) address, widened to bytes32.
///         Emits one `Supply` leg per registered underlying pool token. See ADR 0010.
contract MetaBalancerV3PoolBalanceAdapter is MetaBalanceOracle {
    using Strings for address;
    using BalancerV3PoolLib for IStablePool;

    /// @param protocol_ Protocol identifier (e.g. "Balancer V3").
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(string memory protocol_, address navCalculator_) MetaBalanceOracle(protocol_, navCalculator_) {}

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
        string memory positionId = address(pool).toHexString();
        string memory detail =
            PositionType.withType(_detailBase(IERC20Metadata(address(pool)).name()), PositionType.SUPPLY);

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
                underlyingAsset: assetInfo,
                balanceOracle: address(this),
                amount: amount,
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
        return IStablePool(_toAddress(instance)).poolTokens();
    }

    /// @notice positionDetail JSON base (no closing `}`), deriving the pool name on-chain from the BPT token name.
    function _detailBase(string memory poolName) private view returns (string memory) {
        return string.concat("{\"protocol\":\"", _protocol, "\",\"product\":\"LP\",\"name\":\"", poolName, "\"");
    }
}
