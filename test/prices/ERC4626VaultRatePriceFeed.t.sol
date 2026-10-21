// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";
import {Mock_ERC20, Mock_ERC4626} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @dev Concrete instantiation of the abstract base for scaling tests.
contract _ExposedERC4626Feed is ERC4626VaultRatePriceFeed {
    constructor(address vault_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(vault_, nav_, baseAsset_) {}
}

/// @title ERC4626VaultRatePriceFeed scaling tests
/// @notice Locks in the divisor invariant: `convertToAssets(1 share)` is denominated in the UNDERLYING's decimals,
///         so the price divisor must be `10**assetDecimals`, not `10**shareDecimals`. The two differ only when the
///         vault uses a decimals offset — a case the config-mirroring fork tests can't catch, so it lives here.
contract ERC4626VaultRatePriceFeedTest is Test {
    Mock_NAVCalculator nav;

    function setUp() public {
        nav = new Mock_NAVCalculator();
    }

    /// @dev The regression case: 18-decimal shares over a 6-decimal underlying (USDC-style decimals offset).
    ///      Rate = 1.05 assets/share, base = $1.00. Correct price = 1.05e8. The old `10**shareDecimals` divisor
    ///      floored this to 0 (a 10^12 under-scale); this asserts the fixed `10**assetDecimals` divisor.
    function test_scaling_shareDecimalsGtAssetDecimals() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8); // USDC/USD = $1
        // 1 whole 18-dec share -> 1.05 USDC (1.05e6 in 6-dec underlying units)
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 1.05e6);

        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));
        (uint256 price, bool stale) = feed.getLatestPrice();

        assertFalse(stale, "not stale");
        assertEq(price, 1.05e8, "1.05 assets/share * $1 = $1.05 at 8 decimals");
    }

    /// @dev Matched decimals (6/6, like the shipped syrupUSDC vault) — must stay correct after the fix.
    function test_scaling_shareDecimalsEqAssetDecimals() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 6, address(usdc), 1.05e6);

        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));
        (uint256 price, bool stale) = feed.getLatestPrice();

        assertFalse(stale, "not stale");
        assertEq(price, 1.05e8, "1.05 assets/share * $1 = $1.05 at 8 decimals");
    }

    /// @dev 18/18 (like the shipped sUSDe/sUSDS/sGHO vaults), non-unit base price.
    function test_scaling_eighteenOverEighteen() public {
        Mock_ERC20 usde = new Mock_ERC20("USDe", 18);
        nav.setAssetPrice(address(usde), 1.02e8, 8); // USDe/USD = $1.02
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usde), 1.1e18); // 1.1 USDe/share

        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usde));
        (uint256 price, bool stale) = feed.getLatestPrice();

        assertFalse(stale, "not stale");
        // 1.1 * 1.02 = 1.122 -> 1.122e8
        assertEq(price, 1.122e8, "1.1 assets/share * $1.02 = $1.122 at 8 decimals");
    }

    /// @dev Base-stale propagates to the feed as a FLAG (ADR 0029): the share is still priced off the stale base.
    function test_baseStale_propagates() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 1.05e6);
        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));

        nav.setAssetStale(address(usdc), true);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "stale when base stale");
        assertEq(price, 1.05e8, "priced off the last base price when the base is stale");
    }

    /// @dev No usable base price at all (the NAV returns price 0) is the structural case that still returns 0.
    function test_baseUnpriced_returnsZero() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 1.05e6);
        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));

        nav.setAssetPrice(address(usdc), 0, 8, true); // stale with no usable price
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0, "no base price => 0");
    }

    /// @dev A zero share rate is structural and still returns 0, even with a fresh base.
    function test_zeroShareRate_returnsZero() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 0);
        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale);
        assertEq(price, 0);
    }

    /// @dev Constructor rejects a baseAsset that isn't the vault's own underlying (would price against the wrong asset).
    function test_constructor_rejectsBaseAssetMismatch() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        nav.setAssetPrice(address(weth), 3000e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 1e6); // underlying = USDC
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626VaultRatePriceFeed.BaseAssetMismatch.selector, address(usdc), address(weth))
        );
        new _ExposedERC4626Feed(address(vault), address(nav), address(weth)); // baseAsset WETH != USDC underlying
    }

    /// @dev L2 sequencer-down alone must NOT zero the feed (F1): the base's `pd.stale` is folded true by the sequencer,
    ///      but `pd.sequencerDown` un-folds it so the last base price is still used — matching how computeNav prices
    ///      direct positions during an outage. Otherwise custom positions would crater to $0 while direct ones stay live.
    function test_sequencerDown_doesNotZero() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 1.05e6);
        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));

        nav.setSequencerDown(address(usdc), true); // folds pd.stale=true, pd.sequencerDown=true
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "sequencer-down alone must not mark the feed stale");
        assertEq(price, 1.05e8, "last base price still used during a sequencer outage");

        // Sequencer recovers on an otherwise-fresh feed -> back to fresh (mock folds at read, so this recovers).
        nav.setSequencerDown(address(usdc), false);
        (price, stale) = feed.getLatestPrice();
        assertFalse(stale, "fresh again after sequencer recovers");
        assertEq(price, 1.05e8, "price restored after recovery");
    }

    /// @dev Sequencer-down while the base feed is ALSO genuinely stale: the feed IS stale, and (ADR 0029) still priced
    ///      off the last base price. The sequencer-unfold in `NavBaseUsdLib` must not rescue a genuinely-stale base:
    ///      before ADR 0029 that held only because a stale selection returned price 0; now the price is kept, so the
    ///      flag must come from the base's own freshness (`healthyFeedCount == 0`), not from `stale && !sequencerDown`.
    function test_sequencerDown_withStaleFeed_isStale() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        nav.setAssetPrice(address(usdc), 1e8, 8);
        Mock_ERC4626 vault = new Mock_ERC4626("v", 18, address(usdc), 1.05e6);
        _ExposedERC4626Feed feed = new _ExposedERC4626Feed(address(vault), address(nav), address(usdc));

        nav.setAssetStale(address(usdc), true); // feed genuinely stale -> price kept, healthyFeedCount 0
        nav.setSequencerDown(address(usdc), true); // AND sequencer down
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "genuinely-stale base is stale even during a sequencer outage");
        assertEq(price, 1.05e8, "still priced off the last base price");
    }
}
