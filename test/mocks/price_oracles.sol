// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceOracleCustom} from "src/prices/IPriceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Mock custom price oracle
contract Mock_PriceOracleCustom is IPriceOracleCustom {
    string public name;
    address public underlyingAsset;
    uint256 public price;
    uint8 public decimals_;
    bool public stale;

    constructor(string memory name_, address underlyingAsset_, uint256 price_, uint8 decimals__) {
        name = name_;
        underlyingAsset = underlyingAsset_;
        price = price_;
        decimals_ = decimals__;
        stale = false;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setStale(bool stale_) external {
        stale = stale_;
    }

    function getLatestPrice() external view override returns (uint256, bool) {
        return (price, stale);
    }

    function decimals() external view override returns (uint8) {
        return decimals_;
    }

    function underlyingAssetSupported() external view override returns (address) {
        return underlyingAsset;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IPriceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Mock Chainlink price oracle
contract Mock_PriceOracleChainlink is AggregatorV3Interface {
    string public description;
    uint256 public price;
    uint8 public decimals_;

    constructor(string memory description_, uint256 price_, uint8 decimals__) {
        description = description_;
        price = price_;
        decimals_ = decimals__;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, int256(price), block.timestamp, block.timestamp, 1);
    }

    function decimals() external view override returns (uint8) {
        return decimals_;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        revert("Not implemented");
    }
}

/// @notice Mock Chainlink L2 sequencer uptime feed (up)
contract Mock_ChainlinkL2SequencerUptimeFeed is AggregatorV3Interface {
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // answer: 0 = up, 1 = down
        return (1, int256(0), block.timestamp - 3600, block.timestamp - 3600, 1);
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        revert("Not implemented");
    }
}

/// @notice Mock Chainlink L2 sequencer uptime feed (down)
contract Mock_ChainlinkL2SequencerUptimeFeedDown is AggregatorV3Interface {
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // answer: 0 = up, 1 = down
        return (1, int256(1), block.timestamp - 3600, block.timestamp - 3600, 1);
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        revert("Not implemented");
    }
}

/// @notice Mock Chainlink L2 sequencer uptime feed (down, within grace period)
contract Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod is AggregatorV3Interface {
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // answer: 0 = up, 1 = down
        // updatedAt is recent (within grace period)
        return (1, int256(1), block.timestamp - 100, block.timestamp - 100, 1);
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        revert("Not implemented");
    }
}
