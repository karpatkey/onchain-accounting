// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
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
///      `price = (USDS/USD) * (sUSDS_per_share / 1e18)`,
///      where `sUSDS_per_share = IERC4626(sUSDS).convertToAssets(1e18)`.
///      - The USDS/USD quote comes from `USDS_to_USD_chainlinkOracle` and uses `_decimals` decimals.
///      - `convertToAssets` uses 18 decimals; multiplication is scaled by `10**feedDecimals` via `Math.mulDiv`
///        so the returned USD price has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDS_to_USD_chainlinkHeartbeat`.
///      If the feed is stale or the quoted price is non-positive, the function returns `(0, true)` to signal staleness.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sUSDS_PriceOracle is IPriceFeedCustom {
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

    /// @notice Chainlink oracle for ETH to USD
    AggregatorV3Interface public immutable USDS_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable USDS_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @notice Initialises the balance oracle for Savings USDS.
    /// @param sUsds_ Address of the Savings USDS (sUSDS) vault contract.
    /// @param usdsToUsdChainlinkAddress_ Address of the USDS to USD Chainlink oracle.
    /// @param usdsToUsdChainlinkHeartbeat_ The time in seconds after which the USDS/USD price is considered stale if
    /// not updated.
    constructor(address sUsds_, address usdsToUsdChainlinkAddress_, uint256 usdsToUsdChainlinkHeartbeat_) {
        S_USDS = OracleArgumentChecks.assertERC20Address(sUsds_);

        USDS_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdsToUsdChainlinkAddress_);

        USDS_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdsToUsdChainlinkHeartbeat_);

        _decimals = USDS_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IBalanceOracleCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 usdsToUsdPrice,, uint256 usdsToUsdUpdatedAt,) = USDS_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (usdsToUsdPrice <= 0) {
            return (0, true);
        }

        // Check if the price is stale based on its heartbeat
        if (block.timestamp - usdsToUsdUpdatedAt > USDS_TO_USD_CHAINLINK_HEARTBEAT) {
            stale = true;
        }

        // Get user
        uint256 sUsdsToUsdsPrice = IERC4626(S_USDS).convertToAssets(10 ** IERC4626(S_USDS).decimals());

        // sUSDS/USDS price is in 18 decimals, USDS/USD price is in 8 decimals
        // First multiply the prices together (this will have 18 + 8 = 26 decimals)
        // Then divide by 10^18 to get back to 8 decimals (matching USDS/USD)
        price =
            sUsdsToUsdsPrice.mulDiv(usdsToUsdPrice.toUint256(), 10 ** IERC4626(S_USDS).decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return S_USDS;
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
