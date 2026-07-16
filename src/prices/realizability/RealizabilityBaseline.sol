// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IRealizabilitySource} from "src/prices/IRealizabilitySource.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";

/// @title RealizabilityBaseline
/// @notice Shared skeleton for {IRealizabilitySource} implementations: pins the underlying asset and provides the
///         ERC165 self-declaration. Concrete sources implement only `realizability()`.
/// @dev Each source is pinned to one asset (mirrors the custom-price-feed family). `realizability()` reads live
///      protocol state for `withdrawalsEnabled` / `healthy` where available and returns a coarse
///      `expectedRedemptionSeconds` (an on-chain-derived or constructor-baselined estimate — it only needs to
///      straddle the per-asset limit configured on the NAV, not be exact).
/// @author KPK
abstract contract RealizabilityBaseline is IRealizabilitySource {
    /// @notice The token whose redemption status this source reports.
    address public immutable UNDERLYING;

    /// @param underlying_ The token this source is pinned to (must be ERC20-like).
    constructor(address underlying_) {
        UNDERLYING = OracleArgumentChecks.assertERC20Address(underlying_);
    }

    /// @inheritdoc IRealizabilitySource
    function underlyingAssetSupported() external view virtual override returns (address) {
        return UNDERLYING;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(IRealizabilitySource).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
