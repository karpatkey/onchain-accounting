// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title syrupUSDC Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC by combining Chainlink's USDC/USD feed with the
///         current syrupUSDC→USDC exchange rate from the syrupUSDC ERC-4626 vault.
/// @dev syrupUSDC is an ERC-4626 share token. The price is computed as
///      `price = (USDC/USD) * (syrupUSDC_per_share / 10^decimals)`,
///      where `syrupUSDC_per_share = IERC4626(syrupUSDC).convertToAssets(10^decimals)`.
///      - The USDC/USD quote comes from `USDC_TO_USD_CHAINLINK_ORACLE` and uses `_decimals` decimals.
///      - `convertToAssets` uses the vault's decimals; multiplication is scaled via `Math.mulDiv`
///        so the returned USD price has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDC_TO_USD_CHAINLINK_HEARTBEAT`.
///      If the feed is stale, the function still returns the computed `price` with `stale = true`.
///      If the quoted Chainlink price is non-positive, the function returns `(0, true)`.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract syrupUSDC_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice The syrupUSDC vault contract address.
    address public immutable SYRUP_USDC;

    /// @notice Chainlink oracle for USDC to USD.
    AggregatorV3Interface public immutable USDC_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the USDC/USD Chainlink oracle.
    uint256 public immutable USDC_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @notice Initialises the price oracle for syrupUSDC.
    /// @param syrupUsdc_ Address of the syrupUSDC vault contract.
    /// @param usdcToUsdChainlinkAddress_ Address of the USDC to USD Chainlink oracle.
    /// @param usdcToUsdChainlinkHeartbeat_ The time in seconds after which the USDC/USD price is considered stale if
    /// not updated.
    constructor(address syrupUsdc_, address usdcToUsdChainlinkAddress_, uint256 usdcToUsdChainlinkHeartbeat_) {
        SYRUP_USDC = OracleArgumentChecks.assertERC20Address(syrupUsdc_);
        USDC_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdcToUsdChainlinkAddress_);
        USDC_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdcToUsdChainlinkHeartbeat_);
        _decimals = USDC_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 usdcToUsdPrice,, uint256 usdcToUsdUpdatedAt,) = USDC_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (usdcToUsdPrice <= 0) {
            return (0, true);
        }

        if (block.timestamp - usdcToUsdUpdatedAt > USDC_TO_USD_CHAINLINK_HEARTBEAT) {
            stale = true;
        }

        uint256 syrupUsdcToUsdcPrice = IERC4626(SYRUP_USDC).convertToAssets(10 ** IERC4626(SYRUP_USDC).decimals());

        price = syrupUsdcToUsdcPrice.mulDiv(
            usdcToUsdPrice.toUint256(), 10 ** IERC4626(SYRUP_USDC).decimals(), Math.Rounding.Floor
        );
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return SYRUP_USDC;
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
