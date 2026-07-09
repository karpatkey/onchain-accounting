// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title wstETH Custom Price Oracle
/// @notice Returns the USD price of wstETH by combining wstETH's on-chain stEthPerToken rate with Chainlink's
///         stETH/ETH feed and the NAV's ETH/USD price.
/// @dev The price is computed as `price = stEthPerToken * (stETH/ETH) * (ETH/USD)`, where:
///      - `stEthPerToken` (stETH per 1 wstETH) comes from the wstETH contract (18 decimals)
///      - `stETH/ETH` (ETH per 1 stETH) comes from a Chainlink oracle (18 decimals)
///      - `ETH/USD` (base/USD) comes from the NAV's own selector (`getPriceData(BASE_ASSET)`, 8 decimals)
///      Intermediate `stEthPerToken * (stETH/ETH) / 1e18` yields ETH per wstETH (i.e. the wstETH/ETH price,
///      18 decimals — the stETH/ETH feed returns ETH per stETH); multiplying by ETH/USD and scaling by 1e18
///      yields the USD price (8 decimals).
///      Using the real stETH/ETH rate (rather than assuming stETH == ETH 1:1) keeps the price accurate and lets
///      ETH/USD cancel cleanly when NAV is quoted in ETH — the base/USD term now coming from the NAV makes that
///      cancellation exact (see {NavBaseUsdLib}, incl. the circularity invariant).
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract wstETH_CustomPriceFeed is ICustomPriceFeed {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice wstETH token address.
    address public immutable WSTETH;

    /// @notice Chainlink oracle for stETH to ETH (ETH per 1 stETH).
    AggregatorV3Interface public immutable STETH_TO_ETH_CHAINLINK_ORACLE;

    /// @notice NAVCalculator (proxy) the base/USD (ETH/USD) price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset whose USD price is read from the NAV (e.g. WETH). Must be priced by DIRECT feeds on the
    ///         NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} circularity invariant).
    address public immutable BASE_ASSET;

    /// @notice The heartbeat interval for the stETH/ETH Chainlink oracle.
    uint256 public immutable STETH_TO_ETH_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param wstEth_ The address of the wstETH token.
    /// @param stEthToEthChainlinkOracle_ The address of the stETH to ETH Chainlink oracle.
    /// @param stEthToEthHeartbeat_ The time in seconds after which the stETH/ETH price is considered stale.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address wstEth_,
        address stEthToEthChainlinkOracle_,
        uint256 stEthToEthHeartbeat_,
        address nav_,
        address baseAsset_
    ) {
        WSTETH = OracleArgumentChecks.assertERC20Address(wstEth_);
        STETH_TO_ETH_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(stEthToEthChainlinkOracle_);
        STETH_TO_ETH_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(stEthToEthHeartbeat_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
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
        // stETH/ETH rate leg (Chainlink), plus the base/USD (ETH/USD) term from the NAV's selector. The returned
        // updatedAt is the more conservative min(rateLegUpdatedAt, baseUpdatedAt) so callers see worst-case freshness.
        int256 stEthToEthRate;
        uint256 rateUpdatedAt;
        (roundId, stEthToEthRate, startedAt, rateUpdatedAt, answeredInRound) =
            STETH_TO_ETH_CHAINLINK_ORACLE.latestRoundData();

        (uint256 base8, bool baseStale, uint256 baseUpdatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);

        updatedAt = rateUpdatedAt <= baseUpdatedAt ? rateUpdatedAt : baseUpdatedAt;

        if (baseStale || stEthToEthRate <= 0) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 effectiveStEthUpdatedAt = rateUpdatedAt > block.timestamp ? block.timestamp : rateUpdatedAt;
        if (block.timestamp - effectiveStEthUpdatedAt >= STETH_TO_ETH_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 stEthPerToken = IwstETH(WSTETH).stEthPerToken();
        if (stEthPerToken == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        // stEthPerToken (18) * stETH/ETH (18) / 1e18 = ETH per wstETH (the wstETH/ETH price, 18 decimals)
        uint256 ethPerWstEth = stEthPerToken.mulDiv(
            uint256(stEthToEthRate), 10 ** STETH_TO_ETH_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor
        );
        // (ETH per wstETH, 18) * ETH/USD (8) / 1e18 = USD price (8 decimals)
        price = ethPerWstEth.mulDiv(base8, 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return WSTETH;
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

interface IwstETH {
    /// @notice Get amount of stETH for 1 wstETH (18 decimals).
    function stEthPerToken() external view returns (uint256);
}
