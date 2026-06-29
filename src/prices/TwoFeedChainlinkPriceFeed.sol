// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TwoFeedChainlinkPriceFeed
/// @author KPK
/// @notice Shared skeleton for "asset/USD via two Chainlink feeds" custom price feeds: an asset whose USD price is
///         derived from a `RATE_FEED` (asset priced in some base unit, e.g. cbETH/ETH, weETH/eETH, syrupUSDC/USDC,
///         or the generic Y/X) composed with a `USD_FEED` for that base in USD (e.g. ETH/USD, USDC/USD, X/USD).
///         Used when no direct asset/USD feed exists. Concrete feeds (cbETH_L2, rsETH_L2, weETH, weETH_L2, LDO,
///         syrupUSDC_L2, wstETH_L2, and the generic CrossRate) supply only the two feeds + heartbeats and keep their
///         own named contract.
/// @dev Price is `rate · usd / 10**rateDecimals` (Math.Rounding.Floor) — i.e. `(asset/base) · (base/USD)`, with the
///      rate feed's decimals cancelled out — returned in the `USD_FEED`'s decimals. Both feeds are read each call;
///      the result is stale when either answer is non-positive or either feed is past its own heartbeat, using
///      `effectiveUpdatedAt = min(updatedAt, block.timestamp)` per feed to avoid upstream-clock bias. The returned
///      round metadata is that of the **less-recently-updated** feed (the more conservative `updatedAt`). The 5
///      `ICustomPriceFeed` thunks, the immutables, and constructor validation live here once instead of being
///      copy-pasted into each two-feed feed. Feeds with a single Chainlink base + 18-decimal rate use
///      {BaseCustomPriceFeed}; ERC-4626 vault-rate feeds use {ERC4626VaultRatePriceFeed}.
abstract contract TwoFeedChainlinkPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice The asset whose USD price is returned.
    address public immutable UNDERLYING_ASSET;

    /// @notice Chainlink oracle quoting the asset in its base unit (e.g. cbETH/ETH, Y/X). Its decimals scale the product.
    AggregatorV3Interface public immutable RATE_FEED;

    /// @notice Chainlink oracle quoting the base unit in USD (e.g. ETH/USD, X/USD). Sets the returned price decimals.
    AggregatorV3Interface public immutable USD_FEED;

    /// @notice Heartbeat (seconds) after which the rate feed is considered stale.
    uint256 public immutable RATE_HEARTBEAT;

    /// @notice Heartbeat (seconds) after which the USD feed is considered stale.
    uint256 public immutable USD_HEARTBEAT;

    /// @notice Decimals of the returned price (inherited from the USD feed).
    uint8 private immutable _decimals;

    /// @param underlyingAsset_ The asset being priced (must be ERC20-like).
    /// @param rateFeed_        Chainlink asset/base feed (e.g. cbETH/ETH).
    /// @param usdFeed_         Chainlink base/USD feed (e.g. ETH/USD).
    /// @param rateHeartbeat_   Staleness threshold (seconds) for the rate feed.
    /// @param usdHeartbeat_    Staleness threshold (seconds) for the USD feed.
    constructor(
        address underlyingAsset_,
        address rateFeed_,
        address usdFeed_,
        uint256 rateHeartbeat_,
        uint256 usdHeartbeat_
    ) {
        UNDERLYING_ASSET = OracleArgumentChecks.assertERC20Address(underlyingAsset_);
        RATE_FEED = OracleArgumentChecks.assertChainlinkOracle(rateFeed_);
        USD_FEED = OracleArgumentChecks.assertChainlinkOracle(usdFeed_);
        RATE_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(rateHeartbeat_);
        USD_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdHeartbeat_);
        _decimals = USD_FEED.decimals();
    }

    /// @notice Reads both feeds, applies staleness, and composes `rate · usd / 10**rateDecimals`.
    function _compute()
        internal
        view
        returns (
            uint256 price,
            bool stale,
            uint80 roundId,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        (uint80 rR, int256 rate, uint256 sR, uint256 uR, uint80 arR) = RATE_FEED.latestRoundData();
        (uint80 rU, int256 usd, uint256 sU, uint256 uU, uint80 arU) = USD_FEED.latestRoundData();

        // Report the metadata of the less-recently-updated (more conservative) feed.
        if (uR <= uU) {
            (roundId, startedAt, updatedAt, answeredInRound) = (rR, sR, uR, arR);
        } else {
            (roundId, startedAt, updatedAt, answeredInRound) = (rU, sU, uU, arU);
        }

        if (rate <= 0 || usd <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        uint256 effRate = uR > block.timestamp ? block.timestamp : uR;
        uint256 effUsd = uU > block.timestamp ? block.timestamp : uU;
        if (block.timestamp - effRate >= RATE_HEARTBEAT || block.timestamp - effUsd >= USD_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        // asset/USD = (asset/base) * (base/USD) / 10^rateDecimals
        price = uint256(rate).mulDiv(uint256(usd), 10 ** RATE_FEED.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view virtual override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view virtual override returns (address) {
        return UNDERLYING_ASSET;
    }

    /// @inheritdoc ICustomPriceFeed
    function decimals() external view virtual override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
    function latestRoundData()
        external
        view
        virtual
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        bool stale;
        (price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
        answer = stale ? int256(0) : int256(price);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
