// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NXM / wNXM Custom Price Oracle
/// @notice Returns the USD price of NXM (or its 1:1 wrapper wNXM) by combining Nexus Mutual's RAMM internal price
///         with the NAV's ETH/USD price.
/// @dev NXM has no external market oracle by design; its value is determined internally by the Ratcheting AMM (RAMM),
///      which exposes `getInternalPrice()` as a manipulation-resistant TWAP of ETH-per-NXM (18 decimals). The price
///      is `(ETH/NXM) × (ETH/USD)`, returned in `NAV_DECIMALS` (8). The returned price is the RAMM book
///      value per NXM-unit, assigned to the token passed as `token_`. Deploy one instance per priced token: NXM
///      itself, and/or wNXM — the transferable wrapper a Nexus member can unwrap 1:1 to NXM, so book value is
///      realizable for a member holder (matching how data aggregators price wNXM).
/// @dev Thin {BaseCustomPriceFeed} subclass: `_rate()` is `RAMM.getInternalPrice()` (ETH-per-NXM, 18 decimals) and
///      the base composes it with the NAV's ETH/USD and applies the staleness gate. The constructor additionally fails fast if
///      RAMM is not a live Nexus RAMM (a non-contract / wrong contract makes `getInternalPrice()` revert or return 0,
///      which would otherwise only surface as a silently-skipped feed).
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract NXM_CustomPriceFeed is BaseCustomPriceFeed {
    /// @notice Nexus Mutual RAMM contract providing the internal ETH-per-NXM price.
    address public immutable RAMM;

    /// @param token_ The address of the priced token (NXM or its 1:1 wrapper wNXM).
    /// @param ramm_ The address of the Nexus Mutual RAMM contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address token_, address ramm_, address nav_, address baseAsset_)
        BaseCustomPriceFeed(token_, nav_, baseAsset_)
    {
        RAMM = OracleArgumentChecks.assertNonZeroAddress(ramm_);
        if (IRamm(ramm_).getInternalPrice() == 0) revert InvalidArgumentsWithContext("RAMM");
    }

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev ETH-per-NXM (18 decimals) from the RAMM's manipulation-resistant internal price.
    function _rate() internal view override returns (uint256) {
        return IRamm(RAMM).getInternalPrice();
    }
}

interface IRamm {
    /// @notice Manipulation-resistant internal ETH-per-NXM price (18 decimals).
    function getInternalPrice() external view returns (uint256);
}
