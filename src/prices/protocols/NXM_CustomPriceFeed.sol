// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NXM / wNXM Custom Price Oracle
/// @notice Returns the USD price of NXM (or its 1:1 wrapper wNXM) by combining Nexus Mutual's RAMM internal price
///         with Chainlink's ETH/USD feed.
/// @dev NXM has no external market oracle by design; its value is determined internally by the Ratcheting AMM (RAMM),
///      which exposes `getInternalPrice()` as a manipulation-resistant TWAP of ETH-per-NXM (18 decimals).
///      The price is computed as `price = (ETH/NXM) * (ETH/USD)`, where:
///      - `ETH/NXM` comes from the RAMM contract's `getInternalPrice()` function (18 decimals)
///      - `ETH/USD` comes from Chainlink oracle (8 decimals)
///      Result is scaled to 8 decimals: `price = getInternalPrice * ETH/USD / 1e18`.
///      The returned price is the RAMM book value per NXM-unit, assigned to the token passed as `token_`. Deploy one
///      instance per priced token: NXM itself, and/or wNXM — the transferable wrapper that a Nexus member can unwrap
///      1:1 to NXM, so book value is realizable for a member holder (matching how data aggregators price wNXM).
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract NXM_CustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice The priced token (NXM or its 1:1 wrapper wNXM).
    address public immutable TOKEN;

    /// @notice Nexus Mutual RAMM contract providing the internal ETH-per-NXM price.
    address public immutable RAMM;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    /// @param token_ The address of the priced token (NXM or its 1:1 wrapper wNXM).
    /// @param ramm_ The address of the Nexus Mutual RAMM contract.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address token_, address ramm_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_) {
        TOKEN = OracleArgumentChecks.assertERC20Address(token_);
        RAMM = OracleArgumentChecks.assertNonZeroAddress(ramm_);
        // Fail fast at deploy if RAMM is not a live Nexus RAMM: a non-contract (EOA) or wrong contract makes
        // getInternalPrice() revert or return 0, which would otherwise only surface as a silently-skipped feed.
        if (IRamm(ramm_).getInternalPrice() == 0) revert InvalidArgumentsWithContext("RAMM");
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    function _compute()
        private
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
        int256 ethToUsdPrice;
        (roundId, ethToUsdPrice, startedAt, updatedAt, answeredInRound) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (ethToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        // getInternalPrice() is ETH-per-NXM (18 decimals); ETH/USD is 8 decimals → result is 8 decimals
        uint256 ethPerNxm = IRamm(RAMM).getInternalPrice();
        if (ethPerNxm == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        price = ethPerNxm.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return TOKEN;
    }

    /// @inheritdoc ICustomPriceFeed
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        bool stale;
        (price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
        answer = stale ? int256(0) : int256(price);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface IRamm {
    /// @notice Manipulation-resistant internal ETH-per-NXM price (18 decimals).
    function getInternalPrice() external view returns (uint256);
}
