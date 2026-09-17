// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {syrupUSDT_CustomPriceFeed} from "src/prices/protocols/syrupUSDT_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title syrupUSDT_CustomPriceFeed fork tests
/// @dev Against the real Maple syrupUSDT vault and the LIVE NAV proxy. Unlike the syrupUSDG sibling this feed
///      has no prerequisite registration to wait for — its base asset USDT has been registered with a direct
///      Chainlink primary throughout — so the block choice is not load-bearing here.
contract syrupUSDT_CustomPriceFeedForkTest is TestEnvConfigurator {
    syrupUSDT_CustomPriceFeed oracle;

    address constant SYRUP_USDT = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant FORK_BLOCK = 25_992_700;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        // Point the live proxy at the IN-TREE NAVCalculator/PriceFeedLib. Without it this suite would exercise
        // the FROZEN deployed bytecode, so an in-tree change to the base-price path would break this feed while
        // the test stayed green — the defect review caught in the LBTC/syrupUSDG suites.
        _useNewNavImpl(NAV);

        oracle = new syrupUSDT_CustomPriceFeed(SYRUP_USDT, NAV, USDT);
    }

    /// @dev In-EVM ground truth. The SHARE unit and the ASSET unit are deliberately separate variables:
    ///      `convertToAssets` takes one whole share and returns a value in the ASSET's decimals, so the divisor
    ///      is the asset unit. They are equal here (6 over 6) — collapsing them into one `unit` would let the
    ///      decimals-offset bug `ERC4626VaultRatePriceFeed` warns about pass unnoticed.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(USDT);
        uint256 base8 = uint256(pd.price);
        uint256 shareUnit = 10 ** IERC4626(SYRUP_USDT).decimals();
        uint256 assetUnit = 10 ** IERC20Metadata(USDT).decimals();
        uint256 assetsPerShare = IERC4626(SYRUP_USDT).convertToAssets(shareUnit);
        uint256 expected = (assetsPerShare * base8) / assetUnit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(shareUnit) * NAV(USDT/USD) / assetUnit");
        assertEq(stale, false);

        // Independent sanity band that does NOT mirror the formula: an appreciating USDT-denominated vault share
        // is worth ~$1 and never far from it, so a gross 10**N mis-scale lands orders of magnitude outside.
        assertGe(price, 1e8, "share worth >= $1 (8 dec)");
        assertLe(price, 2e8, "share worth <= $2 (8 dec)");
    }

    /// @notice The vault's own asset is USDT, which is what makes USDT the only valid base.
    function test_vaultAssetIsUsdt() public view {
        assertEq(IERC4626(SYRUP_USDT).asset(), USDT, "syrupUSDT.asset() == USDT");
    }

    /// @notice A sibling-shaped copy-paste (baseAsset USDC) must revert against the REAL vault, not just a mock.
    function test_wrongBaseAsset_revertsAgainstTheRealVault() public {
        vm.expectRevert();
        new syrupUSDT_CustomPriceFeed(SYRUP_USDT, NAV, USDC);
    }

    /// @notice The share rate is above par — the property that makes the asset Appreciating.
    function test_rateIsAbovePar() public view {
        uint256 shareUnit = 10 ** IERC4626(SYRUP_USDT).decimals();
        assertGt(IERC4626(SYRUP_USDT).convertToAssets(shareUnit), shareUnit, "1 share redeems for > 1 USDT");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), SYRUP_USDT, "Underlying asset should be the vault share token");
    }
}
