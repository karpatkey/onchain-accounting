// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title INavSourcedPriceFeed
/// @author KPK
/// @notice The one thing a `Custom` price feed must disclose about its own pricing dependency: which asset, if any,
///         it reads a `base/USD` price for **out of the NAV it is registered on**.
/// @dev Companion to {ICustomPriceFeed}, deliberately kept as a SEPARATE interface rather than folded into it —
///      `PriceFeedLib` gates Custom registration on `supportsInterface(type(ICustomPriceFeed).interfaceId)`, and
///      adding a member to that interface would change its `interfaceId` and make every already-deployed custom feed
///      unregisterable. So this is declared, checked by a raw `staticcall` on the selector, and implemented by the
///      feed bases without touching `ICustomPriceFeed`.
/// @dev **Every custom feed must answer.** Registration reads this and REJECTS a feed that cannot
///      (`IPrices.CustomFeedBaseUnreadable`) — see {IPrices-CustomFeedBaseCircular} for why an unanswerable feed
///      cannot be admitted. A feed with no NAV dependency at all (e.g. `ETHPlus_CustomPriceFeed`, which prices from
///      the Reserve Protocol basket and never calls back) answers `address(0)`, which is always accepted.
interface INavSourcedPriceFeed {
    /// @notice The asset whose USD price this feed reads back out of the NAV (`getPriceData(BASE_ASSET)`) to scale its
    ///         own rate, or `address(0)` if this feed does not source a base price from the NAV.
    /// @dev MUST be `immutable`/`constant`. The value is read once, at registration, and never again — a feed that can
    ///      change its answer afterwards can pass the circularity gate and then recurse anyway (an admission check,
    ///      not a runtime invariant; identical in kind to {ICustomPriceFeed-underlyingAssetSupported}).
    /// @dev MUST NOT equal the asset the feed is registered for — that is the circular configuration the gate rejects.
    /* solhint-disable-next-line func-name-mixedcase */
    function BASE_ASSET() external view returns (address baseAsset);
}
