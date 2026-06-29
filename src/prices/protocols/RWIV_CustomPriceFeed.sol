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

/// @title RWIV Custom Price Oracle
/// @notice Returns the USD price of RWIV (Nexus Mutual RWI Vault share) by combining Chainlink's
///         USDC/USD feed with the current RWIV→USDC exchange rate from the RWIV ERC-4626 vault.
/// @dev RWIV is an ERC-4626 share token with USDC as its underlying asset. The price is computed as
///      `price = (USDC/USD) * (USDC_per_share / 10^_vaultDecimals)`,
///      where `USDC_per_share = IERC4626(RWIV).convertToAssets(10^_vaultDecimals)`.
///      - The USDC/USD quote comes from `USDC_TO_USD_CHAINLINK_ORACLE` and uses `_decimals` decimals.
///      - `convertToAssets` uses the vault's decimals (`_vaultDecimals`); multiplication is scaled via
///        `Math.mulDiv` so the returned USD price has `_decimals` decimals.
///      Freshness is enforced on the Chainlink feed using `USDC_TO_USD_CHAINLINK_HEARTBEAT`.
///      If the feed is stale or the quoted Chainlink price is non-positive, the function returns `(0, true)`.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract RWIV_CustomPriceFeed is ICustomPriceFeed {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice The RWIV vault contract address.
    address public immutable RWIV;

    /// @notice Chainlink oracle for USDC to USD.
    AggregatorV3Interface public immutable USDC_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the USDC/USD Chainlink oracle.
    uint256 public immutable USDC_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    /// @notice Decimals of the RWIV vault share token (used for convertToAssets scaling).
    uint8 private immutable _vaultDecimals;

    //
    // Constructor
    //

    /// @notice Initialises the price oracle for RWIV.
    /// @param rwiv_ Address of the RWIV vault contract.
    /// @param usdcToUsdChainlinkAddress_ Address of the USDC to USD Chainlink oracle.
    /// @param usdcToUsdChainlinkHeartbeat_ The time in seconds after which the USDC/USD price is considered stale if
    /// not updated.
    constructor(address rwiv_, address usdcToUsdChainlinkAddress_, uint256 usdcToUsdChainlinkHeartbeat_) {
        RWIV = OracleArgumentChecks.assertERC20Address(rwiv_);
        USDC_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdcToUsdChainlinkAddress_);
        USDC_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdcToUsdChainlinkHeartbeat_);
        _decimals = USDC_TO_USD_CHAINLINK_ORACLE.decimals();
        _vaultDecimals = IERC4626(rwiv_).decimals();
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
        int256 usdcToUsdPrice;
        (roundId, usdcToUsdPrice, startedAt, updatedAt, answeredInRound) =
            USDC_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (usdcToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= USDC_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 rwivToUsdcPrice = IERC4626(RWIV).convertToAssets(10 ** _vaultDecimals);
        price = rwivToUsdcPrice.mulDiv(usdcToUsdPrice.toUint256(), 10 ** _vaultDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return RWIV;
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
