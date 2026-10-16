// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    UniswapV4SicklePoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/UniswapV4SicklePoolsMetaBalanceAdapter.sol";
import {V4PositionIndex} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4PositionIndex.sol";
import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {LiquidityAmounts} from "src/balances/MetaBalanceAdapters/uniswap/lib/LiquidityAmounts.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";

import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {NotAContract} from "src/errors.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {MockToken} from "test/balances/MetaBalanceAdapters/uniswap/UniswapV3Mocks.sol";
import {
    MockSickle,
    MockSickleFactory,
    MockV4PoolManager,
    MockV4PositionManager
} from "test/balances/MetaBalanceAdapters/uniswap/v4/UniswapV4Mocks.sol";

/// @title UniswapV4SicklePoolsMetaBalanceAdapter unit tests (no fork)
/// @notice Covers what the fork suite cannot reach deterministically: the exact `positionId` bytes and identity
///         fields, the index being a hint that stale and poisoned entries fall out of, the native-currency mapping,
///         `assetFilter`, the both-currencies-registered gate, and `coverage`. Valuation shape (in-range split +
///         full unclaimed fees) is asserted against the same Uniswap math the adapter links; the INDEPENDENT
///         recompute lives in the fork suite, against real chain state.
contract UniswapV4SicklePoolsMetaBalanceAdapterTest is Test {
    address internal constant ERC7528_NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    Mock_NAVCalculator internal nav;
    MockV4PositionManager internal posm;
    MockV4PoolManager internal poolManager;
    MockSickleFactory internal factory;
    V4PositionIndex internal index;
    UniswapV4SicklePoolsMetaBalanceAdapter internal meta;

    MockToken internal usdg;
    MockToken internal metaToken;
    MockToken internal unregistered;

    address internal safe = makeAddr("safe");
    address internal stranger = makeAddr("stranger");
    address internal sickle;

    PoolKey internal keyA; // USDG/META 0.3% — the ordinary two-ERC20 pool
    PoolKey internal keyB; // native ETH/USDG — currency0 is address(0)
    PoolKey internal keyC; // USDG/<unregistered> — the registry-gate pool
    bytes32 internal poolA;
    bytes32 internal poolB;
    bytes32 internal poolC;

    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    uint128 internal constant LIQ_A = 1e12;
    uint128 internal constant LIQ_B = 2e12;
    uint128 internal constant LIQ_C = 3e12;
    /// @dev Q128/1000 of fee growth over L of liquidity is exactly L/1000 raw tokens, which keeps the expectations
    ///      readable without weakening them: they are still computed, never typed in.
    uint256 internal constant FEE_GROWTH = FixedPoint128.Q128 / 1000;

    uint256 internal constant ID_SAFE_A = 11; // held by the Safe itself, pool A
    uint256 internal constant ID_SICKLE_A = 12; // held by the Sickle, pool A
    uint256 internal constant ID_SICKLE_B = 13; // held by the Sickle, native pool B
    uint256 internal constant ID_SICKLE_C = 14; // held by the Sickle, unregistered-currency pool C
    uint256 internal constant ID_STALE = 15; // filed under the Sickle, then transferred away
    uint256 internal constant ID_BURNED = 16; // filed under the Sickle, then burned

    function setUp() public {
        nav = new Mock_NAVCalculator();
        posm = new MockV4PositionManager();
        poolManager = new MockV4PoolManager();
        factory = new MockSickleFactory();
        index = new V4PositionIndex(address(posm));

        sickle = address(new MockSickle(safe));
        factory.setSickle(safe, sickle);

        usdg = new MockToken("USDG", 6);
        metaToken = new MockToken("META", 18);
        unregistered = new MockToken("NOPE", 18);
        nav.registerAsset(address(usdg), 6, "USDG");
        nav.registerAsset(address(metaToken), 18, "META");
        nav.registerAsset(ERC7528_NATIVE, 18, "ETH");

        keyA = PoolKey(address(usdg), address(metaToken), 3000, 60, address(0));
        keyB = PoolKey(address(0), address(usdg), 3000, 60, address(0));
        keyC = PoolKey(address(usdg), address(unregistered), 500, 10, address(0));
        poolA = keccak256(abi.encode(keyA));
        poolB = keccak256(abi.encode(keyB));
        poolC = keccak256(abi.encode(keyC));

        meta = new UniswapV4SicklePoolsMetaBalanceAdapter(
            address(posm), address(poolManager), address(index), address(nav), address(factory)
        );

        _mintAndSeed(safe, ID_SAFE_A, keyA, poolA, LIQ_A);
        _mintAndSeed(sickle, ID_SICKLE_A, keyA, poolA, LIQ_A);
        _mintAndSeed(sickle, ID_SICKLE_B, keyB, poolB, LIQ_B);
        _mintAndSeed(sickle, ID_SICKLE_C, keyC, poolC, LIQ_C);
        _mintAndSeed(sickle, ID_STALE, keyA, poolA, LIQ_A);
        _mintAndSeed(sickle, ID_BURNED, keyA, poolA, LIQ_A);

        uint256[] memory all = new uint256[](6);
        all[0] = ID_SAFE_A;
        all[1] = ID_SICKLE_A;
        all[2] = ID_SICKLE_B;
        all[3] = ID_SICKLE_C;
        all[4] = ID_STALE;
        all[5] = ID_BURNED;
        index.index(all);

        // Now make two of the Sickle's filed entries dead, exactly as a vfat rebalance does.
        posm.transfer(sickle, stranger, ID_STALE);
        posm.burn(ID_BURNED);
    }

    /// @dev Mints one position and seeds the PoolManager words the adapter will read for it.
    function _mintAndSeed(address holder, uint256 tokenId, PoolKey memory key, bytes32 poolId, uint128 liq) internal {
        posm.mint(holder, tokenId, key, TICK_LOWER, TICK_UPPER, liq);
        // Current tick 0 sits inside [-60, 60], so both principal legs are non-zero.
        poolManager.setPool(poolId, TickMath.getSqrtRatioAtTick(0), 0, FEE_GROWTH, FEE_GROWTH);
        poolManager.setTick(poolId, TICK_LOWER, 0, 0);
        poolManager.setTick(poolId, TICK_UPPER, 0, 0);
        poolManager.setPosition(poolId, address(posm), TICK_LOWER, TICK_UPPER, bytes32(tokenId), liq, 0, 0);
    }

    function _one(bytes32 instance) internal pure returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = instance;
    }

    function _positions(address account, bytes32 instance, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return meta.getAdapterPositionsForInstances(account, _one(instance), assetFilter);
    }

    function _expected(uint128 liq) internal pure returns (uint256 amount0, uint256 amount1, uint256 fee) {
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(0),
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            liq
        );
        fee = Math.mulDiv(FEE_GROWTH, liq, FixedPoint128.Q128);
    }

    //
    // Identity
    //

    function test_supportsInterface() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionEnumerable).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
        assertFalse(meta.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// @notice positionId is the RAW pool id, not an address encoding — the override the base's default would break.
    function test_identityAndExactPositionIdBytes() public view {
        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        assertGt(p.length, 0, "the Safe and its Sickle both hold pool-A positions");
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionId, abi.encode(poolA), "positionId == abi.encode(bytes32 poolId)");
            assertEq(p[i].positionId.length, 32, "exactly one word");
            assertEq(p[i].protocolBrand, ProtocolIds.UNISWAP);
            assertEq(p[i].protocolId, ProtocolIds.UNISWAP_V4);
            assertEq(p[i].protocolSubId, ProtocolIds.UNISWAP_V4);
            assertEq(p[i].balanceAdapter, address(meta));
            assertFalse(p[i].isDebt);
            assertFalse(p[i].isLocked, "LP principal and unclaimed fees are always withdrawable");
            assertTrue(p[i].positionInstanceId != bytes32(0), "the NFT id rides in positionInstanceId");
        }
    }

    function test_protocolNameIsDerived() public view {
        assertEq(meta.protocolName(), "Uniswap V4");
    }

    /// @notice {IPositionEnumerable} requires byte-identity between the enumeration and what is emitted.
    function test_positionIdsAreByteIdenticalToEmitted() public {
        bytes32[] memory ins = new bytes32[](2);
        ins[0] = poolA;
        ins[1] = poolB;
        nav.setMetaInstances(address(meta), ins);

        bytes[] memory ids = meta.positionIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], abi.encode(poolA));
        assertEq(ids[1], abi.encode(poolB));

        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositions(safe, address(0));
        assertGt(p.length, 0);
        for (uint256 i; i < p.length; ++i) {
            bool matched =
                keccak256(p[i].positionId) == keccak256(ids[0]) || keccak256(p[i].positionId) == keccak256(ids[1]);
            assertTrue(matched, "every emitted positionId appears in positionIds()");
        }
    }

    //
    // The index is a hint
    //

    /// @notice A filed id whose owner moved on contributes nothing — the entry is still filed, and still skipped.
    function test_staleIndexEntryIsSkipped() public view {
        assertTrue(index.isIndexed(sickle, ID_STALE), "the dead entry is still on file");
        assertEq(posm.ownerOf(ID_STALE), stranger);

        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        for (uint256 i; i < p.length; ++i) {
            assertTrue(p[i].positionInstanceId != bytes32(ID_STALE), "a transferred position is not valued");
        }
    }

    /// @notice A burned id (the residue of every rebalance) makes `ownerOf` revert, which must be absorbed.
    function test_burnedIndexEntryIsSkipped() public view {
        assertTrue(index.isIndexed(sickle, ID_BURNED));
        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        for (uint256 i; i < p.length; ++i) {
            assertTrue(p[i].positionInstanceId != bytes32(ID_BURNED), "a burned position is not valued");
        }
    }

    /// @notice A stranger filing a genuine position of their own against the index cannot make it the Safe's.
    function test_poisonedIndexEntryCannotBeAttributed() public {
        uint256[] memory one = new uint256[](1);
        one[0] = ID_STALE; // now the stranger's
        vm.prank(stranger);
        index.index(one);

        assertTrue(index.isIndexed(stranger, ID_STALE), "filed under its real owner, never the caller's choice");
        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        for (uint256 i; i < p.length; ++i) {
            assertTrue(p[i].positionInstanceId != bytes32(ID_STALE));
        }
    }

    /// @notice A live position in a DIFFERENT pool is skipped for this instance: the pool id is re-derived from the
    ///         position's own PoolKey, never taken from the index.
    function test_positionInAnotherPoolIsNotValuedHere() public view {
        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        for (uint256 i; i < p.length; ++i) {
            assertTrue(p[i].positionInstanceId != bytes32(ID_SICKLE_B), "pool B's position is not pool A's");
        }
    }

    //
    // Holders
    //

    /// @notice Both the account and its Sickle are reported, and a Sickle asked about directly is its own holder.
    function test_bothHoldersAreReported() public view {
        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        bool sawSafe;
        bool sawSickle;
        for (uint256 i; i < p.length; ++i) {
            if (p[i].positionInstanceId == bytes32(ID_SAFE_A)) sawSafe = true;
            if (p[i].positionInstanceId == bytes32(ID_SICKLE_A)) sawSickle = true;
        }
        assertTrue(sawSafe, "the account's own position");
        assertTrue(sawSickle, "the position held through its Sickle");

        INAVCalculator.PositionBalance[] memory direct = _positions(sickle, poolA, address(0));
        for (uint256 i; i < direct.length; ++i) {
            assertTrue(direct[i].positionInstanceId != bytes32(ID_SAFE_A), "a Sickle has no Sickle of its own");
        }
    }

    //
    // Valuation
    //

    function test_principalAndFeeLegs() public view {
        (uint256 e0, uint256 e1, uint256 eFee) = _expected(LIQ_A);
        assertGt(e0, 0);
        assertGt(e1, 0);
        assertGt(eFee, 0);

        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        // Two live pool-A positions (the Safe's and the Sickle's), four legs each.
        assertEq(p.length, 8, "2 live positions x (2 principal + 2 fee) legs");

        uint256 sup0;
        uint256 sup1;
        uint256 fee0;
        uint256 fee1;
        for (uint256 i; i < p.length; ++i) {
            bool isFee = p[i].positionKind == PositionKind.Fees;
            if (p[i].balanceAsset.asset == address(usdg)) {
                if (isFee) fee0 += p[i].amount;
                else sup0 += p[i].amount;
            } else if (p[i].balanceAsset.asset == address(metaToken)) {
                if (isFee) fee1 += p[i].amount;
                else sup1 += p[i].amount;
            } else {
                revert("unexpected asset");
            }
        }
        assertEq(sup0, 2 * e0, "currency0 principal, both positions");
        assertEq(sup1, 2 * e1, "currency1 principal, both positions");
        assertEq(fee0, 2 * eFee, "currency0 fees are feeGrowthInside-derived, not tokensOwed");
        assertEq(fee1, 2 * eFee, "currency1 fees are feeGrowthInside-derived, not tokensOwed");
    }

    /// @notice Registry metadata is carried through from the NAV, not re-read from the token.
    function test_assetMetadataComesFromTheRegistry() public view {
        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolA, address(0));
        for (uint256 i; i < p.length; ++i) {
            if (p[i].balanceAsset.asset == address(usdg)) {
                assertEq(p[i].balanceAsset.symbol, "USDG");
                assertEq(p[i].balanceAsset.decimals, 6);
            }
        }
    }

    //
    // Native ether
    //

    /// @notice A V4 `Currency` of `address(0)` must reach the NAV as its native sentinel, never as the raw zero: the
    ///         raw zero cannot be registered, and `PriceFeedLib` drops an unpriceable leg silently.
    function test_nativeCurrencyIsMappedToTheSentinel() public view {
        assertEq(meta.NATIVE_ADDRESS(), ERC7528_NATIVE, "the ERC-7528 literal the NAV itself registers");

        INAVCalculator.PositionBalance[] memory p = _positions(safe, poolB, address(0));
        assertEq(p.length, 4, "one native position, 4 legs");
        bool sawNative;
        for (uint256 i; i < p.length; ++i) {
            assertTrue(p[i].balanceAsset.asset != address(0), "the raw zero address would be dropped unpriced");
            if (p[i].balanceAsset.asset == meta.NATIVE_ADDRESS()) {
                sawNative = true;
                // Reaching a REGISTERED asset is the point: symbol and decimals come from the NAV's native record,
                // which is the only place they exist for a code-less sentinel.
                (, bool registered) = nav.getRegisteredAsset(p[i].balanceAsset.asset);
                assertTrue(registered, "the emitted sentinel is an asset the NAV can price");
                assertEq(p[i].balanceAsset.symbol, "ETH");
                assertEq(p[i].balanceAsset.decimals, 18);
            }
        }
        assertTrue(sawNative, "currency0 == address(0) is emitted as the sentinel");
    }

    //
    // Gates
    //

    /// @notice `assetFilter` gates which legs are emitted, not whether the position is valued.
    function test_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory only0 = _positions(safe, poolA, address(usdg));
        assertEq(only0.length, 4, "2 positions x (principal + fees) for currency0 only");
        for (uint256 i; i < only0.length; ++i) {
            assertEq(only0[i].balanceAsset.asset, address(usdg));
        }

        INAVCalculator.PositionBalance[] memory none = _positions(safe, poolA, address(unregistered));
        assertEq(none.length, 0, "a filter matching neither currency yields nothing");
    }

    /// @notice Both currencies registered or the position is dropped whole: a half-priced LP understates the NAV.
    function test_unregisteredCurrencyDropsThePosition() public view {
        assertEq(_positions(safe, poolC, address(0)).length, 0, "currency1 is not registered");
        // The filter cannot rescue it either: the gate is the registry, not the filter.
        assertEq(_positions(safe, poolC, address(usdg)).length, 0);
    }

    function test_unconfiguredInstanceIsEmpty() public view {
        assertEq(_positions(safe, keccak256("no such pool"), address(0)).length, 0);
    }

    function test_accountWithNothingIsEmpty() public {
        assertEq(_positions(makeAddr("nobody"), poolA, address(0)).length, 0);
    }

    //
    // Coverage
    //

    function test_coverage() public {
        // The Sickle holds 4 (A, B, C and the burned one is gone, the stale one moved away): 6 minted, 1 to the
        // Safe, 1 transferred out, 1 burned.
        (uint256 live, uint256 held) = meta.coverage(sickle);
        assertEq(held, 3, "balanceOf counts only what it still holds");
        assertEq(live, 3, "and all three are filed");

        // Mint a fourth and do NOT index it: that is exactly the gap `coverage` exists to expose.
        _mintAndSeed(sickle, 99, keyA, poolA, LIQ_A);
        (live, held) = meta.coverage(sickle);
        assertEq(held, 4);
        assertEq(live, 3, "indexedLive < heldTotal means the index is behind");
    }

    //
    // Instance assets and labels
    //

    function test_instanceAssetsNeedAPoolKeyPreimage() public {
        bytes32[] memory ins = _one(poolB);
        assertEq(meta.underlyingAssetsSupportedForInstances(ins).length, 0, "no preimage submitted yet");

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = keyB;
        meta.registerPoolKeys(keys);

        address[] memory assets = meta.underlyingAssetsSupportedForInstances(ins);
        assertEq(assets.length, 2);
        assertEq(assets[0], ERC7528_NATIVE, "currency0 is normalised on the way in");
        assertEq(assets[1], address(usdg));

        (address c0, address c1) = meta.poolCurrencies(poolB);
        assertEq(c0, ERC7528_NATIVE);
        assertEq(c1, address(usdg));
    }

    /// @notice A key is only ever accepted under the pool id it hashes to, so there is nothing to gate.
    function test_registerPoolKeysIsSelfValidating() public {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = PoolKey(address(usdg), address(metaToken), 1234, 7, address(0)); // a key nobody governs
        vm.prank(stranger);
        meta.registerPoolKeys(keys);

        (address c0,) = meta.poolCurrencies(poolA);
        assertEq(c0, address(0), "pool A is untouched: the forged key filed itself under its OWN id");
        (c0,) = meta.poolCurrencies(keccak256(abi.encode(keys[0])));
        assertEq(c0, address(usdg));
    }

    function test_learnPoolKeysFromLivePositions() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = ID_SICKLE_A;
        meta.learnPoolKeys(ids);
        (address c0, address c1) = meta.poolCurrencies(poolA);
        assertEq(c0, address(usdg));
        assertEq(c1, address(metaToken));
    }

    function test_learnPoolKeysRevertsOnAnUnknownPosition() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 777; // never minted: the mock returns a zeroed key
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4SicklePoolsMetaBalanceAdapter.UnknownPosition.selector, uint256(777))
        );
        meta.learnPoolKeys(ids);
    }

    function test_positionLabels() public {
        // No preimage yet: the leaf collapses and only the category survives.
        string[] memory one = meta.positionLabels(abi.encode(poolA));
        assertEq(one.length, 1);
        assertEq(one[0], "AMM Liquidity Pool");

        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = keyA;
        keys[1] = keyB;
        meta.registerPoolKeys(keys);

        string[] memory two = meta.positionLabels(abi.encode(poolA));
        assertEq(two.length, 2);
        assertEq(two[0], "AMM Liquidity Pool");
        assertEq(two[1], "USDG/META");

        // The native leg reads its symbol off the NAV record, which is the only place it exists.
        string[] memory native = meta.positionLabels(abi.encode(poolB));
        assertEq(native[1], "ETH/USDG");
    }

    function test_positionLabelsRejectsAMalformedPositionId() public view {
        assertEq(meta.positionLabels(hex"").length, 0);
        assertEq(meta.positionLabels(abi.encodePacked(poolA, poolA)).length, 0, "two words is not this schema");
        assertEq(meta.positionLabels(hex"1234").length, 0);
    }

    //
    // Constructor
    //

    function test_constructorRejectsNonContracts() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "PositionManager"));
        new UniswapV4SicklePoolsMetaBalanceAdapter(
            address(0), address(poolManager), address(index), address(nav), address(factory)
        );

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "PoolManager"));
        new UniswapV4SicklePoolsMetaBalanceAdapter(
            address(posm), makeAddr("eoa"), address(index), address(nav), address(factory)
        );

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "V4PositionIndex"));
        new UniswapV4SicklePoolsMetaBalanceAdapter(
            address(posm), address(poolManager), makeAddr("eoa2"), address(nav), address(factory)
        );

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "SickleFactory"));
        new UniswapV4SicklePoolsMetaBalanceAdapter(
            address(posm), address(poolManager), address(index), address(nav), makeAddr("eoa3")
        );
    }

    function test_immutablesArePinned() public view {
        assertEq(address(meta.POSITION_MANAGER()), address(posm));
        assertEq(address(meta.POOL_MANAGER()), address(poolManager));
        assertEq(address(meta.POSITION_INDEX()), address(index));
        assertEq(address(meta.SICKLE_FACTORY()), address(factory));
        assertEq(meta.MAX_POSITIONS(), 1000);
    }

    //
    // Non-NAV-path members
    //

    function test_nonMetaMembersAreEmpty() public view {
        (address[] memory a, uint256[] memory b, bool[] memory c) = meta.getAdapterBalances(safe);
        assertEq(a.length, 0);
        assertEq(b.length, 0);
        assertEq(c.length, 0);
        (uint256 amt, bool ok) = meta.getAdapterBalanceForAsset(safe, address(usdg));
        assertEq(amt, 0);
        assertFalse(ok);
    }
}
