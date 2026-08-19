// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {Test} from "forge-std/Test.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IComputedLabelSegments} from "src/balances/IComputedLabelSegments.sol";
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
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, vm.deployCode("NAVRegistryLib.sol:NAVRegistryLib").code);

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

    /// @dev Configuration-view probe. The wallet adapter's leaf IS the token symbol, so it is legitimately
    ///      positionId-derived and `positionLabels("")` returns [] — there is no single shape to name. That is
    ///      not a gap: a wallet position's shape set is the registered-asset list, which a configuration view
    ///      already renders, and the adapter is identified as the wallet singleton by `AdapterType.Default`.
    /// @notice This adapter DECLARES that its only segment is computed, and advertises the ERC-165 bit for it.
    /// @dev **The declaration must agree with `BALANCE_ADAPTERS.md` §6.2, which marks this adapter `C` at index 0 and
    ///      says "Never override".** That instruction used to live only in markdown; the mask is the same fact placed
    ///      where `AssetKindRegistry.setAdapterLabels` can enforce it.
    ///
    ///      Both halves are asserted because either alone is useless: without the mask there is nothing to enforce,
    ///      and without the ERC-165 bit the registry's probe never reads the mask — an advertised-but-unreachable
    ///      declaration, which is worse than none because it reads as protection.
    ///
    ///      ⚠️ This adapter is the highest-blast-radius case in the fleet: it is registered on EVERY chain by
    ///      `initialize()`, so one accepted override would freeze a single symbol onto every ERC20 wallet position on
    ///      that chain, rendering as a plausible label rather than an error.
    function test_computedLabelSegments_declaresIndexZeroAndAdvertisesIt() public view {
        assertEq(adapter.computedLabelSegments(), 1, "bit 0 set: the single segment IS the computed token symbol");
        assertTrue(
            adapter.supportsInterface(type(IComputedLabelSegments).interfaceId),
            "without the ERC-165 bit the registry never reads the mask and the guard silently does not apply"
        );
        // The base bits must survive the override.
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_positionLabels_emptyProbe_returnsEmptyForThePerTokenLeaf() public view {
        assertEq(adapter.positionLabels("").length, 0);

        // Against a real positionId the leaf resolves, so [] above is "per-position", not "broken".
        string[] memory labels = adapter.positionLabels(abi.encode(address(usdc)));
        assertEq(labels.length, 1);
        assertEq(labels[0], "USDC");

        string[] memory native = adapter.positionLabels(abi.encode(NATIVE_ADDRESS));
        assertEq(native.length, 1);
        assertEq(native[0], "native");
    }

    /// @dev A malformed positionId degrades to `[]`; it must never revert. `positionLabels` is display-only and
    ///      this is the one adapter registered on all 24 chains, so a configuration view that generalises
    ///      "per-position adapters answer the probe with []" and probes with anything other than exactly `""`
    ///      must still get an answer. Matches the `[]` its `CapStablecoinBalanceAdapter` /
    ///      `CapSavingsBalanceAdapter` / `NexusMutualStakingPoolsAssistedBalanceAdapter` siblings return for the
    ///      same inputs. (Named `CapBalanceAdapter` until that contract was split one-per-leg.)
    ///
    ///      Both halves are load-bearing against the guard, not just against a revert:
    ///        - truncated (1..31 bytes) would revert in `abi.decode` without the `length >= 32` check;
    ///        - the dirty word is `usdc` with its upper 96 bits set. `abi.decode(_, (address))` reverts on it, and
    ///          a "fix" that merely masked to the low 160 bits would answer "USDC" — a wrong label for a
    ///          coordinate this adapter never emitted. Only the `raw >> 160` check yields [].
    ///      The `assertEq(labels[0], "USDC")` tail pins that the guards did not simply blank the whole view.
    function test_positionLabels_malformedPositionId_returnsEmptyRatherThanReverting() public view {
        // Truncated: shorter than one word.
        assertEq(adapter.positionLabels(hex"0102030405060708090a0b0c").length, 0);
        assertEq(adapter.positionLabels(hex"00").length, 0);

        // Full word, dirty upper 96 bits — including one whose low 160 bits ARE a supported asset.
        assertEq(adapter.positionLabels(abi.encode(type(uint256).max)).length, 0);
        uint256 dirtyUsdc = uint256(uint160(address(usdc))) | (uint256(1) << 255);
        assertEq(adapter.positionLabels(abi.encode(dirtyUsdc)).length, 0);

        // ...while the clean word still resolves, so the assertions above are about malformed input, not a
        // permanently empty view.
        string[] memory labels = adapter.positionLabels(abi.encode(address(usdc)));
        assertEq(labels.length, 1);
        assertEq(labels[0], "USDC");
    }

    /// @dev Pins the `== 32` boundary, which is NOT the same guard as "at least a word". `abi.decode` silently
    ///      ignores trailing bytes, so under a `>= 32` guard a foreign multi-word coordinate whose FIRST word is a
    ///      registered asset would be labelled with that asset's symbol — the same over-claim the dirty-word
    ///      rejection exists to prevent, reached through a far more ordinary input (any adapter that encodes a
    ///      `(address, uint256)` pair).
    ///
    ///      Load-bearing: with the guard relaxed to `>= 32` the 64-byte case returns `["USDC"]` and this fails.
    ///      The exactly-32 tail keeps it from passing on a view that rejects everything.
    function test_positionLabels_overlongPositionId_returnsEmpty() public view {
        assertEq(adapter.positionLabels(abi.encode(address(usdc), uint256(42))).length, 0);
        assertEq(adapter.positionLabels(abi.encodePacked(abi.encode(address(usdc)), hex"01")).length, 0);

        assertEq(adapter.positionLabels(abi.encode(address(usdc))).length, 1);
    }
}
