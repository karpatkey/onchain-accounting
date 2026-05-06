// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ETH+ Custom Price Oracle
/// @notice Returns the USD price of ETH+ using Reserve Protocol basket accounting.
/// @dev Price formula: (basketsNeeded / totalSupply) × basketPrice(low bound).
///      Intermediate precision is 18 decimals; final result scaled to 8 decimals (÷ 1e10).
///
/// @dev Staleness — self-contained in getLatestPrice(), consistent with all other custom feeds:
///
///      Status check: IBasketHandler.status() must be SOUND. IFFY means at least one underlying
///      Chainlink oracle has crossed its heartbeat but Reserve Protocol hasn't zeroed the price
///      yet — the value is non-zero but not trustworthy. Without this check, an IFFY basket
///      would be silently accepted as fresh.
///
///      Heartbeat check: min(IAsset.lastSave()) across all prime basket components must be within
///      RESERVE_PROTOCOL_HEARTBEAT. lastSave() is updated each time a keeper calls refresh() on
///      a collateral plugin — that call is what reads the underlying Chainlink oracle. If the
///      minimum falls behind RESERVE_PROTOCOL_HEARTBEAT, the basket price is considered stale.
///      Taking the minimum across components gives the worst-case freshness of the whole basket.
///
/// @dev latestRoundData() exposes updatedAt = min(lastSave()) for external observability.
///      Prices.sol does not call it for staleness — that is handled entirely in getLatestPrice().
///
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ETHPlus_PriceOracle is IPriceFeedCustom {
    using Math for uint256;

    address public immutable ETHPLUS;
    /// @notice Max age of min(lastSave()) across basket components before the price is stale.
    /// @dev lastSave() is a conservative proxy for the underlying Chainlink updatedAt: it tracks
    ///      when a keeper last called refresh() on a collateral plugin, which triggers the oracle read.
    ///
    /// @dev How to choose this value: set it to the longest Chainlink heartbeat among the basket's
    ///      collateral plugins. For the current ETH+ basket (rETH, cbETH, wstETH …) all underlying
    ///      ETH-denominated feeds have a 24 h (86 400 s) heartbeat, so 86 400 is the correct value.
    ///      If basket composition changes via Reserve Protocol governance, re-evaluate by checking
    ///      the heartbeat of each new collateral's underlying Chainlink feed at:
    ///      https://data.chain.link/ or https://reference-data-directory.vercel.app/feeds-mainnet.json
    uint256 public immutable RESERVE_PROTOCOL_HEARTBEAT;
    uint8 private _decimals;

    constructor(address ethPlus_, uint256 reserveProtocolHeartbeat_) {
        ETHPLUS = OracleArgumentChecks.assertERC20Address(ethPlus_);
        RESERVE_PROTOCOL_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(reserveProtocolHeartbeat_);
        _decimals = 8;
    }

    /// @inheritdoc IPriceFeedCustom
    /// @dev Returns stale=true when the basket is IFFY or DISABLED, or when the worst-case
    ///      collateral plugin refresh time exceeds RESERVE_PROTOCOL_HEARTBEAT.
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        IMain main = IRToken(ETHPLUS).main();
        IBasketHandler basketHandler = main.basketHandler();
        if (basketHandler.status() != CollateralStatus.SOUND) {
            return (0, true);
        }
        uint48 minSave = _minBasketLastSave(main, basketHandler);
        if (block.timestamp - uint256(minSave) > RESERVE_PROTOCOL_HEARTBEAT) {
            return (0, true);
        }
        uint256 usdPerToken18 = _calculateETHPlusPriceUSD18(basketHandler);
        if (usdPerToken18 == 0) return (0, true);
        price = usdPerToken18 / 1e10;
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return ETHPLUS;
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceFeedCustom
    /// @dev updatedAt = min(IAsset.lastSave()) across all prime basket components — the
    ///      worst-case oracle refresh age. roundId, startedAt, answeredInRound are zero
    ///      (Reserve Protocol has no round concept). Exposed for external observability;
    ///      staleness is handled internally in getLatestPrice().
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        IMain main = IRToken(ETHPLUS).main();
        uint48 minSave = _minBasketLastSave(main, main.basketHandler());
        (uint256 price,) = this.getLatestPrice();
        return (0, int256(price), 0, uint256(minSave), 0);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Returns the minimum lastSave() timestamp across all prime basket components.
    function _minBasketLastSave(IMain main, IBasketHandler basketHandler)
        internal
        view
        returns (uint48 minLastSave)
    {
        IAssetRegistry registry = main.assetRegistry();
        (IERC20[] memory erc20s,,) = basketHandler.getPrimeBasket();
        minLastSave = type(uint48).max;
        for (uint256 i = 0; i < erc20s.length; i++) {
            uint48 save = registry.toAsset(erc20s[i]).lastSave();
            if (save < minLastSave) minLastSave = save;
        }
        if (minLastSave == type(uint48).max) minLastSave = 0;
    }

    /// @notice Calculates ETH+ price in USD with 18-decimal precision using Reserve basket accounting.
    /// @dev Uses the 'low' price bound from basketHandler for conservative NAV calculations.
    ///      Caller must have already verified basketHandler.status() == SOUND.
    function _calculateETHPlusPriceUSD18(IBasketHandler basketHandler) internal view returns (uint256 usdPerToken18) {
        uint256 totalBasketsNeeded = uint256(IRToken(ETHPLUS).basketsNeeded());
        if (totalBasketsNeeded == 0) return 0;

        uint256 supply = IRToken(ETHPLUS).totalSupply();
        if (supply == 0) return 0;

        uint256 basketUnitsPerToken = totalBasketsNeeded.mulDiv(1e18, supply, Math.Rounding.Floor);
        if (basketUnitsPerToken == 0) return 0;

        (uint192 low,) = basketHandler.price();

        uint256 basketPriceUSD = uint256(low);
        if (basketPriceUSD == 0) return 0;

        usdPerToken18 = basketUnitsPerToken.mulDiv(basketPriceUSD, 1e18, Math.Rounding.Floor);
    }
}

enum CollateralStatus {
    SOUND,
    IFFY,
    DISABLED
}

interface IERC20 { }

interface IRToken {
    function basketsNeeded() external view returns (uint192);
    function totalSupply() external view returns (uint256);
    function main() external view returns (IMain);
}

interface IMain {
    function basketHandler() external view returns (IBasketHandler);
    function assetRegistry() external view returns (IAssetRegistry);
}

interface IBasketHandler {
    function price() external view returns (uint192 low, uint192 high);
    function status() external view returns (CollateralStatus);
    function getPrimeBasket()
        external
        view
        returns (IERC20[] memory erc20s, bytes32[] memory targetNames, uint192[] memory targetAmts);
}

interface IAssetRegistry {
    function toAsset(IERC20 erc20) external view returns (IAsset);
}

interface IAsset {
    function lastSave() external view returns (uint48);
}
