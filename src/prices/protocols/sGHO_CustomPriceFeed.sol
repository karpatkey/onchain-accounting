// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title sGHO Custom Price Oracle
/// @notice Returns the USD price of sGHO (Aave's GHO savings vault share) by combining Chainlink's
///         GHO/USD feed with the current sGHO→GHO exchange rate from the sGHO ERC-4626 vault.
/// @dev sGHO is an ERC-4626 share token with GHO as its underlying asset. The price is computed as
///      `price = (GHO/USD) * (GHO_per_share / 10^decimals)`,
///      where `GHO_per_share = IERC4626(SGHO).convertToAssets(10^decimals)`.
///      - The GHO/USD quote comes from `GHO_TO_USD_CHAINLINK_ORACLE` and uses `_decimals` decimals.
///      - `convertToAssets` uses the vault's decimals; multiplication is scaled via `Math.mulDiv`
///        so the returned USD price has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `GHO_TO_USD_CHAINLINK_HEARTBEAT`.
///      If the feed is stale or the quoted Chainlink price is non-positive, the function returns `(0, true)`.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sGHO_CustomPriceFeed is ICustomPriceFeed {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice The sGHO vault contract address.
    address public immutable SGHO;

    /// @notice Chainlink oracle for GHO to USD.
    AggregatorV3Interface public immutable GHO_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the GHO/USD Chainlink oracle.
    uint256 public immutable GHO_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    /// @notice Decimals of the sGHO vault share token (used for convertToAssets scaling).
    uint8 private immutable _vaultDecimals;

    //
    // Constructor
    //

    /// @notice Initialises the price oracle for sGHO.
    /// @param sGho_ Address of the sGHO vault contract.
    /// @param ghoToUsdChainlinkAddress_ Address of the GHO to USD Chainlink oracle.
    /// @param ghoToUsdChainlinkHeartbeat_ The time in seconds after which the GHO/USD price is considered stale if
    /// not updated.
    constructor(address sGho_, address ghoToUsdChainlinkAddress_, uint256 ghoToUsdChainlinkHeartbeat_) {
        SGHO = OracleArgumentChecks.assertERC20Address(sGho_);
        GHO_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ghoToUsdChainlinkAddress_);
        GHO_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ghoToUsdChainlinkHeartbeat_);
        _decimals = GHO_TO_USD_CHAINLINK_ORACLE.decimals();
        _vaultDecimals = IERC4626(sGho_).decimals();
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
        int256 ghoToUsdPrice;
        (roundId, ghoToUsdPrice, startedAt, updatedAt, answeredInRound) = GHO_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (ghoToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= GHO_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 sghoToGhoPrice = IERC4626(SGHO).convertToAssets(10 ** _vaultDecimals);
        price = sghoToGhoPrice.mulDiv(ghoToUsdPrice.toUint256(), 10 ** _vaultDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return SGHO;
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
