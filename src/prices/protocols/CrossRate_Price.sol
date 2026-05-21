// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Cross-Rate Price Adapter
/// @notice Computes Y/USD from Chainlink X/USD and Y/X feeds: price = (X/USD) * (Y/X) / 10^yToXDecimals.
/// @dev Use when no direct Y/USD feed exists; the base asset X has a USD feed and Y is quoted in X.
/// @author kpk
contract CrossRatePriceAdapter is IPriceFeedCustom {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    /// @notice The asset whose USD price is returned (Y).
    address public immutable UNDERLYING_ASSET;

    /// @notice Chainlink oracle for X to USD.
    AggregatorV3Interface public immutable X_TO_USD_FEED;

    /// @notice Chainlink oracle for Y to X.
    AggregatorV3Interface public immutable Y_TO_X_FEED;

    /// @notice Heartbeat for X/USD feed; price is stale if not updated within this many seconds.
    uint256 public immutable X_TO_USD_HEARTBEAT;

    /// @notice Heartbeat for Y/X feed; price is stale if not updated within this many seconds.
    uint256 public immutable Y_TO_X_HEARTBEAT;

    /// @notice Decimals of the returned price (matches X/USD feed).
    uint8 internal _decimals;

    constructor(
        address underlyingAsset_,
        address xToUsdFeed_,
        address yToXFeed_,
        uint256 xToUsdHeartbeat_,
        uint256 yToXHeartbeat_
    ) {
        UNDERLYING_ASSET = OracleArgumentChecks.assertERC20Address(underlyingAsset_);
        X_TO_USD_FEED = OracleArgumentChecks.assertChainlinkOracle(xToUsdFeed_);
        Y_TO_X_FEED = OracleArgumentChecks.assertChainlinkOracle(yToXFeed_);
        X_TO_USD_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(xToUsdHeartbeat_);
        Y_TO_X_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(yToXHeartbeat_);
        _decimals = X_TO_USD_FEED.decimals();
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 xToUsd,, uint256 xToUsdUpdatedAt,) = X_TO_USD_FEED.latestRoundData();
        (, int256 yToX,, uint256 yToXUpdatedAt,) = Y_TO_X_FEED.latestRoundData();

        if (xToUsd <= 0 || yToX <= 0) {
            return (0, true);
        }

        uint256 effectiveXUpdatedAt = xToUsdUpdatedAt > block.timestamp ? block.timestamp : xToUsdUpdatedAt;
        uint256 effectiveYUpdatedAt = yToXUpdatedAt > block.timestamp ? block.timestamp : yToXUpdatedAt;
        if (
            block.timestamp - effectiveXUpdatedAt >= X_TO_USD_HEARTBEAT
                || block.timestamp - effectiveYUpdatedAt >= Y_TO_X_HEARTBEAT
        ) {
            return (0, true);
        }

        // Y/USD = (X/USD) * (Y/X) / 10^yToXDecimals
        price = xToUsd.toUint256().mulDiv(yToX.toUint256(), 10 ** Y_TO_X_FEED.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return UNDERLYING_ASSET;
    }

    /// @inheritdoc IPriceFeedCustom
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 r1,, uint256 s1, uint256 u1, uint80 ar1) = X_TO_USD_FEED.latestRoundData();
        (uint80 r2,, uint256 s2, uint256 u2, uint80 ar2) = Y_TO_X_FEED.latestRoundData();
        if (u1 <= u2) {
            (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
        } else {
            (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
        }
        (uint256 price,) = this.getLatestPrice();
        answer = int256(price);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
