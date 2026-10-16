// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {
    UniswapV3SicklePoolsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/vfat/UniswapV3SicklePoolsMetaBalanceAdapter.sol";
import {TickMath} from "src/balances/MetaBalanceAdapters/uniswap/lib/TickMath.sol";
import {FixedPoint128} from "src/balances/MetaBalanceAdapters/uniswap/lib/FixedPoint128.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IPositionEnumerable} from "src/balances/IPositionEnumerable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {NotAContract} from "src/errors.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";
import {
    MockUniswapV3Pool,
    MockPositionManager,
    MockToken
} from "test/balances/MetaBalanceAdapters/uniswap/UniswapV3Mocks.sol";
import {
    MockSickleFactory,
    MockSickle,
    MockRevertingOwnerSickle
} from "test/balances/MetaBalanceAdapters/vfat/SickleMocks.sol";

/// @title UniswapV3SicklePoolsMetaBalanceAdapter unit tests (no fork)
/// @notice The adapter is the join of two tested parts, so these tests pin the JOIN: that an account's own NFTs and
///         the NFTs held by its admitted vfat Sickle both surface in one call, with the base adapter's identity,
///         valuation and gating unchanged, and that a Sickle the admission rule rejects contributes nothing.
contract UniswapV3SicklePoolsMetaBalanceAdapterTest is Test {
    Mock_NAVCalculator nav;
    MockPositionManager npm;
    MockSickleFactory factory;
    UniswapV3SicklePoolsMetaBalanceAdapter meta;

    MockToken usdg; // token0
    MockToken crcl; // token1
    MockUniswapV3Pool pool; // USDG/CRCL 0.3%

    address avatar = makeAddr("avatar");
    address stranger = makeAddr("stranger");
    address sickle;

    function setUp() public {
        nav = new Mock_NAVCalculator();
        npm = new MockPositionManager();
        factory = new MockSickleFactory();

        usdg = new MockToken("USDG", 6);
        crcl = new MockToken("CRCL", 18);
        nav.registerAsset(address(usdg), 6, "USDG");
        nav.registerAsset(address(crcl), 18, "CRCL");

        pool = new MockUniswapV3Pool(address(usdg), address(crcl), 3000, 60);
        // Tick 0 is inside every minted position's [-100, 100] range, so both principal legs are non-zero.
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);

        sickle = address(new MockSickle(avatar));
        factory.setSickle(avatar, sickle);

        meta = new UniswapV3SicklePoolsMetaBalanceAdapter(address(npm), address(nav), address(factory));
    }

    function _mint(address owner, uint256 id, uint128 liq, uint128 owed0, uint128 owed1) internal {
        npm.mint(
            owner,
            id,
            MockPositionManager.PositionData({
                token0: address(usdg),
                token1: address(crcl),
                fee: 3000,
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

    function _instances() internal view returns (bytes32[] memory ins) {
        ins = new bytes32[](1);
        ins[0] = bytes32(uint256(uint160(address(pool))));
    }

    function _read(address account, address assetFilter)
        internal
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return meta.getAdapterPositionsForInstances(account, _instances(), assetFilter);
    }

    //
    // Constructor guards
    //

    function test_constructor_rejectsNonContractPositionManager() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "PositionManager"));
        new UniswapV3SicklePoolsMetaBalanceAdapter(address(0), address(nav), address(factory));

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "PositionManager"));
        new UniswapV3SicklePoolsMetaBalanceAdapter(makeAddr("eoaNpm"), address(nav), address(factory));
    }

    function test_constructor_rejectsNonContractNavCalculator() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new UniswapV3SicklePoolsMetaBalanceAdapter(address(npm), address(0), address(factory));

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new UniswapV3SicklePoolsMetaBalanceAdapter(address(npm), makeAddr("eoaNav"), address(factory));
    }

    function test_constructor_rejectsNonContractSickleFactory() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "SickleFactory"));
        new UniswapV3SicklePoolsMetaBalanceAdapter(address(npm), address(nav), address(0));

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "SickleFactory"));
        new UniswapV3SicklePoolsMetaBalanceAdapter(address(npm), address(nav), makeAddr("eoaFactory"));
    }

    function test_constructor_pinsImmutables() public view {
        assertEq(meta.POSITION_MANAGER(), address(npm));
        assertEq(address(meta.SICKLE_FACTORY()), address(factory));
        assertEq(address(meta.NAV_CALCULATOR()), address(nav));
        assertEq(meta.MAX_POSITIONS(), 1000, "the upstream cap, not the 4663 build's 256");
    }

    //
    // ERC-165
    //

    function test_supportsInterface_true() public view {
        assertTrue(meta.supportsInterface(type(IMetaBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(meta.supportsInterface(type(IPositionEnumerable).interfaceId));
        assertTrue(meta.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_false() public view {
        assertFalse(meta.supportsInterface(0xffffffff), "the ERC-165 invalid id");
        assertFalse(meta.supportsInterface(0x00000000));
        assertFalse(meta.supportsInterface(0x80ac58cd), "ERC-721");
        assertFalse(meta.supportsInterface(0x36372b07), "ERC-20");
    }

    //
    // Holder resolution
    //

    /// @notice An account with no Sickle still reports its own NFTs — the adapter is a superset of the base.
    function test_noSickle_ownLegsOnly() public {
        _mint(stranger, 1, 1_000_000, 42, 1337);
        assertEq(meta.sickleOf(stranger), address(0));

        INAVCalculator.PositionBalance[] memory p = _read(stranger, address(0));
        assertEq(p.length, 4, "4 legs for the account's own NFT");
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionInstanceId, bytes32(uint256(1)));
        }
    }

    /// @notice The shape every live 4663 vault has: the Safe owns nothing directly, the Sickle owns the NFT.
    function test_sickleHeldPositions_areReportedForTheAccount() public {
        _mint(sickle, 1, 1_000_000, 42, 1337);
        assertEq(npm.balanceOf(avatar), 0, "the account itself holds no NFT");

        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        assertEq(p.length, 4, "the Sickle's 4 legs are the account's");
        assertEq(p[0].positionId, abi.encode(address(pool)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
    }

    /// @notice Legs from BOTH holders in ONE call, the account's first.
    function test_bothHolders_inOneCall() public {
        _mint(avatar, 1, 1_000_000, 42, 1337); // held directly
        _mint(sickle, 2, 500_000, 7, 9); // held by the Sickle

        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        assertEq(p.length, 8, "4 legs per NFT, two NFTs across two holders");

        bool saw1;
        bool saw2;
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionId, abi.encode(address(pool)), "one pool, one positionId");
            if (p[i].positionInstanceId == bytes32(uint256(1))) saw1 = true;
            if (p[i].positionInstanceId == bytes32(uint256(2))) saw2 = true;
        }
        assertTrue(saw1, "the account's own NFT");
        assertTrue(saw2, "the Sickle's NFT");
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)), "the account's legs come first");
        assertEq(p[4].positionInstanceId, bytes32(uint256(2)), "the Sickle's legs follow");
    }

    /// @notice A factory entry that fails the reverse `owner()` check contributes NOTHING: the account sees only
    ///         its own legs, even though the foreign Sickle holds a large position in the same pool.
    function test_factoryEntryFailingReverseCheck_reportsOnlyOwnLegs() public {
        address foreign = address(new MockSickle(stranger)); // owned by stranger...
        factory.setSickle(avatar, foreign); // ...but filed under avatar
        _mint(avatar, 1, 1_000_000, 42, 1337);
        _mint(foreign, 2, 999_000_000_000, 1, 1);

        assertEq(meta.sickleOf(avatar), address(0), "both directions must agree");
        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        assertEq(p.length, 4, "only the account's own NFT");
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionInstanceId, bytes32(uint256(1)), "the foreign Sickle's NFT is not borrowed");
        }
    }

    /// @notice A Sickle whose `owner()` reverts is not admitted and does not take the read down.
    function test_sickleWithRevertingOwner_failsOpen() public {
        address broken = address(new MockRevertingOwnerSickle());
        factory.setSickle(avatar, broken);
        _mint(avatar, 1, 1_000_000, 42, 1337);
        _mint(broken, 2, 2_000_000, 5, 5);

        assertEq(meta.sickleOf(avatar), address(0));
        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        assertEq(p.length, 4, "the account's own legs survive");
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
    }

    //
    // Identity, gating, valuation (inherited, pinned through the Sickle path)
    //

    /// @notice Every identity field on a Sickle-held leg, and the exact positionId bytes.
    function test_identityFields_onSickleHeldLegs() public {
        _mint(sickle, 1, 1_000_000, 42, 1337);
        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        assertEq(p.length, 4);

        bytes memory expectedPid = abi.encode(address(pool));
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].positionId, expectedPid, "positionId = abi.encode(pool)");
            assertEq(p[i].positionId.length, 32, "exactly one clean word");
            assertEq(p[i].balanceAdapter, address(meta));
            assertEq(p[i].protocolBrand, ProtocolIds.UNISWAP);
            assertEq(p[i].protocolId, ProtocolIds.UNISWAP_V3);
            assertEq(p[i].protocolSubId, ProtocolIds.UNISWAP_V3);
            assertFalse(p[i].isDebt);
            assertFalse(p[i].isLocked, "LP liquidity and unclaimed fees are always withdrawable");
            assertEq(p[i].positionInstanceId, bytes32(uint256(1)), "the NFT id rides here");
        }
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Supplied));
        assertEq(uint8(p[2].positionKind), uint8(PositionKind.Fees));
        assertEq(uint8(p[3].positionKind), uint8(PositionKind.Fees));
        assertEq(p[0].balanceAsset.asset, address(usdg));
        assertEq(p[1].balanceAsset.asset, address(crcl));
    }

    /// @notice Fees are NOT `tokensOwed`: with a never-poked Sickle position (`tokensOwed == 0`) and non-zero
    ///         global fee growth, the Fees leg is the full accrued amount. This is the live 4663 shape.
    function test_fees_accrueWithoutAPoke() public {
        _mint(sickle, 1, 1_000_000, 0, 0); // tokensOwed0 == tokensOwed1 == 0, as on chain
        pool.setFeeGrowthGlobal(2 * FixedPoint128.Q128, 0);
        pool.setTickFeeGrowth(-100, 0, 0);
        pool.setTickFeeGrowth(100, 0, 0);

        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        uint256 usdgFee;
        for (uint256 i; i < p.length; ++i) {
            if (p[i].positionKind == PositionKind.Fees && p[i].balanceAsset.asset == address(usdg)) {
                usdgFee = p[i].amount;
            }
        }
        assertEq(usdgFee, 2 * 1_000_000, "feeGrowthInside-since-poke, with tokensOwed zero");
    }

    /// @notice `assetFilter` gates which legs are emitted, for the Sickle's holdings too.
    function test_assetFilter() public {
        _mint(sickle, 1, 1_000_000, 42, 1337);
        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(usdg));
        assertEq(p.length, 2, "Supplied + Fees, USDG only");
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].balanceAsset.asset, address(usdg));
        }
        assertEq(_read(avatar, makeAddr("unrelatedToken")).length, 0, "a filter matching neither pool token");
    }

    /// @notice Unregistering either pool token drops the WHOLE instance — both holders — because NAV values an LP
    ///         from the sum of its two legs. The 4663 build had no such gate.
    function test_unregisteredToken_dropsWholeInstance() public {
        _mint(avatar, 1, 1_000_000, 42, 1337);
        _mint(sickle, 2, 500_000, 7, 9);
        assertEq(_read(avatar, address(0)).length, 8, "both holders report before the unregistration");

        nav.unregisterAssetHelper(address(crcl));
        assertEq(_read(avatar, address(0)).length, 0, "one unregistered leg drops the instance for both holders");
    }

    /// @notice NFTs in a different pool are filtered out by the `(token0, token1, fee)` triple, for both holders.
    function test_otherPoolNfts_filteredOut() public {
        MockToken other = new MockToken("OTH", 18);
        nav.registerAsset(address(other), 18, "OTH");
        npm.mint(
            sickle,
            9,
            MockPositionManager.PositionData({
                token0: address(usdg),
                token1: address(other),
                fee: 3000,
                tickLower: -100,
                tickUpper: 100,
                liquidity: 1_000_000,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0,
                tokensOwed0: 1,
                tokensOwed1: 1
            })
        );
        _mint(sickle, 1, 1_000_000, 42, 1337);

        INAVCalculator.PositionBalance[] memory p = _read(avatar, address(0));
        assertEq(p.length, 4, "only the NFT whose triple matches this pool");
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
    }

    /// @notice A reverting pool is isolated by the framework's per-instance try/catch — one frame covers BOTH
    ///         holders (the deliberate difference from the 4663 build's per-(holder, instance) isolation).
    function test_revertingPool_isolatesBothHolders() public {
        _mint(avatar, 1, 1_000_000, 42, 1337);
        _mint(sickle, 2, 500_000, 7, 9);
        pool.setSlot0Reverts(true);
        assertEq(_read(avatar, address(0)).length, 0, "the instance is dropped for both holders, not just one");
    }

    /// @notice Labels are the base's, unchanged, and keyed off the pool in positionId.
    function test_positionLabels() public view {
        string[] memory labels = meta.positionLabels(abi.encode(address(pool)));
        assertEq(labels.length, 2);
        assertEq(labels[0], "AMM Liquidity Pool");
        assertEq(labels[1], "USDG/CRCL 0.3%");
    }

    /// @notice `positionIds()` enumerates the governed set, and each id is byte-identical to an emitted
    ///         `positionId` — including when the legs came from the Sickle.
    function test_positionIds_matchEmittedPositionIds() public {
        _mint(sickle, 1, 1_000_000, 42, 1337);
        nav.setMetaInstances(address(meta), _instances());

        bytes[] memory ids = meta.positionIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], abi.encode(address(pool)));

        INAVCalculator.PositionBalance[] memory p = meta.getAdapterPositions(avatar, address(0));
        assertEq(p.length, 4, "the governed-set read sees the Sickle's legs");
        assertEq(p[0].positionId, ids[0]);
    }

    function test_noArgMethods_returnEmpty() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory debts) = meta.getAdapterBalances(avatar);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(debts.length, 0);
        (uint256 amount, bool found) = meta.getAdapterBalanceForAsset(avatar, address(usdg));
        assertEq(amount, 0);
        assertFalse(found);
        assertEq(meta.underlyingAssetsSupported().length, 0);
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory a = meta.underlyingAssetsSupportedForInstances(_instances());
        assertEq(a.length, 2);
        assertEq(a[0], address(usdg));
        assertEq(a[1], address(crcl));
    }
}
