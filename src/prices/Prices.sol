// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPrices} from "./IPrices.sol";
import {IPriceOracleCustom} from "./IPriceOracleCustom.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Prices
/// @notice This contract manages the price oracles for different tokens.
/// @author kpk
abstract contract Prices is IPrices, Initializable {
    //
    // Libraries
    //
    using ERC165Checker for address;

    /// @notice Grace period for L2 sequencer downtime
    uint256 public chainlinkL2SequencerGracePeriod;

    /// @notice Uptime feed for L2 sequencer
    AggregatorV3Interface public chainlinkL2SequencerUptimeFeed;

    /// @notice Price feed configurations by address (mapping name kept for backward compatibility)
    mapping(address asset => PriceFeedConfig oracle) public priceOracles;

    /// @notice Initializer for UUPS proxy
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the Chainlink feed for the L2 sequencer
    /// uptime. If this is run on a chain without the need of an uptime feed (e.g. L1), this parameter
    /// should be set to 0.
    // solhint-disable-next-line func-name-mixedcase
    function __Prices_init(address chainlinkL2SequencerUptimeFeed_) internal onlyInitializing {
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(chainlinkL2SequencerUptimeFeed_);
        chainlinkL2SequencerGracePeriod = 1 hours; // This is initialised with 1 hour by default.
    }

    /// @inheritdoc IPrices
    function latestPrice(address token) external view returns (uint256 price, uint8 decimals, bool stale) {
        (price, decimals, stale) = _latestPrice(token);

        stale = checkL2SequencerUptime() || stale;
    }

    /// @notice Returns the latest price for a given token without checking the uptime of the sequencer.
    /// @param token The address of the token.
    /// @return price The latest price of the token.
    /// @return decimals The amount of decimal places the price is represented with
    /// @return stale COMPLETE ME
    function _latestPrice(address token) internal view returns (uint256 price, uint8 decimals, bool stale) {
        PriceFeedConfig storage oracle = priceOracles[token];
        stale = false;

        if (oracle.oracle == address(0)) {
            revert PriceFeedNotSet(token);
        }

        if (oracle.priceType == PriceType.Chainlink) {
            AggregatorV3Interface chainlinkOracle = AggregatorV3Interface(oracle.oracle);
            (, int256 chainlinkPrice,, uint256 updatedAt,) = chainlinkOracle.latestRoundData();

            if (chainlinkPrice <= 0) {
                return (0, oracle.decimals, true);
            }

            if (block.timestamp - updatedAt > oracle.chainlinkHeartbeat) stale = true;

            price = uint256(chainlinkPrice);
        } else {
            bool customStale = false;
            (price, customStale) = IPriceOracleCustom(oracle.oracle).getLatestPrice();
            stale = stale || customStale;
        }

        decimals = oracle.decimals;
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
    function checkPriceOracleSupport(address token, address oracle, PriceType priceType) public view {
        if (oracle == address(0) || token == address(0)) {
            revert InvalidPriceOracle();
        }

        if (priceType == PriceType.Custom) {
            if (!oracle.supportsInterface(type(IPriceOracleCustom).interfaceId)) {
                revert InvalidPriceOracle();
            }
        } else if (priceType == PriceType.Chainlink) {
            AggregatorV3Interface(oracle).latestRoundData();
        } else {
            revert InvalidPriceOracleType();
        }

        // Allow replacing existing price oracle (no revert)
    }

    /// @notice Sets the price feed for a given token.
    /// @param token The address of the token.
    /// @param oracle The address of the oracle.
    /// @param chainlinkHeartbeat The heartbeat interval for the Chainlink oracle. This parameter is ignored for
    /// non-Chainlink oracles.
    /// @param priceType The type of the oracle.
    function _setPriceFeed(address token, address oracle, uint256 chainlinkHeartbeat, PriceType priceType) internal {
        checkPriceOracleSupport(token, oracle, priceType);

        uint8 decimals;
        if (priceType == PriceType.Chainlink) {
            if (chainlinkHeartbeat == 0) revert InvalidPriceOracle();
            decimals = AggregatorV3Interface(oracle).decimals();
        } else {
            decimals = IPriceOracleCustom(oracle).decimals();
        }

        priceOracles[token] = PriceFeedConfig({
            oracle: oracle, priceType: priceType, decimals: decimals, chainlinkHeartbeat: chainlinkHeartbeat
        });

        emit PriceFeedSet(token, oracle, chainlinkHeartbeat, priceType);
    }

    /// @notice Unsets the price feed for a given token.
    /// @param token The address of the token.
    function _unsetPriceFeed(address token) internal {
        delete priceOracles[token];
        emit PriceFeedUnset(token);
    }

    /// @notice Gap for upgradeability
    uint256[50] private __gap;
}
