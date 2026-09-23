// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {WalletTokenMetaBalanceAdapterBase} from "../WalletTokenMetaBalanceAdapterBase.sol";
import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Liquid Collective wallet-held yield token adapter
/// @author KPK
/// @notice Reports an account's wallet-held lsETH as a Liquid Collective position rather than an anonymous
///         wallet holding. Instances are the token addresses, governed on NAVCalculator (ADR 0010).
/// @dev Kind is `Staking`. Exit at par is Liquid Collective's redeem queue over staked ETH.
///
///      The token does NOT need excluding from `ERC20DefaultBalanceAdapter` by hand: claiming a coordinate
///      disarms the default adapter for it in the same transaction (`NAVRegistryLib._claim`), and this
///      adapter additionally suppresses its own leg while the default adapter still reports the token. An
///      earlier version of this line said the exclusion was required first; that was true before the
///      claimant map and is no longer. See {WalletTokenMetaBalanceAdapterBase}.
contract LiquidCollectiveStakedEthWalletMetaBalanceAdapter is WalletTokenMetaBalanceAdapterBase {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) WalletTokenMetaBalanceAdapterBase(navCalculator_) {}

    /// @inheritdoc WalletTokenMetaBalanceAdapterBase
    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Staking;
    }

    /// @inheritdoc WalletTokenMetaBalanceAdapterBase
    function _labelCategory() internal pure override returns (string memory) {
        return "LST";
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.LIQUID_COLLECTIVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.LIQUID_COLLECTIVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.LIQUID_COLLECTIVE_STAKED_ETH;
    }
}
