// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract Mock_CustomPriceFeed is ICustomPriceFeed {
    string name;
    address addressSupported;
    uint256 price;
    uint8 internal _decimals;
    uint256 internal _updatedAt;
    uint256 internal _heartbeat = 3600; // governing-leg heartbeat reported by governingFeedFreshness

    constructor(string memory name_, address addressSupported_, uint256 price_, uint8 decimals_) {
        name = name_;
        addressSupported = addressSupported_;
        price = price_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function setHeartbeat(uint256 heartbeat_) external {
        _heartbeat = heartbeat_;
    }

    function getLatestPrice() external view virtual returns (uint256, bool) {
        return (price, false);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function underlyingAssetSupported() external view override returns (address) {
        return addressSupported;
    }

    function latestRoundData() external view virtual override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, int256(price), 0, _updatedAt, 0);
    }

    function governingFeedFreshness() external view virtual override returns (uint256, uint256) {
        return (_updatedAt, _heartbeat);
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract Mock_PriceOracleChainlink is AggregatorV3Interface {
    string name;
    uint256 price;
    uint8 internal _decimals;
    uint256 internal _updatedAt;

    constructor(string memory name_, uint256 price_, uint8 decimals_) {
        name = name_;
        price = price_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return name;
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // casting to 'int256' is safe because price is uint256 and fits in int256 range for Chainlink prices
        // forge-lint: disable-next-line(unsafe-typecast)
        return (0, int256(price), 0, block.timestamp, 0);
    }

    function latestRoundData()
        external
        view
        virtual
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // casting to 'int256' is safe because price is a positive value representing a price
        // forge-lint: disable-next-line(unsafe-typecast)
        return (0, int256(price), 0, _updatedAt, 0);
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }
}

contract Mock_ChainlinkL2SequencerUptimeFeed is Mock_PriceOracleChainlink {
    constructor() Mock_PriceOracleChainlink("L2 sequencer uptime feed", 0, 0) {}

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 statusStartedAt = block.timestamp > 1 hours ? block.timestamp - 1 hours - 1 : 1;
        return (0, 0, statusStartedAt, statusStartedAt, 0);
    }
}

contract Mock_ChainlinkL2SequencerUptimeFeedUninitialized is Mock_PriceOracleChainlink {
    constructor() Mock_PriceOracleChainlink("L2 sequencer uninitialized", 0, 0) {}

    function latestRoundData()
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, 0, 0, 0, 0);
    }
}

contract Mock_ChainlinkL2SequencerUptimeFeedDown is Mock_PriceOracleChainlink {
    constructor() Mock_PriceOracleChainlink("L2 sequencer down", 0, 0) {}

    function latestRoundData()
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, 1, 0, 0, 0);
    }
}

contract Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod is Mock_PriceOracleChainlink {
    constructor() Mock_PriceOracleChainlink("L2 sequencer ithin grace period", 0, 0) {}

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, 0, block.timestamp, 0, 0);
    }
}

contract Mock_CustomPriceFeedStaled is Mock_CustomPriceFeed {
    constructor(string memory _name, address _addressSupported, uint256 _price, uint8 _decimals)
        Mock_CustomPriceFeed(_name, _addressSupported, _price, _decimals)
    {}

    function getLatestPrice() external view override returns (uint256, bool) {
        return (price, true);
    }

    // updatedAt = 0 so block.timestamp - 0 > any positive heartbeat is always true
    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }
}
