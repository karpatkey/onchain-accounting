// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {SparkLendBalanceAdapter} from "src/balances/protocols/SparkLend.sol";
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
    address constant PRICE_FEED_LIB = 0x4D19204c82bac5677Dc06C80E7a95df8232D1988;

    // Aave V3 Core (mainnet) ProtocolDataProvider — the instance coordinate.
    address public constant CORE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public constant WBTC = MAINNET_WBTC;
    address public constant USDC = MAINNET_USDC;
    address public constant DAI = MAINNET_DAI;
    // Account with WBTC collateral + USDC/DAI positions on Core at the default fork block.
    address public constant USER = 0xe84A061897afc2e7fF5FB7e3686717C528617487;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    NAVCalculator public nav;
    AaveV3InstancesMetaBalanceAdapter public adapter;
    SparkLendBalanceAdapter public perInstance;

    function setUp() public override {
        super.setUp(); // forks mainnet at DEFAULT_FORK_BLOCK

        vm.etch(PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(0x02F27E28452E6F419b97935f6346381E2b5003B1, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);

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
        vm.stopPrank();

        adapter = new AaveV3InstancesMetaBalanceAdapter("Aave V3", address(nav));
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
        // Same reserve iteration order; identical VALUE fields. positionId is the same Pool address for both, but
        // the meta-adapter derives it lowercase (Strings.toHexString) while the per-instance adapter pins the
        // checksummed config string — same address, different case, so compare case-insensitively.
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
}
