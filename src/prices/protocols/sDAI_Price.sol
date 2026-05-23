// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title sDAI Custom Price Oracle
/// @notice Returns the USD price of sDAI by combining Chainlink’s DAI/USD feed with Maker’s DSR “chi” ratio.
/// @dev The price is computed as `price = (DAI/USD) * (sDAI/DAI)`, where:
///      - `DAI/USD` comes from `DAI_to_USD_chainlinkOracle` and uses `_decimals` decimals.
///      - `sDAI/DAI` is Maker’s DSR Pot `chi` (27-decimals, RAY) read via `RATE_PROVIDER`.
///      The function multiplies these values and scales by `10**RATIO_DECIMALS` (1e27) so the result has `_decimals`.
///      Freshness is enforced only on the Chainlink feed using `DAI_to_USD_chainlinkHeartbeat`; if the feed is stale
///      or any input is non-positive, the function returns `(0, true)` to signal staleness.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sDAI_PriceOracle is IPriceFeedCustom {
    using Math for uint256;

    //
    // State
    //

    /// @notice Chainlink oracle for DAI to USD
    /// solhint-disable-next-line var-name-mixedcase
    AggregatorV3Interface public immutable DAI_TO_USD_CHAINLINK_ORACLE;

    /// @notice rate provider for (sDAI / DAI)
    PotLike public immutable RATE_PROVIDER;

    /// @notice Address of the sDAI token
    address public immutable S_DAI;

    /// @notice Number of decimals for sDAI / DAI ratio
    uint8 public constant RATIO_DECIMALS = 27;

    /// @notice The heartbeat interval for the Chainlink oracle.
    /// solhint-disable-next-line var-name-mixedcase
    uint256 public immutable DAI_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param sDai_ The address of the sDAI token
    /// @param dsrManager_ The address of the DSR Manager contract
    /// @param daiToUsdChainlinkOracle_ The address of the DAI to USD Chainlink oracle.
    /// @param daiToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not
    /// updated
    constructor(
        address sDai_,
        address dsrManager_,
        address daiToUsdChainlinkOracle_,
        uint256 daiToUsdChainlinkHeartbeat_
    ) {
        S_DAI = OracleArgumentChecks.assertERC20Address(sDai_);

        DAI_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(daiToUsdChainlinkOracle_);

        DAI_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(daiToUsdChainlinkHeartbeat_);

        DsrManager dsrManager = DsrManager(OracleArgumentChecks.assertNonZeroAddress(dsrManager_));

        _decimals = DAI_TO_USD_CHAINLINK_ORACLE.decimals();
        RATE_PROVIDER = dsrManager.pot();
    }

    //
    // IPriceFeedCustom
    //

    function _compute()
        private
        view
        returns (uint256 price, bool stale, uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        int256 daiToUsdPrice;
        (roundId, daiToUsdPrice, startedAt, updatedAt, answeredInRound) = DAI_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (daiToUsdPrice <= 0) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= DAI_TO_USD_CHAINLINK_HEARTBEAT) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
        uint256 chi = RATE_PROVIDER.chi();
        if (chi == 0) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
        price = uint256(daiToUsdPrice).mulDiv(chi, 10 ** uint256(RATIO_DECIMALS), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return S_DAI;
    }

    /// @inheritdoc IPriceFeedCustom
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
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface DsrManager {
    /// @notice from the original DsrManager contract
    /// @return The pot value
    function pot() external view returns (PotLike);
}

interface PotLike {
    /// @notice from the original Pot contract
    /// @return chi The chi value
    function chi() external view returns (uint256 chi);
}
