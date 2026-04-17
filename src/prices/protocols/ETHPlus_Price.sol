// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ETH+ Custom Price Oracle
/// @notice Returns the USD price of ETH+ using Reserve protocol basket accounting.
/// @dev ETH+ uses USD as Unit of Account. price = (basketsNeeded / totalSupply) * basketPrice (low bound).
///      Intermediate precision is 18 decimals; final result scaled to 8 decimals (divide by 1e10).
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ETHPlus_PriceOracle is IPriceFeedCustom {
    using Math for uint256;

    address public immutable ETHPLUS;
    uint8 private _decimals;

    constructor(address ethPlus_) {
        ETHPLUS = OracleArgumentChecks.assertERC20Address(ethPlus_);
        _decimals = 8;
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        uint256 usdPerToken18 = _calculateETHPlusPriceUSD18();
        if (usdPerToken18 == 0) {
            return (0, true);
        }
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Calculates ETH+ price in USD with 18-decimal precision using Reserve basket accounting.
    /// @dev Uses the 'low' price bound from basketHandler for conservative NAV calculations.
    function _calculateETHPlusPriceUSD18() internal view returns (uint256 usdPerToken18) {
        uint256 totalBasketsNeeded = uint256(IRToken(ETHPLUS).basketsNeeded());
        if (totalBasketsNeeded == 0) return 0;

        uint256 supply = IRToken(ETHPLUS).totalSupply();
        if (supply == 0) return 0;

        uint256 basketUnitsPerToken = totalBasketsNeeded.mulDiv(1e18, supply, Math.Rounding.Floor);
        if (basketUnitsPerToken == 0) return 0;

        IMain main = IRToken(ETHPLUS).main();
        IBasketHandler basketHandler = main.basketHandler();
        (uint192 low,) = basketHandler.price();

        uint256 basketPriceUSD = uint256(low);
        if (basketPriceUSD == 0) return 0;

        usdPerToken18 = basketUnitsPerToken.mulDiv(basketPriceUSD, 1e18, Math.Rounding.Floor);
    }
}

interface IRToken {
    function basketsNeeded() external view returns (uint192);
    function totalSupply() external view returns (uint256);
    function main() external view returns (IMain);
}

interface IMain {
    function basketHandler() external view returns (IBasketHandler);
}

interface IBasketHandler {
    function price() external view returns (uint192 low, uint192 high);
}
