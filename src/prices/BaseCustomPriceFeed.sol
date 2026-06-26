// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseCustomPriceFeed
/// @author kpk
/// @notice Shared skeleton for the "exchange-rate × Chainlink-base" custom price feeds: it reads a base Chainlink
///         feed (typically ETH/USD, 8 decimals), applies the standard staleness gate, multiplies by a
///         protocol-supplied 18-decimal exchange rate, and returns the result in the base feed's decimals.
///         Concrete feeds implement only `_rate()` — the protocol's exchange rate as 18-decimal base-token
///         units per 1 `UNDERLYING` (e.g. ETH per rETH), i.e. the same orientation the multiply expects.
/// @dev The 5 `ICustomPriceFeed` thunks, the immutables, the constructor validation, and the
///      read/staleness/normalize math live here once, instead of being copy-pasted into ~17 feeds. The math is
///      identical to the former per-feed `_compute()`: `price = rate · baseAnswer / 1e18` (Math.Rounding.Floor),
///      stale when the base answer is non-positive, the base feed is past its heartbeat, or `_rate()` is 0.
///      Staleness uses `effectiveUpdatedAt = min(updatedAt, block.timestamp)` to avoid upstream-clock bias.
///      Feeds whose rate is itself a Chainlink feed should use the generic `CrossRate_CustomPriceFeed` instead;
///      feeds with no Chainlink base (e.g. ETHPlus) or a derived two-feed rate (e.g. eETH) stay bespoke.
abstract contract BaseCustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice The token this feed prices (returned by `underlyingAssetSupported`).
    address public immutable UNDERLYING;

    /// @notice Base Chainlink oracle (typically ETH/USD).
    AggregatorV3Interface public immutable BASE_ORACLE;

    /// @notice Heartbeat (seconds) after which the base feed is considered stale.
    uint256 public immutable BASE_HEARTBEAT;

    /// @notice Decimals of the returned price (inherited from the base Chainlink feed).
    uint8 private immutable _decimals;

    /// @param underlying_   The token being priced (must be ERC20-like).
    /// @param baseOracle_    The base Chainlink oracle (e.g. ETH/USD).
    /// @param baseHeartbeat_ Staleness threshold (seconds) for the base feed.
    constructor(address underlying_, address baseOracle_, uint256 baseHeartbeat_) {
        UNDERLYING = OracleArgumentChecks.assertERC20Address(underlying_);
        BASE_ORACLE = OracleArgumentChecks.assertChainlinkOracle(baseOracle_);
        BASE_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(baseHeartbeat_);
        _decimals = BASE_ORACLE.decimals();
    }

    /// @notice The protocol's exchange rate, expressed as 18-decimal base-token units per 1 `UNDERLYING`
    ///         (e.g. ETH per rETH). Return 0 to mark the price stale/unavailable.
    /// @dev The only hook a concrete feed must implement.
    function _rate() internal view virtual returns (uint256);

    /// @notice Reads the base feed + rate, applies staleness, and combines them. Mirrors the former per-feed
    ///         `_compute()`. Exposed to subclasses that need a different `latestRoundData` shape.
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
        int256 baseAnswer;
        (roundId, baseAnswer, startedAt, updatedAt, answeredInRound) = BASE_ORACLE.latestRoundData();
        if (baseAnswer <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= BASE_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 rate = _rate();
        if (rate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        // rate is 18 decimals; result is in the base feed's own decimals (8 for the usual ETH/USD feed).
        price = rate.mulDiv(uint256(baseAnswer), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view virtual override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view virtual override returns (address) {
        return UNDERLYING;
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
