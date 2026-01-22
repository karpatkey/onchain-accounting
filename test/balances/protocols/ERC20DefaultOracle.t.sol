// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {Balances} from "src/balances/Balances.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

contract BalancesHarnessForTest is Balances {
    ERC20DefaultOracle public defaultOracle;

    constructor() initializer {
        __Balances_init();
        // Set up ERC20DefaultOracle
        defaultOracle = new ERC20DefaultOracle(address(this));
        _setErc20DefaultOracle(address(defaultOracle));
    }

    // Expose internal functions for testing
    function registerAssetForTest(address asset, uint8 decimals) public {
        _registerAsset(asset, decimals);
    }

    function setAssetSymbolForTest(address asset, string memory symbol) public {
        _setAssetSymbol(asset, symbol);
    }
}

contract ERC20DefaultOracleTest is TestEnvConfigurator {
    BalancesHarnessForTest public balances;
    ERC20DefaultOracle public oracle;

    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;
    Mock_ERC20 public weth;
    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    function setUp() public {
        balances = new BalancesHarnessForTest();
        oracle = balances.defaultOracle();
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);
        weth = new Mock_ERC20("WETH", 18);
    }

    function test_constructor() public view {
        assertEq(address(oracle.BALANCES()), address(balances));
    }

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0x12345678));
    }

    function test_underlyingAssetsSupported_returnsAllRegisteredAssets() public {
        // Register some assets
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");
        balances.registerAssetForTest(address(dai), 18);
        balances.setAssetSymbolForTest(address(dai), "DAI");
        balances.registerAssetForTest(address(weth), 18);
        balances.setAssetSymbolForTest(address(weth), "WETH");
        balances.registerAssetForTest(NATIVE_ADDRESS, 18);
        balances.setAssetSymbolForTest(NATIVE_ADDRESS, "ETH");

        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 4);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(dai));
        assertEq(assets[2], address(weth));
        assertEq(assets[3], NATIVE_ADDRESS);
    }

    function test_underlyingAssetsSupported_returnsEmptyWhenNoAssets() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
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
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");

        int256 balance = oracle.getOracleBalanceForAsset(user, address(0));
        assertEq(balance, 0);
    }

    function test_getOracleBalance_returnsEmptyWhenNoAssets() public {
        address user = makeAddr("user");

        (address[] memory assets, int256[] memory amounts) = oracle.getOracleBalance(user);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getOraclePositions_returnsEmptyWhenNoAssets() public {
        address user = makeAddr("user");

        INAVCalculator.Position[] memory positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 0);
    }

    function test_getOraclePositions_withAssetFilter() public {
        address user = makeAddr("user");
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");
        balances.registerAssetForTest(address(dai), 18);
        balances.setAssetSymbolForTest(address(dai), "DAI");

        // Mint some tokens to the user so we have a balance
        usdc.mint(user, 1000e6);

        // Filter by USDC
        INAVCalculator.Position[] memory positions = oracle.getOraclePositions(user, address(usdc));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(usdc));
        assertEq(positions[0].underlyingAsset.symbol, "USDC");
        assertEq(positions[0].underlyingAsset.decimals, 6);
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].protocol, "wallet");
    }

    function test_getOraclePositions_protocolAndPositionDetail() public {
        address user = makeAddr("user");
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");

        INAVCalculator.Position[] memory positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 0); // No balance, so no positions

        // Mint some USDC to the user
        usdc.mint(user, 1000e6);

        positions = oracle.getOraclePositions(user, address(0));
        assertEq(positions.length, 1);
        assertEq(positions[0].protocol, "wallet");
        assertEq(positions[0].positionDetail, "USDC");
    }
}
