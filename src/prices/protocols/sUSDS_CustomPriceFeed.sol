// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title sUSDS Custom Price Oracle
/// @notice Returns the USD price of sUSDS by combining Chainlink’s USDS/USD feed with the
///         current sUSDS→USDS exchange rate from the sUSDS ERC-4626 vault.
/// @dev sUSDS is an ERC-4626 share token. The price is computed as
///      `price = (USDS/USD) * (sUSDS_per_share / 10**vaultDecimals)`,
///      where `sUSDS_per_share = IERC4626(sUSDS).convertToAssets(10**vaultDecimals)`.
///      - The USDS/USD quote comes from `USDS_TO_USD_CHAINLINK_ORACLE` and uses `_decimals` decimals.
///      - `convertToAssets` is linear in shares, so dividing by the same `10**_vaultDecimals` used as input
///        yields the exchange rate (totalAssets/totalSupply); the result has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDS_TO_USD_CHAINLINK_HEARTBEAT`.
///      If the feed is stale or the quoted price is non-positive, the function returns `(0, true)` to signal staleness.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sUSDS_CustomPriceFeed is ICustomPriceFeed {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;
    //
    // State
    //

    /// @notice The Savings USDS (sUSDS) vault contract address.
    address public immutable S_USDS;

    /// @notice Chainlink oracle for USDS to USD
    AggregatorV3Interface public immutable USDS_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the USDS/USD Chainlink oracle.
    uint256 public immutable USDS_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    /// @notice Decimals of the sUSDS vault share token (used for convertToAssets scaling).
    uint8 private immutable _vaultDecimals;

    //
    // Constructor
    //

    /// @notice Initialises the price oracle for Savings USDS.
    /// @param sUsds_ Address of the Savings USDS (sUSDS) vault contract.
    /// @param usdsToUsdChainlinkAddress_ Address of the USDS to USD Chainlink oracle.
    /// @param usdsToUsdChainlinkHeartbeat_ The time in seconds after which the USDS/USD price is considered stale if
    /// not updated.
    constructor(address sUsds_, address usdsToUsdChainlinkAddress_, uint256 usdsToUsdChainlinkHeartbeat_) {
        S_USDS = OracleArgumentChecks.assertERC20Address(sUsds_);

        USDS_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdsToUsdChainlinkAddress_);

        USDS_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdsToUsdChainlinkHeartbeat_);

        _decimals = USDS_TO_USD_CHAINLINK_ORACLE.decimals();
        _vaultDecimals = IERC4626(sUsds_).decimals();
    }

    //
    // ICustomPriceFeed
    //

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
        int256 usdsToUsdPrice;
        (roundId, usdsToUsdPrice, startedAt, updatedAt, answeredInRound) =
            USDS_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (usdsToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= USDS_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 sUsdsToUsdsPrice = IERC4626(S_USDS).convertToAssets(10 ** _vaultDecimals);
        price = sUsdsToUsdsPrice.mulDiv(usdsToUsdPrice.toUint256(), 10 ** _vaultDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return S_USDS;
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
