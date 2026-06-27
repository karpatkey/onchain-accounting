// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    UniswapV3PoolsBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/UniswapV3PoolsBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NotTokenOwner} from "src/errors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockPositionManager, MockToken} from "test/balances/AssistedBalanceAdapters/UniswapV3Mocks.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title UniswapV3PoolsBalanceAdapter unit tests (no fork)
/// @notice Assisted (agent-fed) tokenId cache + per-NFT decomposition for UniswapV3Pools. The adapter never reads
///         the pool — it reads `positions(tokenId)` and reconstructs the price from the registered oracles — so
///         these tests drive it entirely through the NPM mock + the submitted tokenId cache.
contract UniswapV3PoolsBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    UniswapV3PoolsBalanceAdapter adapter;

    MockToken wbtc; // NFT 1 token0
    MockToken weth; // shared token1
    MockToken usdc; // NFT 2 token0

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

        // [2] The adapter reconstructs sqrtPriceX96 from these oracle prices (it never reads slot0). They are chosen
        // so the reconstructed raw token1/token0 price is 1.0 (sqrtPrice == 2^96, tick 0), keeping the [-100, 100]
        // NFT positions in range. Deliberately nonsensical as USD figures (this suite asserts leg structure/amounts,
        // not values): WBTC(8)/WETH(18) → (1e8·10^10)/1e18 = 1; USDC(6)/WETH(18) → (1e6·10^12)/1e18 = 1.
        nav.setAssetPrice(address(wbtc), 1e8, 8);
        nav.setAssetPrice(address(weth), 1e18, 8);
        nav.setAssetPrice(address(usdc), 1e6, 8);

        // In-range NFT for alice in two pools + settled fees (tokensOwed) for deterministic Fees legs.
        _mint(1, address(wbtc), address(weth), 3000, 1_000_000, 42, 1337);
        _mint(2, address(usdc), address(weth), 500, 2_000_000, 7, 99);

        // admin + assistant = this test, so it can submit/clear tokenIds.
        adapter = new UniswapV3PoolsBalanceAdapter(address(npm), "Uniswap V3", address(nav), address(this), address(this));
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
        // NFT 1 legs carry positionId = abi.encode(npm, tokenId=1)
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(1)));
        // NFT 2 legs carry positionId = abi.encode(npm, tokenId=2)
        assertEq(p[4].positionId, abi.encode(address(npm), uint256(2)));
    }

    function test_feesLegType() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        // The 3rd/4th NFT-1 legs are Fees (tokensOwed 42/1337).
        assertEq(p[2].amount, 42);
        assertEq(uint8(p[2].positionKind), uint8(PositionKind.Fees));
        assertEq(p[3].amount, 1337);
        assertEq(uint8(p[3].positionKind), uint8(PositionKind.Fees));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
    }

    /// @notice Audit M-A1: fee legs report ONLY the position's settled `tokensOwed`. The adapter never reads the
    ///         pool's tick fee-growth, so the uncollected-since-poke component is structurally absent. WBTC fee is
    ///         unique to NFT 1 (tokensOwed0=42); USDC fee is unique to NFT 2 (tokensOwed0=7).
    function test_M_A1_fees_areSettledTokensOwedOnly() public view {
        uint256 wbtcFee;
        uint256 usdcFee;
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i].positionKind != PositionKind.Fees) continue;
            if (p[i].balanceAsset.asset == address(wbtc)) wbtcFee = p[i].amount;
            if (p[i].balanceAsset.asset == address(usdc)) usdcFee = p[i].amount;
        }
        assertEq(wbtcFee, 42, "WBTC fee leg == tokensOwed0 only");
        assertEq(usdcFee, 7, "USDC fee leg == tokensOwed0 only");
    }

    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(wbtc));
        assertGt(p.length, 0);
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, address(wbtc));
        }
    }

    /// @notice [2] Valuing the LP split needs BOTH tokens' oracle prices. If either token is unregistered the price
    ///         cannot be reconstructed, so that NFT contributes no legs (not just the unregistered token's leg).
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
        npm.mint(other, 3, MockPositionManager.PositionData(address(wbtc), address(weth), 3000, -100, 100, 1, 0, 0, 0, 0));
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
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(2)));
    }

    /// @notice Reads are fail-open: a burned id (ownerOf reverts) is silently discarded.
    function test_read_discardsBurnedId() public {
        npm.burn(2);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(alice, address(0));
        assertEq(p.length, 4, "burned NFT discarded; remaining NFT still reported");
        assertEq(p[0].positionId, abi.encode(address(npm), uint256(1)));
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
}
