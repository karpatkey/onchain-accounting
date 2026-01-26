// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
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

contract ERC20DefaultOracleTest is TestEnvConfigurator {
    NAVCalculator public navCalculator;
    ERC20DefaultOracle public oracle;

    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;
    Mock_ERC20 public weth;
    Mock_CustomPriceFeed public usdcOracle;
    Mock_CustomPriceFeed public daiOracle;
    Mock_CustomPriceFeed public wethOracle;
    Mock_CustomPriceFeed public ethOracle;

    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");

    function setUp() public {
        // Set up tokens
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);
        weth = new Mock_ERC20("WETH", 18);

        // Set up price feeds
        usdcOracle = new Mock_CustomPriceFeed("USDC", address(usdc), 1e8, 8);
        daiOracle = new Mock_CustomPriceFeed("DAI", address(dai), 1e8, 8);
        wethOracle = new Mock_CustomPriceFeed("WETH", address(weth), 2000e8, 8);
        ethOracle = new Mock_CustomPriceFeed("ETH", NATIVE_ADDRESS, 2000e8, 8);

        // Set up NAVCalculator
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, makeAddr("safe"), address(0)))
        );
        navCalculator = NAVCalculator(navProxy);
        navCalculator.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register assets in NAVCalculator
        vm.startPrank(manager);
        navCalculator.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(dai), address(daiOracle), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(weth), address(wethOracle), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(NATIVE_ADDRESS, address(ethOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        // Create ERC20DefaultOracle (it's already created by NAVCalculator, but we can get it)
        oracle = ERC20DefaultOracle(navCalculator.erc20DefaultOracle());
    }

    function test_constructor() public view {
        assertEq(address(oracle.NAV_CALCULATOR()), address(navCalculator));
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0x12345678));
    }

    function test_underlyingAssetsSupported_returnsAllRegisteredAssets() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 4);
        
        // Assets can be in any order, so we check by searching
        bool foundUsdc = false;
        bool foundDai = false;
        bool foundWeth = false;
        bool foundNative = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(usdc)) foundUsdc = true;
            if (assets[i] == address(dai)) foundDai = true;
            if (assets[i] == address(weth)) foundWeth = true;
            if (assets[i] == NATIVE_ADDRESS) foundNative = true;
        }
        assertTrue(foundUsdc, "USDC should be found");
        assertTrue(foundDai, "DAI should be found");
        assertTrue(foundWeth, "WETH should be found");
        assertTrue(foundNative, "Native address should be found");
    }

    function test_underlyingAssetsSupported_returnsEmptyWhenNoAssets() public {
        // Create a new NAVCalculator with no assets
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, makeAddr("safe"), address(0)))
        );
        NAVCalculator emptyNav = NAVCalculator(navProxy);
        vm.stopPrank();

        ERC20DefaultOracle emptyOracle = ERC20DefaultOracle(emptyNav.erc20DefaultOracle());
        address[] memory assets = emptyOracle.underlyingAssetsSupported();
        assertEq(assets.length, 0);
    }

    function test_getOracleBalanceForAsset_returnsZeroForUnregisteredAsset() public {
        address user = makeAddr("user");
        address unregisteredAsset = makeAddr("unregistered");

        int256 balance = oracle.getOracleBalanceForAsset(user, unregisteredAsset);
        assertEq(balance, 0);
    }

    function test_getOracleBalanceForAsset_returnsZeroForZeroAddress() public {
        address user = makeAddr("user");

        int256 balance = oracle.getOracleBalanceForAsset(user, address(0));
        assertEq(balance, 0);
    }

    function test_getOracleBalance_returnsEmptyWhenNoAssets() public {
        address user = makeAddr("user");

        (address[] memory assets, int256[] memory balances) = oracle.getOracleBalance(user);
        // Should return all registered assets, but with zero balances
        assertEq(assets.length, 0);
        assertEq(balances.length, 0);
    }

    function test_getOraclePositions_returnsEmptyWhenNoAssets() public {
        address user = makeAddr("user");

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 0);
    }

    function test_getOraclePositions_withAssetFilter() public {
        address user = makeAddr("user");

        // Mint some tokens to the user so we have a balance
        usdc.mint(user, 1000e6);

        // Filter by USDC
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(user, address(usdc));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(usdc));
        assertEq(positions[0].underlyingAsset.symbol, "USDC");
        assertEq(positions[0].underlyingAsset.decimals, 6);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].protocol, "wallet");
        assertEq(positions[0].positionDetail, "USDC");
    }

    function test_getOraclePositions_protocolAndPositionDetail() public {
        address user = makeAddr("user");

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 0); // No balance, so no positions

        // Mint some USDC to the user
        usdc.mint(user, 1000e6);

        positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].protocol, "wallet");
        assertEq(positions[0].positionDetail, "USDC");
    }
}
