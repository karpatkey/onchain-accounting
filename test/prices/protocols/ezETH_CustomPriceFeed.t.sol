// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ezETH_CustomPriceFeed} from "src/prices/protocols/ezETH_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title ezETH_CustomPriceFeed unit tests (no fork)
/// @dev Base/USD (ETH/USD) now comes from the NAV via a Mock_NAVCalculator; the constructor takes
///      `(ezEth, restakeManager, nav, baseAsset)`. Arithmetic is exercised in the fork test against real Renzo state.

/// @notice Renzo RestakeManager stand-in returning a canonical `(uint256[][], uint256[], uint256)`.
/// @dev Records the selector it was called with, so a test can pin the calldata the feed's raw assembly builds.
contract Mock_RestakeManager {
    uint256 public totalTVL;

    constructor(uint256 totalTVL_) {
        totalTVL = totalTVL_;
    }

    /// @dev MUST be `view`. The feed reads it with `staticcall`, so a state-mutating mock would hit the EVM's
    ///      write-protection abort — which consumes every wei of forwarded gas and makes the feed read stale for
    ///      a reason that has nothing to do with the code under test. The first draft of this mock recorded
    ///      `msg.sig` into storage and failed exactly that way; the selector is pinned with `vm.expectCall`
    ///      instead, which observes the calldata without needing the callee to mutate.
    function calculateTVLs() external view returns (uint256[][] memory a, uint256[] memory b, uint256 c) {
        a = new uint256[][](2); // non-trivial tail, so head words 0 and 1 are OFFSETS, not the value
        a[0] = new uint256[](3);
        a[1] = new uint256[](2);
        b = new uint256[](4);
        c = totalTVL;
    }
}

/// @notice Answers the selector but with fewer than the three head words the feed requires.
contract Mock_ShortReply {
    fallback() external {
        assembly {
            mstore(0x00, 1)
            mstore(0x20, 2)
            return(0x00, 0x40) // 64 bytes — one word short
        }
    }
}

/// @notice Returns 80 bytes: two full head words plus HALF of the third, with non-zero content in that half.
/// @dev The case the `returndatasize() >= 96` guard actually exists for, and the only one that distinguishes it
///      from the window-zeroing. For a reply of <= 64 bytes the third word keeps the zeros written before the
///      call, so the guard and the zeroing agree. Between 65 and 95 bytes the EVM writes PART of the third word
///      and leaves the rest zero, so `mload` returns a spliced value that is neither the callee's nor zero.
///      Without the size check the feed would publish that as `totalTVL`.
contract Mock_PartialThirdWord {
    fallback() external {
        assembly {
            mstore(0x00, 1)
            mstore(0x20, 2)
            mstore(0x40, not(0)) // third word all-ones; only its top 16 bytes get copied
            return(0x00, 0x50) // 80 bytes
        }
    }
}

/// @notice Succeeds and returns NOTHING — the ERC-1967-proxy-over-codeless-impl shape.
contract Mock_EmptyReply {
    fallback() external {
        assembly {
            return(0x00, 0x00)
        }
    }
}

contract ezETH_CustomPriceFeedTest is Test {
    Mock_ERC20 ezEth;
    Mock_ERC20 weth;
    Mock_NAVCalculator nav;
    address restakeManager;

    function setUp() public {
        ezEth = new Mock_ERC20("ezETH", 18);
        weth = new Mock_ERC20("WETH", 18);
        nav = new Mock_NAVCalculator();
        nav.setAssetPrice(address(weth), 3000e8, 8); // ETH/USD = $3000
        restakeManager = address(nav); // only checked non-zero at construction
    }

    function test_constructor_valid() public {
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), restakeManager, address(nav), address(weth));
        assertEq(oracle.decimals(), 8, "decimals == NAV_DECIMALS");
        assertEq(oracle.underlyingAssetSupported(), address(ezEth));
    }

    function test_invalidConstructorArgs() public {
        // zero ezETH
        vm.expectRevert();
        new ezETH_CustomPriceFeed(address(0), restakeManager, address(nav), address(weth));

        // zero restakeManager
        vm.expectRevert();
        new ezETH_CustomPriceFeed(address(ezEth), address(0), address(nav), address(weth));

        // zero nav (not a contract)
        vm.expectRevert();
        new ezETH_CustomPriceFeed(address(ezEth), restakeManager, address(0), address(weth));

        // zero base asset
        vm.expectRevert();
        new ezETH_CustomPriceFeed(address(ezEth), restakeManager, address(nav), address(0));

        // base asset not an ERC20 (nav has no totalSupply)
        vm.expectRevert();
        new ezETH_CustomPriceFeed(address(ezEth), restakeManager, address(nav), address(nav));
    }

    // ─── _rate(): the raw-assembly read ──────────────────────────────────────
    //
    // These did not exist. `restakeManager` was `address(nav)` and only checked non-zero at construction, so
    // `_rate()` had NO non-fork coverage at all — which is why a review claim about the selector could only be
    // answered by running a fork. The assembly reads head word 2 of a
    // `(uint256[][], uint256[], uint256)` return through a fixed 96-byte output window.

    /// @notice The happy path pins BOTH the selector and the head-word-2 offset.
    /// @dev The mock returns non-empty arrays, so head words 0 and 1 are ABI OFFSETS (0x60, and 0x60+tail).
    ///      Reading either instead of word 2 would produce a wildly different price, so this asserting the exact
    ///      expected value is what makes the offset load-bearing rather than incidental.
    function test_rate_readsTotalTVLFromHeadWordTwo() public {
        ezEth.mint(address(this), 100e18); // supply = 100e18
        Mock_RestakeManager rm = new Mock_RestakeManager(120e18); // rate = 1.2e18
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(rm), address(nav), address(weth));

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertFalse(stale, "a well-formed reply must not read stale");
        // rate(1.2e18) * base8(3000e8) / 1e18 == 3600e8
        assertEq(price, 3600e8, "price == (totalTVL/supply) * base/USD");
    }

    /// @notice The calldata the assembly builds really is `calculateTVLs()`.
    /// @dev Pins the `bytes4` alignment directly. A review round claimed `mstore(0x00, selector)` right-aligns
    ///      the selector, making the calldata `0x00000000`. It does not — `bytes4` is left-aligned in its word
    ///      (the same idiom `LabelLib._readString` uses and documents) — and this asserts it without a fork.
    function test_rate_callsTheCalculateTVLsSelector() public {
        ezEth.mint(address(this), 100e18);
        Mock_RestakeManager rm = new Mock_RestakeManager(120e18);
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(rm), address(nav), address(weth));

        // Asserts the exact 4 calldata bytes. If the selector were right-aligned in its word the calldata would
        // be 0x00000000 and this would not match.
        vm.expectCall(address(rm), abi.encodeWithSelector(Mock_RestakeManager.calculateTVLs.selector));
        oracle.getLatestPrice();
    }

    /// @notice A reply one word short of the head is rejected, not partially read.
    function test_rate_shortReply_isStaleNotInvented() public {
        ezEth.mint(address(this), 100e18);
        Mock_ShortReply short = new Mock_ShortReply();
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(short), address(nav), address(weth));

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "a 64-byte reply must not yield a price");
        assertTrue(stale, "and must mark the feed stale");
    }

    /// @notice The trigger the fix exists for: a call that SUCCEEDS and returns nothing.
    /// @dev This is the ERC-1967 proxy whose implementation slot points at a code-less address. Under the old
    ///      `try`/`catch` over `(uint256[][], uint256[], uint256)` the decoder rejected the empty reply and
    ///      reverted in the CALLING frame, past the `catch` — so `_rate()` reverted instead of returning 0.
    function test_rate_emptyReply_returnsZeroRatherThanReverting() public {
        ezEth.mint(address(this), 100e18);
        Mock_EmptyReply empty = new Mock_EmptyReply();
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(empty), address(nav), address(weth));

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0);
        assertTrue(stale, "empty returndata must mark stale, not revert");
    }

    /// @notice A code-less restake manager degrades to stale rather than reverting.
    function test_rate_codelessTarget_isStale() public {
        ezEth.mint(address(this), 100e18);
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(0xDEAD), address(nav), address(weth));

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0);
        assertTrue(stale);
    }

    /// @notice Zero ezETH supply is stale, not a division by zero.
    function test_rate_zeroSupply_isStale() public {
        Mock_RestakeManager rm = new Mock_RestakeManager(120e18);
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(rm), address(nav), address(weth));

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0);
        assertTrue(stale);
    }

    /// @notice A partially-written third head word must not be published as a price.
    /// @dev This is what makes the `returndatasize() >= 96` guard load-bearing. Verified by mutation: removing
    ///      that guard leaves every other test in this file green and fails only this one, because the other
    ///      short-reply cases are already covered by zeroing the output window.
    function test_rate_partialThirdWord_isRejectedNotSpliced() public {
        ezEth.mint(address(this), 100e18);
        Mock_PartialThirdWord splicer = new Mock_PartialThirdWord();
        ezETH_CustomPriceFeed oracle =
            new ezETH_CustomPriceFeed(address(ezEth), address(splicer), address(nav), address(weth));

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "a spliced third word must not become a price");
        assertTrue(stale, "an 80-byte reply must mark the feed stale");
    }
}
