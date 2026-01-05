// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceOracleCustom} from "src/prices/IPriceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "src/errors.sol";

/// @title sUSDS Custom Price Oracle
/// @notice Returns the USD price of sUSDS by combining Chainlink’s USDS/USD feed with the
///         current sUSDS→USDS exchange rate from the sUSDS ERC-4626 vault.
/// @dev sUSDS is an ERC-4626 share token. The price is computed as
///      `price = (USDS/USD) * (sUSDS_per_share / 1e18)`,
///      where `sUSDS_per_share = IERC4626(sUSDS).convertToAssets(1e18)`.
///      - The USDS/USD quote comes from `USDS_to_USD_chainlinkOracle` and uses `_decimals` decimals.
///      - `convertToAssets` uses 18 decimals; multiplication is scaled by `10**feedDecimals` via `Math.mulDiv`
///        so the returned USD price has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDS_to_USD_chainlinkHeartbeat`.
///      If the feed is stale or the quoted price is non-positive, the function returns `(0, true)` to signal staleness.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sUSDS_PriceOracle is IPriceOracleCustom {
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
    address public immutable sUSDS;

    /// @notice Chainlink oracle for ETH to USD
    AggregatorV3Interface public immutable USDS_to_USD_chainlinkOracle;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable USDS_to_USD_chainlinkHeartbeat;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @notice Initialises the balance oracle for Savings USDS.
    /// @param sUSDS_ Address of the Savings USDS (sUSDS) vault contract.
    /// @param USDS_to_USD_ChainlinkAddress_ Address of the USDS to USD Chainlink oracle.
    /// @param USDS_to_USD_chainlinkHeartbeat_ The time in seconds after which the USDS/USD price is considered stale if
    /// not updated.
    constructor(address sUSDS_, address USDS_to_USD_ChainlinkAddress_, uint256 USDS_to_USD_chainlinkHeartbeat_) {
        sUSDS = OracleArgumentChecks.assertERC20Address(sUSDS_);

        USDS_to_USD_chainlinkOracle = OracleArgumentChecks.assertChainlinkOracle(USDS_to_USD_ChainlinkAddress_);

        USDS_to_USD_chainlinkHeartbeat = OracleArgumentChecks.assertNotZeroNumber(USDS_to_USD_chainlinkHeartbeat_);

        _decimals = USDS_to_USD_chainlinkOracle.decimals();
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IPriceOracleCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 USDS_to_USD_price,, uint256 USDS_to_USD_updatedAt,) = USDS_to_USD_chainlinkOracle.latestRoundData();

        if (USDS_to_USD_price <= 0) {
            return (0, true);
        }

        // Check if the price is stale based on its heartbeat
        if (block.timestamp - USDS_to_USD_updatedAt > USDS_to_USD_chainlinkHeartbeat) {
            stale = true;
        }

        // Get user
        uint256 sUSDS_to_USDS_price = IERC4626(sUSDS).convertToAssets(10 ** IERC4626(sUSDS).decimals());

        // sUSDS/USDS price is in 18 decimals, USDS/USD price is in 8 decimals
        // First multiply the prices together (this will have 18 + 8 = 26 decimals)
        // Then divide by 10^18 to get back to 8 decimals (matching USDS/USD)
        price = sUSDS_to_USDS_price.mulDiv(
            USDS_to_USD_price.toUint256(), 10 ** IERC4626(sUSDS).decimals(), Math.Rounding.Floor
        );
    }

    /// @inheritdoc IPriceOracleCustom
    function underlyingAssetSupported() external view override returns (address) {
        return sUSDS;
    }

    /// @inheritdoc IPriceOracleCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
