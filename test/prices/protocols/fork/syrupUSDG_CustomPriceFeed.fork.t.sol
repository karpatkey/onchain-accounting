// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {syrupUSDG_CustomPriceFeed} from "src/prices/protocols/syrupUSDG_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title syrupUSDG_CustomPriceFeed fork tests
/// @dev Pinned AFTER the USDG registration (blocks 25_992_630-25_992_635) on purpose: this feed reads USDG/USD
///      from the NAV, so at any earlier block the base leg does not resolve and `getLatestPrice` cannot return a
///      price. Note the feed would still CONSTRUCT at an earlier block — `ERC4626VaultRatePriceFeed`'s
///      constructor validates addresses and the vault's `asset()` pairing, and never reads a NAV price — so the
///      dependency is on PRICING, not on deployment order. That is the dependency worth pinning, not an
///      incidental choice of block; `test_usdgIsRegisteredAtThePinnedBlock` below asserts it directly.
///
///      Uses the LIVE NAV proxy 0x54EaD2A1…, not the superseded 0x42aC2659… that the sibling syrupUSDC fork test
///      still names.
contract syrupUSDG_CustomPriceFeedForkTest is TestEnvConfigurator {
    syrupUSDG_CustomPriceFeed oracle;

    address constant SYRUP_USDG = 0x87b65C4aAFFA76881f9E96F3e7ED945ddFC3Cd7A;
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant FORK_BLOCK = 25_992_700;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        // See the LBTC primary suite: without this the feed is exercised against the FROZEN deployed NAV
        // bytecode rather than the in-tree build, so an in-tree base-price change breaks it silently.
        _useNewNavImpl(NAV);

        oracle = new syrupUSDG_CustomPriceFeed(SYRUP_USDG, NAV, USDG);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(USDG);
        uint256 base8 = uint256(pd.price);
        // The two units are DISTINCT and must not be collapsed: `convertToAssets` takes one whole SHARE and
        // returns a value denominated in the ASSET's decimals, so the divisor is the asset unit. They are equal
        // here only because syrupUSDG is 6-dp over 6-dp USDG — writing `unit` for both would let the exact
        // decimals-offset bug `ERC4626VaultRatePriceFeed` warns about pass this test unnoticed.
        uint256 shareUnit = 10 ** IERC4626(SYRUP_USDG).decimals();
        uint256 assetUnit = 10 ** IERC20Metadata(USDG).decimals();
        uint256 assetsPerShare = IERC4626(SYRUP_USDG).convertToAssets(shareUnit);
        uint256 expected = (assetsPerShare * base8) / assetUnit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(USDG/USD) / unit");
        assertEq(stale, false);

        // Independent sanity band (does NOT mirror the impl formula): an appreciating USDG-denominated vault
        // share is worth ~$1 and never far from it. Catches a gross decimals mis-scale, which would land orders
        // of magnitude outside this band.
        assertGe(price, 1e8, "share worth >= $1 (8 dec)");
        assertLe(price, 2e8, "share worth <= $2 (8 dec) - guards against a 10**N mis-scale");
    }

    /// @notice The base leg this feed depends on must actually be registered at the pinned block.
    /// @dev Stated as its own assertion so that if the block is ever moved earlier, the failure names the cause
    ///      (USDG unregistered) instead of surfacing as an opaque revert in `setUp`.
    function test_usdgIsRegisteredAtThePinnedBlock() public view {
        assertTrue(INAVCalculator(NAV).isAssetRegistered(USDG), "USDG must be registered for the base leg");
    }

    /// @notice The vault's own asset is USDG, which is what makes USDG the only valid base.
    function test_vaultAssetIsUsdg() public view {
        assertEq(IERC4626(SYRUP_USDG).asset(), USDG, "syrupUSDG.asset() == USDG");
    }

    /// @notice A syrupUSDC-shaped copy-paste (baseAsset USDC) must revert against the REAL vault, not just a mock.
    function test_wrongBaseAsset_revertsAgainstTheRealVault() public {
        vm.expectRevert();
        new syrupUSDG_CustomPriceFeed(SYRUP_USDG, NAV, USDC);
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), SYRUP_USDG, "Underlying asset should match the vault share token");
    }
}
