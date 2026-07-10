// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NXM_CustomPriceFeed} from "src/prices/protocols/NXM_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IRammInternalPrice {
    function getInternalPrice() external view returns (uint256);
}

/// @title wNXM fork tests
/// @notice wNXM reuses NXM_CustomPriceFeed: the 1:1 wrapper a Nexus member can unwrap to NXM, priced at the
///         same RAMM book value as NXM. Verifies wNXM reports wNXM as underlying and matches a same-block NXM.
contract wNXM_CustomPriceFeedForkTest is TestEnvConfigurator {
    NXM_CustomPriceFeed wnxmPriceOracle;
    NXM_CustomPriceFeed nxmPriceOracle;

    address constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address constant WNXM = 0x0d438F3b5175Bebc262bF23753C1E53d03432bDE;
    address constant RAMM = 0xcafea54f03E1Cc036653444e581A10a43B2487CD;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        wnxmPriceOracle = new NXM_CustomPriceFeed(WNXM, RAMM, NAV, WETH);
        nxmPriceOracle = new NXM_CustomPriceFeed(NXM, RAMM, NAV, WETH);
    }

    /// @dev In-EVM ground truth: RAMM.getInternalPrice() (ETH/NXM, 18 dec) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        uint256 rate = IRammInternalPrice(RAMM).getInternalPrice();
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = wnxmPriceOracle.getLatestPrice();
        assertEq(price, expected, "wNXM priced at NXM book value = RAMM.getInternalPrice() * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_matchesNxmPrice() public view {
        (uint256 wnxmPrice,) = wnxmPriceOracle.getLatestPrice();
        (uint256 nxmPrice,) = nxmPriceOracle.getLatestPrice();
        assertEq(wnxmPrice, nxmPrice, "wNXM and NXM share the same RAMM book price");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(wnxmPriceOracle.underlyingAssetSupported(), WNXM, "Underlying asset should match wNXM token");
    }
}
