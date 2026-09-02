// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {WalletTokenMetaBalanceAdapterBase} from "../WalletTokenMetaBalanceAdapterBase.sol";
import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Ankr wallet-held yield token adapter
/// @author KPK
/// @notice Reports an account's wallet-held ankrETH as a Ankr position rather than an anonymous
///         wallet holding. Instances are the token addresses, governed on NAVCalculator (ADR 0010).
/// @dev Kind is `Staking`. Exit at par is Ankr's unstake over staked ETH.
///
///      The token must be EXCLUDED from `ERC20DefaultBalanceAdapter` before being added here, or both
///      adapters report it under different reconciliation keys and NAV double-counts with no health flag.
///      See {WalletTokenMetaBalanceAdapterBase}.
contract AnkrStakedEthWalletMetaBalanceAdapter is WalletTokenMetaBalanceAdapterBase {
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
        return ProtocolIds.ANKR;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.ANKR;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.ANKR_STAKED_ETH;
    }
}
