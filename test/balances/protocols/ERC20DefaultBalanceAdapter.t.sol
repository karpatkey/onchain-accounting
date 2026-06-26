// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {Test} from "forge-std/Test.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/protocols/ERC20DefaultBalanceAdapter.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
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

contract ERC20DefaultBalanceAdapterTest is Test {
    NAVCalculator public navCalculator;
    ERC20DefaultBalanceAdapter public adapter;

    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;
    Mock_ERC20 public weth;
    Mock_CustomPriceFeed public usdcAdapter;
    Mock_CustomPriceFeed public daiAdapter;
    Mock_CustomPriceFeed public wethAdapter;
    Mock_CustomPriceFeed public ethAdapter;

    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");

    function setUp() public {
        // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml libraries config).
        // In tests there's no chain state, so etch the runtime code there so DELEGATECALL succeeds.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(LibraryPins.PRICE_FEED_LIB, priceFeedLibImpl.code);
        vm.etch(0x2F1F6c17D64bE96F583D390be212aFCF8D0F102a, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

        // Set up tokens
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);
        weth = new Mock_ERC20("WETH", 18);

        // Set up price feeds
        usdcAdapter = new Mock_CustomPriceFeed("USDC", address(usdc), 1e8, 8);
        daiAdapter = new Mock_CustomPriceFeed("DAI", address(dai), 1e8, 8);
        wethAdapter = new Mock_CustomPriceFeed("WETH", address(weth), 2000e8, 8);
        ethAdapter = new Mock_CustomPriceFeed("ETH", NATIVE_ADDRESS, 2000e8, 8);

        // Set up NAVCalculator
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
        );
        navCalculator = NAVCalculator(navProxy);
        navCalculator.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register assets in NAVCalculator (native is pre-registered in initialize)
        vm.startPrank(manager);
        navCalculator.addPriceFeed(NATIVE_ADDRESS, address(ethAdapter), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(dai), address(daiAdapter), IPrices.PriceType.Custom, type(uint256).max);
        navCalculator.registerAsset(address(weth), address(wethAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        // Create ERC20DefaultBalanceAdapter (it's already created by NAVCalculator, but we can get it)
        adapter = ERC20DefaultBalanceAdapter(navCalculator.erc20DefaultBalanceAdapter());
    }

    function test_constructor() public view {
        assertEq(address(adapter.NAV_CALCULATOR()), address(navCalculator));
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0x12345678));
    }

    function test_underlyingAssetsSupported_returnsAllRegisteredAssets() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
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

    function test_underlyingAssetsSupported_nativeOnlyWhenNoOtherAssets() public {
        // A freshly initialized NAVCalculator has native pre-registered in the default adapter
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
        );
        NAVCalculator emptyNav = NAVCalculator(navProxy);
        vm.stopPrank();

        ERC20DefaultBalanceAdapter emptyAdapter = ERC20DefaultBalanceAdapter(emptyNav.erc20DefaultBalanceAdapter());
        address[] memory assets = emptyAdapter.underlyingAssetsSupported();
        assertEq(assets.length, 1, "Only native is in the default adapter before other assets are registered");
        assertEq(assets[0], NATIVE_ADDRESS);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForUnregisteredAsset() public {
        address user = makeAddr("user");
        address unregisteredAsset = makeAddr("unregistered");

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(user, unregisteredAsset);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAddress() public {
        address user = makeAddr("user");

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(user, address(0));
        assertEq(amount, 0);
    }

    function test_getAdapterBalance_returnsEmptyWhenNoAssets() public {
        address user = makeAddr("user");

        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(user);
        // Should return all registered assets, but with zero balances
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyWhenNoAssets() public {
        address user = makeAddr("user");

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(user, address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_withAssetFilter() public {
        address user = makeAddr("user");

        // Mint some tokens to the user so we have a balance
        usdc.mint(user, 1000e6);

        // Filter by USDC
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(user, address(usdc));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(usdc));
        assertEq(positions[0].balanceAsset.symbol, "USDC");
        assertEq(positions[0].balanceAsset.decimals, 6);
        assertEq(positions[0].balanceAdapter, address(adapter));
    }

    function test_getAdapterPositions_protocolAndPositionDetail() public {
        address user = makeAddr("user");

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(user, address(0));
        assertEq(positions.length, 0); // No balance, so no positions

        // Mint some USDC to the user
        usdc.mint(user, 1000e6);

        positions = adapter.getAdapterPositions(user, address(0));
        assertEq(positions.length, 1);
    }

    // ============================================
    // Inclusion list: addSupportedAsset / removeSupportedAsset
    // ============================================

    function test_addSupportedAsset_onlyNAVCalculatorCanCall() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(OnlyNAVCalculator.selector);
        adapter.addSupportedAsset(address(usdc));
    }

    function test_removeSupportedAsset_onlyNAVCalculatorCanCall() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(OnlyNAVCalculator.selector);
        adapter.removeSupportedAsset(address(usdc));
    }

    function test_removeSupportedAsset_assetDisappearsFromInclusionList() public {
        address user = makeAddr("user");
        usdc.mint(user, 1000e6);

        assertTrue(adapter.isSupportedByDefault(address(usdc)));
        assertEq(adapter.underlyingAssetsSupported().length, 4);

        vm.prank(manager);
        navCalculator.excludeAssetFromDefaultAdapter(address(usdc));

        assertFalse(adapter.isSupportedByDefault(address(usdc)));
        address[] memory supported = adapter.underlyingAssetsSupported();
        assertEq(supported.length, 3);
        for (uint256 i = 0; i < supported.length; i++) {
            assertTrue(supported[i] != address(usdc));
        }
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(user, address(usdc));
        assertEq(amount, 0);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(user, address(usdc));
        assertEq(positions.length, 0);
        positions = adapter.getAdapterPositions(user, address(0));
        assertEq(positions.length, 0);
    }

    function test_includeAssetInDefaultAdapter_assetReappears() public {
        vm.prank(manager);
        navCalculator.excludeAssetFromDefaultAdapter(address(usdc));

        assertFalse(adapter.isSupportedByDefault(address(usdc)));

        vm.prank(manager);
        navCalculator.includeAssetInDefaultAdapter(address(usdc));

        assertTrue(adapter.isSupportedByDefault(address(usdc)));
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 4);
        bool found = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(usdc)) found = true;
        }
        assertTrue(found);

        address user = makeAddr("user");
        usdc.mint(user, 500e6);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(user, address(usdc));
        assertEq(amount, 500e6);
    }

    function test_removeSupportedAsset_idempotent() public {
        vm.startPrank(manager);
        navCalculator.excludeAssetFromDefaultAdapter(address(usdc));
        navCalculator.excludeAssetFromDefaultAdapter(address(usdc));
        vm.stopPrank();
        assertFalse(adapter.isSupportedByDefault(address(usdc)));
    }

    function test_isSupportedByDefault() public view {
        assertTrue(adapter.isSupportedByDefault(address(usdc)));
        assertTrue(adapter.isSupportedByDefault(address(dai)));
        assertTrue(adapter.isSupportedByDefault(NATIVE_ADDRESS));
        assertFalse(adapter.isSupportedByDefault(address(0x1234)));
    }
}
