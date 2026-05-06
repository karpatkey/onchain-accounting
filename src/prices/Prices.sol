// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPrices} from "./IPrices.sol";
import {IPriceFeedCustom} from "./IPriceFeedCustom.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Prices
/// @notice This contract manages the price feeds for different tokens.
/// @author kpk
abstract contract Prices is IPrices, Initializable {
    //
    // Libraries
    //
    using ERC165Checker for address;
    using SafeCast for uint256;

    /// @notice Grace period for L2 sequencer downtime
    uint256 public chainlinkL2SequencerGracePeriod;

    /// @notice Uptime feed for L2 sequencer
    AggregatorV3Interface public chainlinkL2SequencerUptimeFeed;

    /// @notice Price feed configurations by asset address
    mapping(address asset => PriceFeedConfig config) public priceOracles;

    /// @notice Initializer for UUPS proxy
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the Chainlink feed for the L2 sequencer
    /// uptime. If this is run on a chain without the need of an uptime feed (e.g. L1), this parameter
    /// should be set to 0.
    // solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
    function __Prices_init(address chainlinkL2SequencerUptimeFeed_) internal onlyInitializing {
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(chainlinkL2SequencerUptimeFeed_);
        chainlinkL2SequencerGracePeriod = 1 hours; // This is initialised with 1 hour by default.
    }

    /// @inheritdoc IPrices
    function latestPrice(address token) external view returns (int256 price, uint8 decimals, bool stale) {
        (price, decimals, stale) = _latestPrice(token);

        stale = checkL2SequencerUptime() || stale;
    }

    /// @notice Returns the latest price for a given token without checking the uptime of the sequencer.
    /// @param token The address of the token.
    /// @return price The latest price of the token (int256; Chainlink returned as-is, custom cast from uint256).
    /// @return decimals The amount of decimal places the price is represented with
    /// @return stale Whether the price is considered stale.
    function _latestPrice(address token) internal view returns (int256 price, uint8 decimals, bool stale) {
        PriceFeedConfig storage config = priceOracles[token];

        if (config.priceFeed == address(0)) {
            revert PriceFeedNotSet(token);
        }

        decimals = config.decimals;

        if (config.priceType == PriceType.Chainlink) {
            AggregatorV3Interface chainlinkFeed = AggregatorV3Interface(config.priceFeed);
            (, int256 chainlinkPrice,, uint256 updatedAt,) = chainlinkFeed.latestRoundData();

            if (chainlinkPrice <= 0) {
                return (0, decimals, true);
            }

            price = chainlinkPrice;
            stale = block.timestamp - updatedAt > config.chainlinkHeartbeat;
        } else {
            (,,, uint256 updatedAt,) = IPriceFeedCustom(config.priceFeed).latestRoundData();
            uint256 customPrice;
            (customPrice,) = IPriceFeedCustom(config.priceFeed).getLatestPrice();

            if (customPrice == 0) return (0, decimals, true);

            price = customPrice.toInt256();
            stale = block.timestamp - updatedAt > config.chainlinkHeartbeat;
        }
    }

    /// @inheritdoc IPrices
    function checkL2SequencerUptime() public view returns (bool stale) {
        stale = false;

        if (address(chainlinkL2SequencerUptimeFeed) != address(0)) {
            (, int256 answer, uint256 startedAt,,) = chainlinkL2SequencerUptimeFeed.latestRoundData();

            if (answer != 0) {
                stale = true;
            } else {
                // Make sure the grace period has passed after the
                // sequencer is back up.
                uint256 timeSinceUp = block.timestamp - startedAt;

                if (timeSinceUp <= chainlinkL2SequencerGracePeriod) stale = true;
            }
        }
    }

    /// @inheritdoc IPrices
    function checkPriceOracleSupport(address token, address priceFeed, PriceType priceType) public view {
        if (priceFeed == address(0) || token == address(0)) revert InvalidPriceOracle();
        if (priceType == PriceType.Custom) {
            if (!priceFeed.supportsInterface(type(IPriceFeedCustom).interfaceId)) revert InvalidPriceOracle();
        } else if (priceType == PriceType.Chainlink) {
            // Reject contracts that explicitly identify as IPriceFeedCustom — Chainlink and Custom are mutually exclusive.
            // ERC165Checker.supportsInterface() returns false (not revert) when the feed doesn't implement ERC165,
            // so this is safe to call on real Chainlink oracles.
            if (priceFeed.supportsInterface(type(IPriceFeedCustom).interfaceId)) revert InvalidPriceOracle();
            AggregatorV3Interface(priceFeed).latestRoundData();
        } else {
            revert InvalidPriceOracleType();
        }
    }

    /// @notice Sets the price feed for a given token.
    /// @param token The address of the token.
    /// @param priceFeed The address of the price feed.
    /// @param chainlinkHeartbeat The heartbeat interval in seconds. Required non-zero for all feeds.
    /// @param priceType The type of the price feed.
    function _setPriceFeed(address token, address priceFeed, uint256 chainlinkHeartbeat, PriceType priceType) internal {
        checkPriceOracleSupport(token, priceFeed, priceType);

        if (chainlinkHeartbeat == 0) revert InvalidPriceOracle();

        uint8 decimals;
        if (priceType == PriceType.Chainlink) {
            decimals = AggregatorV3Interface(priceFeed).decimals();
        } else {
            decimals = IPriceFeedCustom(priceFeed).decimals();
        }

        priceOracles[token] = PriceFeedConfig({
            priceFeed: priceFeed, priceType: priceType, decimals: decimals, chainlinkHeartbeat: chainlinkHeartbeat
        });

        emit PriceFeedSet(token, priceFeed, chainlinkHeartbeat, priceType);
    }

    /// @notice Unsets the price feed for a given token.
    /// @param token The address of the token.
    function _unsetPriceFeed(address token) internal {
        delete priceOracles[token];
        emit PriceFeedUnset(token);
    }
}
