// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UniswapV3PoolsBalanceAdapter} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NotTokenOwner, TokenIdCacheFull} from "src/errors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockPositionManager,
    MockUniswapV3Pool,
    MockUniswapV3Factory,
    MockToken
} from "test/balances/AssistedBalanceAdapters/UniswapV3Mocks.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";

/// @title UniswapV3PoolsBalanceAdapter unit tests (no fork)
/// @notice Assisted (agent-fed) tokenId cache + per-NFT decomposition for UniswapV3Pools. The adapter reads
///         `positions(tokenId)`, splits the principal at the pool's live `slot0` (instantaneous on-chain amounts;
///         ADR 0017) and resolves the pool address (positionId) via the factory — so these tests drive it through
///         the NPM/factory/pool mocks + the cache.
contract UniswapV3PoolsBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    MockUniswapV3Factory factory;
    UniswapV3PoolsBalanceAdapter adapter;

    MockToken wbtc; // NFT 1 token0
    MockToken weth; // shared token1
    MockToken usdc; // NFT 2 token0
    MockUniswapV3Pool poolA; // WBTC/WETH 0.3% (NFT 1)
    MockUniswapV3Pool poolB; // USDC/WETH 0.05% (NFT 2)

    address alice = makeAddr("alice");
    address other = makeAddr("other");

    bytes32 constant ASSISTANT_ROLE = keccak256("ASSISTANT_ROLE");

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        wbtc = new MockToken("WBTC", 8);
        weth = new MockToken("WETH", 18);
        usdc = new MockToken("USDC", 6);
        nav.registerAsset(address(wbtc), 8, "WBTC");
        nav.registerAsset(address(weth), 18, "WETH");
        nav.registerAsset(address(usdc), 6, "USDC");

        // Factory + per-(token0,token1,fee) pool contracts; positionId resolves to the pool address via getPool.
        factory = new MockUniswapV3Factory();
        poolA = new MockUniswapV3Pool(address(wbtc), address(weth), 3000, 60);
        poolB = new MockUniswapV3Pool(address(usdc), address(weth), 500, 10);
        factory.setPool(address(wbtc), address(weth), 3000, address(poolA));
        factory.setPool(address(usdc), address(weth), 500, address(poolB));
        npm.setFactory(address(factory)); // must precede adapter construction (read in the constructor)

        // ADR 0017: the adapter splits the principal at the pool's live `slot0` (it reads slot0 directly, NOT the
        // oracle). Put each pool in range at sqrtPrice == 2^96 (raw token1/token0 price 1.0, tick 0), keeping the
        // [-100, 100] NFT positions in range so both legs are non-zero.
        poolA.setSlot0(uint160(1 << 96), 0);
        poolB.setSlot0(uint160(1 << 96), 0);

        // NAV still needs the assets registered + priced (it, not the adapter, does the pricing/staleness). The USD
        // figures are deliberately nonsensical — this suite asserts leg structure/amounts, not values.
        nav.setAssetPrice(address(wbtc), 1e8, 8);
        nav.setAssetPrice(address(weth), 1e18, 8);
        nav.setAssetPrice(address(usdc), 1e6, 8);

        // In-range NFT for alice in two pools + settled fees (tokensOwed) for deterministic Fees legs.
        _mint(1, address(wbtc), address(weth), 3000, 1_000_000, 42, 1337);
        _mint(2, address(usdc), address(weth), 500, 2_000_000, 7, 99);

        // admin + assistant = this test, so it can submit/clear tokenIds.
        adapter =
            new UniswapV3PoolsBalanceAdapter(address(npm), "Uniswap V3", address(nav), address(this), address(this));
        adapter.submitTokenIds(alice, _ids(1, 2));
    }

    function _mint(uint256 id, address t0, address t1, uint24 fee, uint128 liq, uint128 owed0, uint128 owed1) internal {
        npm.mint(
            alice,
            id,
            MockPositionManager.PositionData({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: -100,
                tickUpper: 100,
                liquidity: liq,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: owed0,
                tokensOwed1: owed1
            })
        );
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _id(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    /// @notice Sum of legs for a given token across all of alice's reported positions.
    function _token(address token) internal view returns (uint256 sum) {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == token) sum += p[i].amount;
        }
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_roles_grantedToConstructorArgs() public view {
        assertTrue(adapter.hasRole(ASSISTANT_ROLE, address(this)));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adapter.hasRole(ASSISTANT_ROLE, other));
    }

    function test_noArgMethods_returnEmpty() public view {
        assertEq(adapter.underlyingAssetsSupported().length, 0);
        (address[] memory a,,) = adapter.getAdapterBalances(alice);
        assertEq(a.length, 0);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(alice, address(wbtc));
        assertEq(amt, 0);
        assertFalse(d);
    }

    function test_token_nonZero() public view {
        assertGt(_token(address(wbtc)), 0);
        assertGt(_token(address(usdc)), 0);
        assertGt(_token(address(weth)), 0);
    }

    function test_positions_legsAndIdentity() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        // NFT 1: WBTC supply, WETH supply, WBTC fees, WETH fees (4) + NFT 2: USDC/WETH supply + fees (4)
        assertEq(p.length, 8, "4 legs per NFT");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAdapter, address(adapter));
            assertFalse(p[i].isDebt);
        }
        // NFT 1 legs carry positionId = the pool address (WBTC/WETH 0.3%)
        assertEq(p[0].positionId, abi.encode(address(poolA)));
        // NFT 2 legs carry positionId = the pool address (USDC/WETH 0.05%)
        assertEq(p[4].positionId, abi.encode(address(poolB)));
        // Labels carry the pool address and the NFT id last: ["Liquidity Pool", "<pool>", "NFT #<id>"].
        assertEq(p[0].labels.length, 3);
        assertEq(p[0].labels[0], "Liquidity Pool");
        assertEq(p[0].labels[1], Strings.toHexString(address(poolA)));
        assertEq(p[0].labels[2], "NFT #1");
        assertEq(p[4].labels[2], "NFT #2");
    }

    /// @notice Emission order per NFT: Supplied liq0, Supplied liq1, Fees fee0, Fees fee1. With the mock's
    ///         feeGrowthGlobal == 0 and the position's feeGrowthInsideLast == 0, the accruing-since-poke component is
    ///         zero, so the full uncollected fee collapses to `tokensOwed` (42/1337) — the accruing component is
    ///         exercised separately in test_fees_fullUncollected_feeGrowthPlusTokensOwed.
    function test_feesLegType() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Supplied));
        // The 3rd/4th NFT-1 legs are Fees (tokensOwed 42/1337; feeGrowth == 0 so full fee == tokensOwed).
        assertEq(p[2].amount, 42);
        assertEq(uint8(p[2].positionKind), uint8(PositionKind.Fees));
        assertEq(p[3].amount, 1337);
        assertEq(uint8(p[3].positionKind), uint8(PositionKind.Fees));
    }

    /// @notice ADR 0017 reverses audit M-A1: fee legs now report the FULL uncollected fee — the
    ///         `feeGrowthInside`-since-poke accruing component PLUS the settled `tokensOwed` — valued at the pool's
    ///         real `slot0` tick, not `tokensOwed` alone. Set a non-zero pool `feeGrowthGlobal` and a smaller
    ///         per-position `feeGrowthInsideLast` so `feeGrowthGlobal − feeGrowthInsideLast > 0`, and assert the
    ///         reported Fees leg = mulDiv(delta, liquidity, 2^128) + tokensOwed (strictly greater than tokensOwed).
    function test_fees_fullUncollected_feeGrowthPlusTokensOwed() public {
        adapter.clearAccount(alice); // start from a clean cache (setUp seeded ids 1,2)

        uint256 liq = 1_000_000;
        uint128 owed0 = 42;
        uint128 owed1 = 1337;
        // Accruing-since-poke fee growth: global − inside-last. Pick deltas that, scaled by liquidity, are exact and
        // non-trivial: delta0 = 1·Q128 → accrued0 = liq; delta1 = 3·Q128 → accrued1 = 3·liq.
        uint256 fgInside0Last = 5 * FixedPoint128.Q128;
        uint256 fgInside1Last = 2 * FixedPoint128.Q128;
        uint256 fgGlobal0 = fgInside0Last + 1 * FixedPoint128.Q128; // delta 1·Q128
        uint256 fgGlobal1 = fgInside1Last + 3 * FixedPoint128.Q128; // delta 3·Q128

        // Mint NFT 10 (WBTC/WETH 0.3% → poolA) with the per-position feeGrowthInsideLast set, then advance the pool's
        // global fee growth above it. tickCurrent 0 ∈ [-100, 100] and the mock's ticks() return zero outside-growth,
        // so feeGrowthInside == feeGrowthGlobal and the accruing component is exactly mulDiv(global - last, liq, Q128).
        npm.mint(
            alice,
            10,
            MockPositionManager.PositionData({
                token0: address(wbtc),
                token1: address(weth),
                fee: 3000,
                tickLower: -100,
                tickUpper: 100,
                liquidity: uint128(liq),
                feeGrowthInside0LastX128: fgInside0Last,
                feeGrowthInside1LastX128: fgInside1Last,
                tokensOwed0: owed0,
                tokensOwed1: owed1
            })
        );
        poolA.setFeeGrowthGlobal(fgGlobal0, fgGlobal1);
        adapter.submitTokenIds(alice, _id(10));

        uint256 expected0 = Math.mulDiv(fgGlobal0 - fgInside0Last, liq, FixedPoint128.Q128) + owed0;
        uint256 expected1 = Math.mulDiv(fgGlobal1 - fgInside1Last, liq, FixedPoint128.Q128) + owed1;

        uint256 wbtcFee;
        uint256 wethFee;
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind != PositionKind.Fees) continue;
            if (p[i].balanceAsset.asset == address(wbtc)) wbtcFee = p[i].amount;
            if (p[i].balanceAsset.asset == address(weth)) wethFee = p[i].amount;
        }
        assertEq(wbtcFee, expected0, "WBTC fee = feeGrowth-since-poke + tokensOwed0");
        assertEq(wethFee, expected1, "WETH fee = feeGrowth-since-poke + tokensOwed1");
        // The accruing component is genuinely included — strictly greater than the settled tokensOwed alone.
        assertGt(wbtcFee, owed0, "full fee strictly exceeds tokensOwed0");
        assertGt(wethFee, owed1, "full fee strictly exceeds tokensOwed1");
        assertEq(wbtcFee, liq + owed0, "WBTC accrued == 1*liq + owed0");
        assertEq(wethFee, 3 * liq + owed1, "WETH accrued == 3*liq + owed1");
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(wbtc));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(wbtc));
        }
    }

    /// @notice Both pool tokens must be registered for NAV to price the legs. If either is unregistered the whole NFT
    ///         contributes no legs (not just the unregistered token's leg) — the adapter requires reg0 && reg1.
    function test_unregisteredToken_dropsPosition() public {
        nav.unregisterAssetHelper(address(weth)); // NFT 1 is WBTC/WETH → WETH unregistered
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        // NFT 1 fully dropped; NFT 2 (USDC/WETH) also drops because WETH is its token1 → no legs at all.
        assertEq(p.length, 0, "unregistering WETH drops both NFTs (both pair WETH)");
    }

    function test_emptyCache_returnsEmpty() public view {
        assertEq(adapter.getAdapterPositions(other, address(0)).length, 0);
    }

    //
    // Assisted-cache behaviour
    //

    function test_submit_onlyAssistantRole() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, ASSISTANT_ROLE)
        );
        adapter.submitTokenIds(alice, _id(1));
    }

    function test_clear_onlyAssistantRole() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, ASSISTANT_ROLE)
        );
        adapter.clearTokenId(alice, 1);
    }

    /// @notice Writes are fail-loud: submitting an id not owned by the account reverts NotTokenOwner.
    function test_submit_revertsOnNonOwnedId() public {
        // NFT 3 is owned by `other`, not alice.
        npm.mint(
            other, 3, MockPositionManager.PositionData(address(wbtc), address(weth), 3000, -100, 100, 1, 0, 0, 0, 0)
        );
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, alice, uint256(3)));
        adapter.submitTokenIds(alice, _id(3));
    }

    /// @notice Writes revert for a non-existent id too (ownerOf reverts → surfaced as NotTokenOwner).
    function test_submit_revertsOnNonexistentId() public {
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, alice, uint256(999)));
        adapter.submitTokenIds(alice, _id(999));
    }

    /// @notice Reads are fail-open: an id transferred away after submission is silently discarded, the rest survive.
    function test_read_discardsTransferredId() public {
        npm.setOwner(1, other); // alice's NFT 1 moves to `other`
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        // NFT 1's 4 legs gone; NFT 2's 4 legs remain.
        assertEq(p.length, 4, "transferred NFT discarded; remaining NFT still reported");
        assertEq(p[0].positionId, abi.encode(address(poolB)));
        assertEq(p[0].labels[2], "NFT #2");
    }

    /// @notice Reads are fail-open: a burned id (ownerOf reverts) is silently discarded.
    function test_read_discardsBurnedId() public {
        npm.burn(2);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertEq(p.length, 4, "burned NFT discarded; remaining NFT still reported");
        assertEq(p[0].positionId, abi.encode(address(poolA)));
        assertEq(p[0].labels[2], "NFT #1");
    }

    function test_submit_dedups() public {
        adapter.submitTokenIds(alice, _ids(1, 2)); // already cached
        assertEq(adapter.tokenIdsOf(alice).length, 2);
    }

    function test_clearTokenId() public {
        adapter.clearTokenId(alice, 1);
        assertEq(adapter.tokenIdsOf(alice).length, 1);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertEq(p.length, 4, "only NFT 2 remains");
    }

    function test_clearAccount() public {
        adapter.clearAccount(alice);
        assertEq(adapter.tokenIdsOf(alice).length, 0);
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, 0);
    }

    /// @notice ADR 0017: the split no longer reads prices — the adapter reports instantaneous on-chain amounts and
    ///         NAVCalculator (not the adapter) handles pricing/staleness. So making a token's price feed revert does
    ///         NOT drop the position from the adapter's output; the legs are still emitted (NAV deals with the price
    ///         failure downstream). Per-NFT isolation against burned/transferred ids is covered by the read tests.
    function test_priceFeedRemoved_positionStillReported() public {
        // WBTC pairs only in NFT 1 (poolA); make its feed read revert like the real NAVCalculator's PriceFeedNotSet.
        nav.setPriceReverts(address(wbtc), true);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        // Both NFTs still reported (8 legs) — the adapter does not consult getPriceData.
        assertEq(p.length, 8, "price-feed failure does not drop positions from the adapter");

        // NFT 1's WBTC leg (the asset whose feed reverts) is still present.
        bool sawWbtc;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].balanceAsset.asset == address(wbtc)) sawWbtc = true;
        }
        assertTrue(sawWbtc, "WBTC legs still emitted despite the reverting feed");
    }

    /// @notice Per-NFT fail-open isolation: each cached NFT is valued behind a `this.positionLegs(...)` external call
    ///         wrapped in try/catch, so a revert in ONE NFT's live reads (slot0/positions/ticks/feeGrowth) drops only
    ///         that id — the rest of the account's V3 set still reports. Make poolA's `slot0()` revert and assert the
    ///         read does not revert, returns ONLY poolB's 4 legs (all carrying poolB's positionId), and poolA's NFT is
    ///         silently dropped. (Before slot0 became a per-NFT live read this isolation was covered by the old
    ///         price-feed-revert test; it now lives here.)
    function test_revertingPool_isolatedFromRest() public {
        // alice has NFT 1 (poolA) + NFT 2 (poolB) from setUp. Make poolA's slot0 read revert.
        poolA.setSlot0Reverts(true);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        // poolA's NFT is dropped; only poolB's 4 legs survive.
        assertEq(p.length, 4, "reverting pool's NFT dropped; the rest of the V3 set survives");
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, abi.encode(address(poolB)), "only poolB legs remain");
        }
        assertEq(p[0].labels[2], "NFT #2", "surviving legs are NFT #2 (poolB)");
    }

    /// @notice Writes are fail-loud at the cap: an owned id past MAX_TOKEN_IDS reverts TokenIdCacheFull rather than
    ///         being silently dropped (which would silently under-count the account's NAV).
    function test_perAccountCap_revertsWhenFull() public {
        adapter.clearAccount(alice); // start empty (setUp seeded ids 1,2)
        uint256 cap = adapter.MAX_TOKEN_IDS();

        // Fill the cache to exactly MAX_TOKEN_IDS with owned NFTs (all in poolA's pair; ownerOf == alice is all the
        // cap path needs). ids 1,2 were minted in setUp, so reuse them and mint the rest.
        uint256[] memory ids = new uint256[](cap);
        for (uint256 i = 0; i < cap; i++) {
            uint256 id = i + 1;
            if (id > 2) _mint(id, address(wbtc), address(weth), 3000, 1_000_000, 0, 0);
            ids[i] = id;
        }
        adapter.submitTokenIds(alice, ids);
        assertEq(adapter.tokenIdsOf(alice).length, cap);

        // One more owned id past the cap is fail-loud.
        uint256 overflowId = cap + 1;
        _mint(overflowId, address(wbtc), address(weth), 3000, 1_000_000, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(TokenIdCacheFull.selector, alice, cap));
        adapter.submitTokenIds(alice, _id(overflowId));

        // Re-submitting an already-cached id while full is still an idempotent no-op (dedup precedes the cap check).
        adapter.submitTokenIds(alice, _id(1));
        assertEq(adapter.tokenIdsOf(alice).length, cap);
    }
}
