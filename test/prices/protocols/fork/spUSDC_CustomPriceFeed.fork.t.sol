// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {spUSDC_CustomPriceFeed} from "src/prices/protocols/spUSDC_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract spUSDC_CustomPriceFeedForkTest is TestEnvConfigurator {
    spUSDC_CustomPriceFeed oracle;

    /// @dev The LIVE vault. Spark shipped this savings family twice and the dead generation answers the same
    ///      `symbol()`; an empty ERC-4626 returns `convertToAssets` at the 1:1 default instead of reverting, so
    ///      the wrong address would price plausibly and wrongly. `test_vaultIsTheLiveGeneration` pins this.
    address constant VAULT = 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        oracle = new spUSDC_CustomPriceFeed(VAULT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: convertToAssets(unit) * NAV(base/USD, 8 dec) / unit.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        // ASSET decimals, not SHARE decimals: `ERC4626VaultRatePriceFeed` divides by `_assetUnit`.
        // Identical for this vault (shares and asset share a decimals value), so nothing fails today —
        // but this line is advertised as an INDEPENDENT ground truth for the price band, and reading
        // share decimals would silently reproduce an offset-vault bug rather than catch it. That is the
        // exact case `_assetUnit` exists for, and this file is the obvious template for the next feed.
        uint256 unit = 10 ** IERC20Metadata(IERC4626(VAULT).asset()).decimals();
        uint256 assetsPerShare = IERC4626(VAULT).convertToAssets(unit);
        uint256 expected = (assetsPerShare * base8) / unit;

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == convertToAssets(unit) * NAV(base/USD) / unit");
        assertEq(stale, false);

        // Independent band — deliberately does NOT mirror the formula above, so a 10**N mis-scale that the
        // ground-truth assert would reproduce still fails here. A USDC savings share is worth just over \$1.
        assertGe(price, 1e8, "share priced too low");
        assertLe(price, 2e8, "share priced too high - guards against a 10**N mis-scale");
    }

    /// @dev Guards the address trap directly: the dead generation has `totalSupply == 0`. If VAULT is ever
    ///      re-pointed at it, the price assert above would still pass (1:1 default rate) but this fails.
    /// @notice The vault this test pins IS the one the deploy script will read from config.
    /// @dev Without this the regression guard below is disconnected from production: `VAULT` is a constant here,
    ///      so re-pointing `custom-price-feeds/1.json` at the dead generation would leave every assertion in this
    ///      file green while the deployed feed priced the wrong vault. Binding the two means the address can only
    ///      be changed in both places at once, which is the point at which someone has to think about it.
    function test_pinnedVaultMatchesDeployConfig() public view {
        string memory cfg = vm.readFile("script/config/contracts-deployment-config/custom-price-feeds/1.json");
        assertEq(
            vm.parseJsonAddress(cfg, ".spUSDC.constructor.spUsdc"),
            VAULT,
            "deploy config points at a different vault than this test pins"
        );
        assertEq(
            vm.parseJsonAddress(cfg, ".spUSDC.constructor.baseAsset"),
            BASE,
            "deploy config points at a different base asset than this test pins"
        );
    }

    function test_vaultIsTheLiveGeneration() public view {
        assertGt(IERC4626(VAULT).totalSupply(), 0, "vault has no shares - wrong (dead) generation?");
        assertEq(IERC4626(VAULT).asset(), BASE, "vault underlying must be the configured base asset");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), VAULT, "Underlying asset should match the vault share token");
    }
}
