// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BridgedAssetsOracle} from "src/balances/protocols/BridgedAssetsOracle.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract BridgedAssetsOracleTest is Test {
    NAVCalculator public navCalculator;
    BridgedAssetsOracle public oracle;

    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;
    Mock_CustomPriceFeed public usdcOracle;
    Mock_CustomPriceFeed public daiOracle;
    Mock_CustomPriceFeed public ethOracle;

    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public operator = makeAddr("operator");
    address public alice = makeAddr("alice");

    event BridgePositionOpened(
        uint256 indexed bridgeId,
        address indexed operator,
        address indexed account,
        address asset,
        uint256 amount,
        uint64 sourceChainId,
        uint64 destinationChainId
    );

    function setUp() public {
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);

        usdcOracle = new Mock_CustomPriceFeed("USDC", address(usdc), 1e8, 8);
        daiOracle = new Mock_CustomPriceFeed("DAI", address(dai), 1e8, 8);
        ethOracle = new Mock_CustomPriceFeed("ETH", NATIVE_ADDRESS, 2000e8, 8);

        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
        );
        navCalculator = NAVCalculator(navProxy);
        navCalculator.grantRole(MANAGER, manager);
        oracle = new BridgedAssetsOracle(address(navCalculator), "ManualBridge");
        vm.stopPrank();

        vm.startPrank(manager);
        navCalculator.setPriceFeed(NATIVE_ADDRESS, address(ethOracle), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(dai), address(daiOracle), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.addBalanceOracle(address(oracle));
        vm.stopPrank();

        vm.prank(admin);
        oracle.setOperator(operator, true);
    }

    function test_constructor_revertsForInvalidArgs() public {
        vm.expectRevert(InvalidArguments.selector);
        new BridgedAssetsOracle(address(0), "ManualBridge");

        vm.expectRevert(InvalidArguments.selector);
        new BridgedAssetsOracle(address(navCalculator), "");
    }

    function test_constructor() public view {
        assertEq(address(oracle.NAV_CALCULATOR()), address(navCalculator));
        assertEq(oracle.ADMIN(), admin);
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0x12345678));
    }

    function test_setOperator_onlyAdmin() public {
        vm.prank(manager);
        vm.expectRevert(NotAuthorized.selector);
        oracle.setOperator(makeAddr("newOperator"), true);
    }

    function test_setOperator_revertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(InvalidArguments.selector);
        oracle.setOperator(address(0), true);
    }

    function test_openBridgePosition_emitsSourceChainId() public {
        vm.expectEmit(true, true, true, true);
        emit BridgePositionOpened(1, operator, alice, address(usdc), 100e6, uint64(block.chainid), 10);

        vm.prank(operator);
        uint256 bridgeId = oracle.openBridgePosition(alice, address(usdc), 100e6, 10);
        assertEq(bridgeId, 1);
    }

    function test_openBridgePosition_onlyOperator() public {
        vm.prank(manager);
        vm.expectRevert(NotAuthorized.selector);
        oracle.openBridgePosition(alice, address(usdc), 100e6, 10);
    }

    function test_openBridgePosition_revertsForUnregisteredAsset() public {
        address randomAsset = makeAddr("randomAsset");
        vm.prank(operator);
        vm.expectRevert(AssetNotFound.selector);
        oracle.openBridgePosition(alice, randomAsset, 100e6, 10);
    }

    function test_closeBridgePosition() public {
        vm.prank(operator);
        uint256 bridgeId = oracle.openBridgePosition(alice, address(usdc), 120e6, 10);

        vm.prank(operator);
        oracle.closeBridgePosition(bridgeId);

        BridgedAssetsOracle.BridgePosition memory position = oracle.getBridgePosition(bridgeId);
        assertFalse(position.active);

        vm.prank(operator);
        vm.expectRevert(InvalidArguments.selector);
        oracle.closeBridgePosition(bridgeId);
    }

    function test_getOraclePositions_and_getOracleBalances_shareAggregation() public {
        vm.startPrank(operator);
        oracle.openBridgePosition(alice, address(usdc), 50e6, 10);
        oracle.openBridgePosition(alice, address(usdc), 70e6, 10);
        oracle.openBridgePosition(alice, address(usdc), 30e6, 42161);
        vm.stopPrank();

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 2, "USDC should aggregate by destination chain");
        assertEq(positions[0].underlyingAsset.asset, address(usdc));
        assertEq(positions[0].isDebt, false);
        assertEq(positions[0].protocol, "ManualBridge");

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1, "USDC should aggregate across chains");
        assertEq(assets[0], address(usdc));
        assertEq(amounts[0], 150e6);
        assertFalse(isDebt[0]);

        (uint256 amount, bool debt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 150e6);
        assertFalse(debt);

        BridgedAssetsOracle.BridgePosition[] memory destination10 =
            oracle.getActiveBridgePositionsByDestinationChain(10);
        BridgedAssetsOracle.BridgePosition[] memory destination42161 =
            oracle.getActiveBridgePositionsByDestinationChain(42161);
        assertEq(destination10.length, 2);
        assertEq(destination42161.length, 1);
    }

    function test_getOraclePositions_assetFilter() public {
        vm.startPrank(operator);
        oracle.openBridgePosition(alice, address(usdc), 100e6, 10);
        oracle.openBridgePosition(alice, address(dai), 2e18, 10);
        vm.stopPrank();

        INAVCalculator.PositionBalance[] memory usdcPositions = oracle.getOraclePositions(alice, address(usdc));
        assertEq(usdcPositions.length, 1);
        assertEq(usdcPositions[0].underlyingAsset.asset, address(usdc));
        assertEq(usdcPositions[0].amount, 100e6);
    }

    function test_getOraclePositions_unregisteredAssetFilterReturnsEmpty() public {
        vm.prank(operator);
        oracle.openBridgePosition(alice, address(usdc), 100e6, 10);

        address unregistered = makeAddr("unregistered");
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, unregistered);
        assertEq(positions.length, 0);
    }

    function test_getAccountActiveBridgePositions() public {
        vm.startPrank(operator);
        uint256 id1 = oracle.openBridgePosition(alice, address(usdc), 10e6, 10);
        oracle.openBridgePosition(alice, address(dai), 1e18, 137);
        vm.stopPrank();

        vm.prank(operator);
        oracle.closeBridgePosition(id1);

        BridgedAssetsOracle.BridgePosition[] memory active = oracle.getAccountActiveBridgePositions(alice);
        assertEq(active.length, 1);
        assertEq(active[0].asset, address(dai));
        assertTrue(active[0].active);
    }

    function test_getAccountActiveBridgePositions_zeroAddressReturnsEmpty() public view {
        BridgedAssetsOracle.BridgePosition[] memory active = oracle.getAccountActiveBridgePositions(address(0));
        assertEq(active.length, 0);
    }

    function test_getActiveBridgePositionsByDestinationChain_zeroReturnsEmpty() public view {
        BridgedAssetsOracle.BridgePosition[] memory positions = oracle.getActiveBridgePositionsByDestinationChain(0);
        assertEq(positions.length, 0);
    }

    function test_underlyingAssetsSupported_equalsRegisteredAssets() public view {
        address[] memory supported = oracle.underlyingAssetsSupported();
        INAVCalculator.Asset[] memory registered = navCalculator.getRegisteredAssets();
        assertEq(supported.length, registered.length);
    }

    function test_getOraclePositions_zeroAccountReturnsEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0);
    }

    function test_getOracleBalances_zeroAccountReturnsEmpty() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalanceForAsset_invalidInputsReturnZero() public {
        (uint256 amount1, bool debt1) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        (uint256 amount2, bool debt2) = oracle.getOracleBalanceForAsset(alice, address(0));
        (uint256 amount3, bool debt3) = oracle.getOracleBalanceForAsset(alice, makeAddr("unregistered-asset"));

        assertEq(amount1, 0);
        assertEq(amount2, 0);
        assertEq(amount3, 0);
        assertFalse(debt1);
        assertFalse(debt2);
        assertFalse(debt3);
    }

    function test_navIntegration_getAccountNavIncludesManualBridgedPositions() public {
        vm.startPrank(operator);
        oracle.openBridgePosition(alice, address(usdc), 200e6, 10); // $200
        oracle.openBridgePosition(alice, address(dai), 3e18, 10); // $3
        vm.stopPrank();

        INAVCalculator.NAV memory nav = navCalculator.getAccountNav(alice, address(0));
        assertEq(nav.value, 203e8);
    }
}
