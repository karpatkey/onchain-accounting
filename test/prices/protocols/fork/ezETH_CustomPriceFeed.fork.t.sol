// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ezETH_CustomPriceFeed} from "src/prices/protocols/ezETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRestakeManagerTVL {
    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);
}

contract ezETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    ezETH_CustomPriceFeed oracle;

    address constant EZETH = 0xbf5495Efe5DB9ce00f80364C8B423567e58d2110;
    address constant RESTAKE_MANAGER = 0x74a09653A083691711cF8215a6ab074BB4e99ef5;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new ezETH_CustomPriceFeed(EZETH, RESTAKE_MANAGER, NAV, WETH);
    }

    /// @dev In-EVM ground truth: (totalTVL * 1e18 / ezETH.totalSupply()) * NAV base/USD (8 dec) / 1e18.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(WETH);
        uint256 base8 = uint256(pd.price);
        (,, uint256 totalTVL) = IRestakeManagerTVL(RESTAKE_MANAGER).calculateTVLs();
        uint256 supply = IERC20(EZETH).totalSupply();
        uint256 rate = (totalTVL * 1e18) / supply;
        uint256 expected = (rate * base8) / 1e18;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (totalTVL/supply) * NAV(ETH/USD) / 1e18");
        assertEq(stale, false);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), EZETH, "Underlying asset should match ezETH token");
    }
}
