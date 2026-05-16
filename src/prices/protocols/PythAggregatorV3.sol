// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @title PythAggregatorV3
/// @notice Wraps a Pyth Network price feed behind AggregatorV3Interface so it can be registered
/// as a redundancy feed alongside Chainlink and Redstone Classic Push feeds.
/// @dev Reads via IPyth.getPriceUnsafe — no on-chain update or fee required; freshness is
/// enforced by the caller's heartbeat gate in Prices._selectFeed. On Pyth-sponsored chains
/// (Ethereum, Arbitrum, Base, Optimism, Avalanche, etc.) a first-party push service keeps
/// the on-chain mirror up to date at ~1h heartbeat / 1% deviation.
/// updatedAt == PythStructs.Price.publishTime (upstream Pythnet signing time, not EVM block
/// time). The consumer normalises this via min(updatedAt, block.timestamp).
/// @author kpk
contract PythAggregatorV3 is AggregatorV3Interface {
    uint8 private constant FIXED_DECIMALS = 8;

    IPyth public immutable pyth;
    bytes32 public immutable priceFeedId;

    constructor(address pyth_, bytes32 priceFeedId_) {
        pyth = IPyth(pyth_);
        priceFeedId = priceFeedId_;
    }

    function decimals() external pure override returns (uint8) {
        return FIXED_DECIMALS;
    }

    function description() external pure override returns (string memory) {
        return "PythAggregatorV3";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Returns the latest price normalised to 8 decimals.
    /// @dev Converts Pyth's (price * 10^expo) to (price * 10^-8).
    /// price is the int64 mantissa and expo the signed exponent (typically negative, e.g. -8).
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        PythStructs.Price memory p = pyth.getPriceUnsafe(priceFeedId);

        answer = _normalise(p.price, p.expo);
        updatedAt = p.publishTime;
        // Pyth has no round concept; synthesise from publishTime for interface compatibility.
        roundId = uint80(p.publishTime);
        answeredInRound = roundId;
        startedAt = p.publishTime;
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return this.latestRoundData();
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    /// @notice Converts Pyth's (mantissa, expo) to a fixed-8-decimal int256.
    /// @dev Pyth expo is typically -8; if it differs we scale accordingly.
    /// Reverts if the mantissa is negative (invalid price) — caller should treat answer <= 0 as invalid.
    function _normalise(int64 mantissa, int32 expo) internal pure returns (int256) {
        // FIXED_DECIMALS = 8; we want result = mantissa * 10^(8 + expo)
        int32 shift = int32(int8(FIXED_DECIMALS)) + expo; // positive → multiply, negative → divide
        int256 base = int256(mantissa);

        if (shift >= 0) {
            return base * int256(10 ** uint32(shift));
        } else {
            return base / int256(10 ** uint32(-shift));
        }
    }
}
