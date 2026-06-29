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

/// @title sUSDe Custom Price Oracle
/// @notice Returns the USD price of sUSDe by combining Chainlink's USDe/USD feed with the
///         current sUSDe→USDe exchange rate from the sUSDe ERC-4626 vault.
/// @dev sUSDe is an ERC-4626 share token. The price is computed as
///      `price = (USDe/USD) * (USDe_per_share / 10**_vaultDecimals)`,
///      where `USDe_per_share = IERC4626(sUSDe).convertToAssets(10**_vaultDecimals)`.
///      - The USDe/USD quote comes from `USDE_TO_USD_CHAINLINK_ORACLE` and uses `_decimals` decimals.
///      - `convertToAssets` is linear in shares, so dividing by the same `10**_vaultDecimals` used as input
///        yields the exchange rate (totalAssets/totalSupply); the result has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDE_TO_USD_CHAINLINK_HEARTBEAT`.
///      If the feed is stale or the quoted Chainlink price is non-positive, the function returns `(0, true)`.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sUSDe_CustomPriceFeed is ICustomPriceFeed {
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
    uint8 private immutable _decimals;

    /// @notice Decimals of the sUSDe vault share token (used for convertToAssets scaling).
    uint8 private immutable _vaultDecimals;

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
        _vaultDecimals = IERC4626(sUsde_).decimals();
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
        int256 usdeToUsdPrice;
        (roundId, usdeToUsdPrice, startedAt, updatedAt, answeredInRound) =
            USDE_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (usdeToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= USDE_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 sUsdeToUsdePrice = IERC4626(S_USDE).convertToAssets(10 ** _vaultDecimals);
        price = sUsdeToUsdePrice.mulDiv(usdeToUsdPrice.toUint256(), 10 ** _vaultDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return S_USDE;
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
