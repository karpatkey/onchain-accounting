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

/// @title sUSDe Custom Price Oracle
/// @notice Returns the USD price of sUSDe by combining Chainlink's USDe/USD feed with the
///         current sUSDe→USDe exchange rate from the sUSDe ERC-4626 vault.
/// @dev sUSDe is an ERC-4626 share token. The price is computed as
///      `price = (USDe/USD) * (sUSDe_per_share / 10^decimals)`,
///      where `sUSDe_per_share = IERC4626(sUSDe).convertToAssets(10^decimals)`.
///      - The USDe/USD quote comes from `USDE_TO_USD_CHAINLINK_ORACLE` and uses `_decimals` decimals.
///      - `convertToAssets` uses the vault's decimals; multiplication is scaled via `Math.mulDiv`
///        so the returned USD price has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDE_TO_USD_CHAINLINK_HEARTBEAT`.
///      If the feed is stale, the function still returns the computed `price` with `stale = true`.
///      If the quoted Chainlink price is non-positive, the function returns `(0, true)`.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sUSDe_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice The Staked USDe (sUSDe) vault contract address.
    address public immutable S_USDE;

    /// @notice Chainlink oracle for USDe to USD.
    AggregatorV3Interface public immutable USDE_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the USDe/USD Chainlink oracle.
    uint256 public immutable USDE_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @notice Initialises the price oracle for Staked USDe.
    /// @param sUsde_ Address of the Staked USDe (sUSDe) vault contract.
    /// @param usdeToUsdChainlinkAddress_ Address of the USDe to USD Chainlink oracle.
    /// @param usdeToUsdChainlinkHeartbeat_ The time in seconds after which the USDe/USD price is considered stale if
    /// not updated.
    constructor(address sUsde_, address usdeToUsdChainlinkAddress_, uint256 usdeToUsdChainlinkHeartbeat_) {
        S_USDE = OracleArgumentChecks.assertERC20Address(sUsde_);
        USDE_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdeToUsdChainlinkAddress_);
        USDE_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdeToUsdChainlinkHeartbeat_);
        _decimals = USDE_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 usdeToUsdPrice,, uint256 usdeToUsdUpdatedAt,) = USDE_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (usdeToUsdPrice <= 0) {
            return (0, true);
        }

        if (block.timestamp - usdeToUsdUpdatedAt > USDE_TO_USD_CHAINLINK_HEARTBEAT) {
            stale = true;
        }

        uint256 sUsdeToUsdePrice = IERC4626(S_USDE).convertToAssets(10 ** IERC4626(S_USDE).decimals());

        price =
            sUsdeToUsdePrice.mulDiv(usdeToUsdPrice.toUint256(), 10 ** IERC4626(S_USDE).decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return S_USDE;
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
