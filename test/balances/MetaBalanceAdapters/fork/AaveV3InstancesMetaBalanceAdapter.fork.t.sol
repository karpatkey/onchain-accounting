// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    AaveV3InstancesMetaBalanceAdapter,
    IAaveAddressesProviderSource,
    IAavePoolAddressesProvider
} from "src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol";
import {RawReplier, RawReplyLib} from "test/mocks/RawReplier.sol";
import {SparkLendBalanceAdapter} from "src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {aa} from "test/helpers/AdapterArray.sol";

/// @title AaveV3InstancesMetaBalanceAdapter fork tests
/// @notice One meta-adapter serving Aave V3 instances, routed through a real NAVCalculator that holds the
///         configured DataProvider set (seeded via addMetaBalanceAdapter). Uses the mainnet Core instance and an account with
///         collateral + supply + borrow, and asserts parity with the per-instance AaveV3Instance adapter.
contract AaveV3InstancesMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    address constant PRICE_FEED_LIB = LibraryPins.PRICE_FEED_LIB;

    // Aave V3 Core (mainnet) ProtocolDataProvider — the instance coordinate.
    address public constant CORE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public constant WBTC = MAINNET_WBTC;
    address public constant USDC = MAINNET_USDC;
    address public constant DAI = MAINNET_DAI;
    // The account also BORROWS USDT (reserve id 8). It must be registered: an unreportable debt now suppresses
    // the whole instance, so leaving USDT out would make this fixture assert the very over-report the adapter
    // exists to prevent (collateral reported, USDT borrow silently dropped).
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // Account with WBTC collateral + USDC/DAI positions and USDC/USDT borrows on Core at the default fork block.
    address public constant USER = 0xe84A061897afc2e7fF5FB7e3686717C528617487;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    NAVCalculator public nav;
    AaveV3InstancesMetaBalanceAdapter public adapter;
    SparkLendBalanceAdapter public perInstance;

    function setUp() public override {
        super.setUp(); // forks mainnet at DEFAULT_FORK_BLOCK

        vm.etch(PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
            )
        );
        nav.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register the account's reserves with mock feeds + native ETH for getAccountNav.
        vm.startPrank(manager);
        nav.addPriceFeed(
            nav.NATIVE_ADDRESS(),
            address(new Mock_CustomPriceFeed("ETH", nav.NATIVE_ADDRESS(), 3000e8, 8)),
            IPrices.PriceType.Custom,
            type(uint256).max
        );
        nav.registerAsset(
            WBTC,
            address(new Mock_CustomPriceFeed("WBTC", WBTC, 60_000e8, 8)),
            IPrices.PriceType.Custom,
            type(uint256).max
        );
        nav.registerAsset(
            USDC, address(new Mock_CustomPriceFeed("USDC", USDC, 1e8, 8)), IPrices.PriceType.Custom, type(uint256).max
        );
        nav.registerAsset(
            DAI, address(new Mock_CustomPriceFeed("DAI", DAI, 1e8, 8)), IPrices.PriceType.Custom, type(uint256).max
        );
        nav.registerAsset(
            USDT, address(new Mock_CustomPriceFeed("USDT", USDT, 1e8, 8)), IPrices.PriceType.Custom, type(uint256).max
        );
        vm.stopPrank();

        adapter = new AaveV3InstancesMetaBalanceAdapter(address(nav));
        perInstance = new SparkLendBalanceAdapter(CORE_DATA_PROVIDER, address(nav));

        vm.startPrank(manager);
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(uint160(CORE_DATA_PROVIDER)));
        nav.addMetaBalanceAdapter(address(adapter), instances);
        vm.stopPrank();
    }

    function _ids() internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = bytes32(uint256(uint160(CORE_DATA_PROVIDER)));
    }

    function test_positions_nonEmpty_attributed() public view {
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(USER, _ids(), address(0));
        assertGt(pos.length, 0, "account has Core positions");
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAdapter, address(adapter));
            assertGt(pos[i].amount, 0);
        }
    }

    function test_parity_withPerInstanceAdapter() public view {
        INAVCalculator.PositionBalance[] memory metaPos =
            adapter.getAdapterPositionsForInstances(USER, _ids(), address(0));
        INAVCalculator.PositionBalance[] memory refPos = perInstance.getAdapterPositions(USER, address(0));

        assertEq(metaPos.length, refPos.length, "same leg count as per-instance adapter");
        // Same reserve iteration order; identical VALUE fields. positionId is `abi.encode(pool)` for both (the
        // reserve is NOT encoded — it lives in balanceAsset): the meta resolves the pool from the instance
        // DataProvider, the per-instance SparkLend adapter pins the same pool at construction, so the encodings
        // are byte-identical.
        for (uint256 i = 0; i < metaPos.length; i++) {
            assertEq(metaPos[i].balanceAsset.asset, refPos[i].balanceAsset.asset, "asset");
            assertEq(metaPos[i].amount, refPos[i].amount, "amount");
            assertEq(metaPos[i].isDebt, refPos[i].isDebt, "isDebt");
            assertEq(metaPos[i].positionId, refPos[i].positionId, "positionId");
        }
    }

    function test_navRouting_surfacesPositions() public view {
        INAVCalculator.PositionBalance[] memory expected =
            adapter.getAdapterPositionsForInstances(USER, _ids(), address(0));
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(USER, address(0));
        uint256 metaCount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAdapter == address(adapter)) metaCount++;
        }
        assertEq(metaCount, expected.length, "NAV surfaces every meta-adapter leg");
        assertGt(metaCount, 0);

        INAVCalculator.NAV memory snapshot = nav.getAccountNav(USER, address(0));
        assertTrue(snapshot.value != 0, "NAV computed");
    }

    function test_assetFilter_singleAsset() public view {
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(USER, _ids(), USDC);
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAsset.asset, USDC);
        }
    }

    /// @notice `positionIds()` advertises the resolved **Pool**, not the ProtocolDataProvider coordinate, and those
    ///         bytes are exactly what the adapter emits as `PositionBalance.positionId`.
    /// @dev Aave V3 is the one meta-adapter whose positionId is not its instance coordinate, so it is the one that
    ///      needs the `_instancePositionId` override. Without it the base default would advertise
    ///      `abi.encode(dataProvider)` and a configuration view could not JOIN its rows against real positions.
    ///
    ///      **This failure would be invisible to a label-based check**, which is why it is asserted on bytes: on
    ///      this very fork `positionLabels(dataProvider)` and `positionLabels(pool)` BOTH return
    ///      `["Market", <marketId>]`, because `_marketId` reads `ADDRESSES_PROVIDER()` and a ProtocolDataProvider
    ///      exposes that too, pointing at the same provider. The label is right by coincidence; only the identity
    ///      is wrong. Asserted here against the live mainnet Core instance.
    function test_positionIds_advertiseThePoolNotTheDataProvider() public view {
        address ap = IAaveAddressesProviderSource(CORE_DATA_PROVIDER).ADDRESSES_PROVIDER();
        address pool = IAavePoolAddressesProvider(ap).getPool();
        assertTrue(pool != CORE_DATA_PROVIDER, "pool and data provider must differ for this test to mean anything");

        bytes[] memory ids = adapter.positionIds();
        assertEq(ids.length, 1, "one configured instance");
        assertEq(ids[0], abi.encode(pool), "advertised id is the resolved Pool");
        assertTrue(
            keccak256(ids[0]) != keccak256(abi.encode(CORE_DATA_PROVIDER)),
            "advertised id must NOT be the DataProvider coordinate"
        );

        // Both label identically — the coincidence that makes a label-based check useless here.
        string[] memory viaPool = adapter.positionLabels(abi.encode(pool));
        string[] memory viaDp = adapter.positionLabels(abi.encode(CORE_DATA_PROVIDER));
        assertEq(viaPool.length, viaDp.length);
        assertEq(viaPool[1], viaDp[1], "the wrong id labels the same as the right one");
    }

    /// @notice The join guarantee against a REAL holder: every emitted positionId is an advertised shape.
    /// @dev This is the property a configuration view depends on, and the reason the override above exists.
    function test_positionIds_matchTheEmittedPositionIdsOnMainnet() public view {
        INAVCalculator.PositionBalance[] memory positions =
            adapter.getAdapterPositionsForInstances(USER, _ids(), address(0));
        assertGt(positions.length, 0, "the pinned holder must have Aave positions at this block");

        bytes[] memory ids = adapter.positionIds();
        for (uint256 i; i < positions.length; ++i) {
            bool matched;
            for (uint256 j; j < ids.length; ++j) {
                if (keccak256(ids[j]) == keccak256(positions[i].positionId)) matched = true;
            }
            assertTrue(matched, "every emitted positionId must be an advertised shape");
        }
    }

    /// @notice The hardened market-id reader decodes a REAL, proxied Aave provider byte-for-byte the same as a plain
    ///         high-level call does.
    /// @dev The unit tests prove the malformed shapes degrade; this proves the rewrite did not break the canonical
    ///      path against production bytecode. `getMarketId()` on mainnet Core is served through a proxy, which is
    ///      exactly the shape the raw-staticcall reader had to keep working.
    function test_positionLabels_realProvider_matchesDirectRead() public view {
        address ap = IAaveAddressesProviderSource(CORE_DATA_PROVIDER).ADDRESSES_PROVIDER();
        address pool = IAavePoolAddressesProvider(ap).getPool();
        string memory direct = IAavePoolAddressesProvider(ap).getMarketId();
        assertGt(bytes(direct).length, 0, "the real market id is non-empty");

        string[] memory labels = adapter.positionLabels(abi.encode(pool));
        assertEq(labels.length, 2, "category + market id");
        assertEq(labels[0], "Market");
        assertEq(labels[1], direct, "label leaf must equal the provider's own getMarketId()");
    }

    /// @notice Every uncaught failure mode degrades to `["Market"]` against the real deployed adapter — no revert.
    /// @dev Staged on the fork with {RawReplier} rather than mocked in isolation, so the assertion covers the
    ///      adapter as it will actually be deployed. A `try`/`catch` reader reverts on all four of these.
    function test_positionLabels_hostilePool_degradesOnFork() public {
        RawReplier provider = new RawReplier();
        RawReplier pool = new RawReplier();
        pool.stageReturn(abi.encode(address(provider)));

        bytes[] memory shapes = new bytes[](4);
        shapes[0] = RawReplyLib.bytes32String("Aave Ethereum Market"); // MKR-era bytes32 string
        shapes[1] = ""; // proxy to a code-less implementation
        shapes[2] = RawReplyLib.badOffset(0x40, "Aave Ethereum Market"); // malformed head
        shapes[3] = RawReplyLib.declaredLength(type(uint256).max, "x"); // absurd length

        for (uint256 i = 0; i < shapes.length; i++) {
            provider.stageReturn(shapes[i]);
            string[] memory labels = adapter.positionLabels(abi.encode(address(pool)));
            assertEq(labels.length, 1, "must degrade, not revert");
            assertEq(labels[0], "Market");
        }

        // A code-less pool reverts at Solidity's `extcodesize` precheck, which `try`/`catch` never sees either.
        string[] memory codeless = adapter.positionLabels(abi.encode(address(0xdead)));
        assertEq(codeless.length, 1, "a code-less pool must degrade too");
    }

    /// @notice A hostile provider cannot burn the caller's gas budget through the label path.
    /// @dev Measured without the stipend elsewhere in this change: over 1e9 gas for the looping case and ~17M for a
    ///      3 MB revert payload. Both are enough to out-of-gas a verbose NAV read.
    function test_positionLabels_hostileProvider_isGasBounded() public {
        RawReplier provider = new RawReplier();
        RawReplier pool = new RawReplier();
        pool.stageReturn(abi.encode(address(provider)));

        provider.stageBurnGas();
        uint256 before = gasleft();
        adapter.positionLabels(abi.encode(address(pool)));
        assertLt(before - gasleft(), 1_000_000, "gas-burning provider must be capped");

        provider.stageRevert(3_000_000);
        before = gasleft();
        adapter.positionLabels(abi.encode(address(pool)));
        assertLt(before - gasleft(), 1_000_000, "giant revert payload must be capped");
    }
}
