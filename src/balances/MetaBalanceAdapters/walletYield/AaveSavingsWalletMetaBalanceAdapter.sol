// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {WalletTokenMetaBalanceAdapterBase} from "../WalletTokenMetaBalanceAdapterBase.sol";
import {MetaBalanceAdapter} from "../../MetaBalanceAdapter.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title Aave V3 wallet-held yield token adapter
/// @author KPK
/// @notice Reports an account's wallet-held sGHO as a Aave V3 position rather than an anonymous
///         wallet holding. Instances are the token addresses, governed on NAVCalculator (ADR 0010).
/// @dev Kind is `Supplied`. Exit at par redeems savings shares against the GHO market.
///
///      The token must be EXCLUDED from `ERC20DefaultBalanceAdapter` before being added here, or both
///      adapters report it under different reconciliation keys and NAV double-counts with no health flag.
///      See {WalletTokenMetaBalanceAdapterBase}.
contract AaveSavingsWalletMetaBalanceAdapter is WalletTokenMetaBalanceAdapterBase {
    /// @param navCalculator_ The NAVCalculator contract for asset-registry access.
    constructor(address navCalculator_) WalletTokenMetaBalanceAdapterBase(navCalculator_) {}

    /// @inheritdoc WalletTokenMetaBalanceAdapterBase
    function _positionKind() internal pure override returns (PositionKind) {
        return PositionKind.Supplied;
    }

    /// @inheritdoc WalletTokenMetaBalanceAdapterBase
    function _labelCategory() internal pure override returns (string memory) {
        return "Savings";
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolBrand() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V3;
    }

    /// @inheritdoc MetaBalanceAdapter
    function _protocolSubId() internal pure override returns (bytes32) {
        return ProtocolIds.AAVE_V3_SAVINGS;
    }
}
