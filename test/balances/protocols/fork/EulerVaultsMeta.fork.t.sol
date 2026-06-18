// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {EulerVaultsMetaBalanceAdapter, IEulerEVaultDebt} from "src/balances/protocols/EulerVaultsMeta.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";

/// @title EulerVaultsMetaBalanceAdapter fork tests
/// @notice One immutable meta-adapter serving every Euler V2 eVault (supply leg, ERC4626 convertToAssets), routed
///         through a real NAVCalculator that holds the configured instance set (seeded via addMetaBalanceAdapter).
///         Uses the two kpk-curated eVaults at a pinned block: KPK_ETH_Term (WETH, with its real holder the KPK DAO
///         Safe) and kpk_RWA_USDC (USDC, with a position deposited in setUp).
contract EulerVaultsMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    // External libraries pre-linked at deterministic CREATE2 addresses (foundry.toml). Etch their runtime on the fork
    // so NAVCalculator's pricing/registry DELEGATECALLs succeed.
    address constant PRICE_FEED_LIB = 0x6F0C6f68728Ec474FecB4DE7cdd72E28C2D42715;
    address constant NAV_REGISTRY_LIB = 0x02F27E28452E6F419b97935f6346381E2b5003B1;

    // kpk-curated Euler V2 eVaults (ERC4626 EVK vaults) on mainnet.
    IERC4626 public constant KPK_ETH_TERM = IERC4626(0xB6D6D89ad4b4D61C15a293e28b74f77F6817fF48); // WETH
    IERC4626 public constant KPK_RWA_USDC = IERC4626(0x2B47c128b35DDDcB66Ce2FA5B33c95314a7de245); // USDC
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // KPK DAO Safe — the dominant holder of KPK_ETH_Term (269.79 / 269.84 total shares at the fork block).
    address public constant SAFE = 0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C;
    // KPK Foundation Safe — the dominant holder of kpk_RWA_USDC (~1,000,000 of ~1,005,018 total shares).
    address public constant USDC_HOLDER = 0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7;

    // A real Euler V2 borrower at the fork block: supplies USDC collateral in eUSDC-2 and borrows WETH from eWETH-2
    // (both are core EVK eVaults — the underlying strategies KPK_ETH_Term itself allocates to). Used to exercise the
    // borrow (debt) leg + the earn/lend/borrow combination on a single account.
    address public constant BORROWER = 0x5c950F946F02F3AcBa1F9e68A3CCDb7DD148e820;
    IERC4626 public constant E_USDC2 = IERC4626(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9); // core eVault, USDC
    IERC4626 public constant E_WETH2 = IERC4626(0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2); // core eVault, WETH

    uint256 public constant FORK_BLOCK = 25_346_929;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    NAVCalculator public nav;
    EulerVaultsMetaBalanceAdapter public adapter;

    function setUp() public override {
        _setupFork();
        _setupNav();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupNav() internal {
        // Etch the pre-linked external libraries so NAVCalculator works on the fork.
        vm.etch(PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(NAV_REGISTRY_LIB, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);

        // Real NAVCalculator (L1: no sequencer uptime feed).
        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
            )
        );
        nav.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Register the underlyings with (non-stale) custom price feeds.
        Mock_CustomPriceFeed wethFeed = new Mock_CustomPriceFeed("WETH", address(WETH), 2500e8, 8);
        Mock_CustomPriceFeed usdcFeed = new Mock_CustomPriceFeed("USDC", address(USDC), 1e8, 8);
        Mock_CustomPriceFeed ethFeed = new Mock_CustomPriceFeed("ETH", NATIVE_ADDRESS, 2500e8, 8);
        vm.startPrank(manager);
        nav.registerAsset(address(WETH), address(wethFeed), IPrices.PriceType.Custom, type(uint256).max);
        nav.registerAsset(address(USDC), address(usdcFeed), IPrices.PriceType.Custom, type(uint256).max);
        // NATIVE_ADDRESS is pre-registered (feedless) by initialize(); SAFE holds native ETH, so attach a feed via
        // addPriceFeed (registerAsset would revert on the already-registered native asset) to keep getAccountNav whole.
        nav.addPriceFeed(NATIVE_ADDRESS, address(ethFeed), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        // Give SAFE a position in the real kpk_RWA_USDC eVault so the USDC instance is non-zero too.
        deal(address(USDC), SAFE, 2_000e6);
        vm.startPrank(SAFE);
        USDC.approve(address(KPK_RWA_USDC), 2_000e6);
        KPK_RWA_USDC.deposit(2_000e6, SAFE);
        vm.stopPrank();

        // Deploy the meta-adapter and register it on NAV with both eVaults as instances.
        adapter = new EulerVaultsMetaBalanceAdapter("Euler", address(nav));
        vm.startPrank(manager);
        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(KPK_ETH_TERM))));
        instances[1] = bytes32(uint256(uint160(address(KPK_RWA_USDC))));
        nav.addMetaBalanceAdapter(address(adapter), instances);
        vm.stopPrank();
    }

    function test_metaInstances_registered() public view {
        assertEq(nav.getMetaInstances(address(adapter)).length, 2);
    }

    function test_adapterDirect_aggregatesBothVaults() public view {
        bytes32[] memory instances = nav.getMetaInstances(address(adapter));
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(SAFE, instances, address(0));

        assertEq(pos.length, 2, "two supply positions from one adapter");
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAdapter, address(adapter));
            assertFalse(pos[i].isDebt, "supply leg only, never debt");
            assertGt(pos[i].amount, 0);
            assertEq(pos[i].protocolId, ProtocolIds.EULER_VAULTS);
            assertTrue(pos[i].positionKind == PositionKind.Supplied);
        }
        // WETH leg (KPK_ETH_Term) then USDC leg (kpk_RWA_USDC); identity derived on-chain from the instance coord.
        assertEq(pos[0].balanceAsset.asset, address(WETH));
        assertEq(pos[0].positionId, abi.encode(address(KPK_ETH_TERM)));
        assertEq(pos[1].balanceAsset.asset, address(USDC));
        assertEq(pos[1].positionId, abi.encode(address(KPK_RWA_USDC)));
    }

    function test_navRouting_aggregatesViaMetaAdapter() public view {
        INAVCalculator.PositionBalance[] memory expected =
            adapter.getAdapterPositionsForInstances(SAFE, nav.getMetaInstances(address(adapter)), address(0));

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(SAFE, address(0));

        uint256 metaCount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAdapter == address(adapter)) metaCount++;
        }
        assertEq(metaCount, expected.length, "NAV surfaces every meta-adapter position");
        assertEq(metaCount, 2);

        INAVCalculator.NAV memory snapshot = nav.getAccountNav(SAFE, address(0));
        assertGt(snapshot.value, 0, "NAV positive with the two Euler eVault positions");
    }

    /// @notice Strict-equality cross-check against real on-chain redemption. The eVault lends deposits out, so only
    ///         `maxRedeem` shares are instantly redeemable (~30 of ~270 WETH at this block) — the adapter correctly
    ///         reports the FULL position value (convertToAssets of all shares, the NAV semantics), so we verify both:
    ///         (a) the adapter amount equals convertToAssets(all shares), and (b) convertToAssets is faithful to real
    ///         money by redeeming the available portion and matching the realized WETH exactly. Mutating; isolated.
    function test_adapterDirect_matchesRedemption_realEthTerm() public {
        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(uint160(address(KPK_ETH_TERM))));
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(SAFE, one, address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].balanceAsset.asset, address(WETH));

        uint256 shares = KPK_ETH_TERM.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE holds KPK_ETH_Term shares at fork block");
        // (a) adapter reports the full position value.
        assertEq(pos[0].amount, KPK_ETH_TERM.convertToAssets(shares), "adapter amount == convertToAssets(all shares)");

        // (b) redeem the cash-available portion and match the realized WETH to the same per-share conversion.
        uint256 redeemable = KPK_ETH_TERM.maxRedeem(SAFE);
        assertGt(redeemable, 0, "some shares are instantly redeemable");
        uint256 expected = KPK_ETH_TERM.convertToAssets(redeemable);
        uint256 before = WETH.balanceOf(SAFE);
        vm.prank(SAFE);
        KPK_ETH_TERM.redeem(redeemable, SAFE, SAFE);
        uint256 redeemed = WETH.balanceOf(SAFE) - before;

        assertEq(redeemed, expected, "realized WETH == convertToAssets(redeemed shares)");
    }

    function test_assetFilter() public view {
        bytes32[] memory instances = nav.getMetaInstances(address(adapter));

        INAVCalculator.PositionBalance[] memory wethOnly =
            adapter.getAdapterPositionsForInstances(SAFE, instances, address(WETH));
        assertEq(wethOnly.length, 1);
        assertEq(wethOnly[0].balanceAsset.asset, address(WETH));

        INAVCalculator.PositionBalance[] memory none =
            adapter.getAdapterPositionsForInstances(SAFE, instances, address(0xdead));
        assertEq(none.length, 0);
    }

    function test_describePosition_realVaultName() public view {
        assertEq(adapter.describePosition(abi.encode(address(KPK_ETH_TERM))), "KPK ETH Yield Term");
    }

    /// @notice Real account exercising all three Euler shapes in one query: an **earn** leg (EulerEarn KPK_ETH_Term,
    ///         seeded with a deposit), a **lend** leg (real USDC collateral in core eVault eUSDC-2), and a **borrow**
    ///         leg (real WETH debt in core eVault eWETH-2). Proves the adapter emits a Supplied leg + a Borrowed
    ///         (isDebt) leg, each strict-equal to the on-chain `convertToAssets` / `debtOf`.
    function test_realBorrower_earnLendBorrow() public {
        // Seed an EulerEarn (earn) position so the same real borrower also shows the aggregator leg.
        deal(address(WETH), BORROWER, 5e18);
        vm.startPrank(BORROWER);
        WETH.approve(address(KPK_ETH_TERM), 5e18);
        KPK_ETH_TERM.deposit(5e18, BORROWER);
        vm.stopPrank();

        bytes32[] memory ins = new bytes32[](3);
        ins[0] = bytes32(uint256(uint160(address(KPK_ETH_TERM)))); // earn  (EulerEarn, WETH)
        ins[1] = bytes32(uint256(uint160(address(E_USDC2)))); // lend  (core eVault, USDC collateral)
        ins[2] = bytes32(uint256(uint160(address(E_WETH2)))); // borrow(core eVault, WETH debt)

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(BORROWER, ins, address(0));

        uint256 earn;
        uint256 lend;
        uint256 borrow;
        bool fe;
        bool fl;
        bool fb;
        for (uint256 i = 0; i < pos.length; i++) {
            bytes32 id = keccak256(pos[i].positionId);
            if (id == keccak256(abi.encode(address(KPK_ETH_TERM))) && !pos[i].isDebt) {
                earn = pos[i].amount;
                fe = true;
                assertEq(pos[i].balanceAsset.asset, address(WETH));
                assertTrue(pos[i].positionKind == PositionKind.Supplied);
            } else if (id == keccak256(abi.encode(address(E_USDC2))) && !pos[i].isDebt) {
                lend = pos[i].amount;
                fl = true;
                assertEq(pos[i].balanceAsset.asset, address(USDC));
                assertTrue(pos[i].positionKind == PositionKind.Supplied);
            } else if (id == keccak256(abi.encode(address(E_WETH2))) && pos[i].isDebt) {
                borrow = pos[i].amount;
                fb = true;
                assertEq(pos[i].balanceAsset.asset, address(WETH));
                assertTrue(pos[i].positionKind == PositionKind.Borrowed);
            }
        }
        assertTrue(fe && fl && fb, "earn + lend + borrow legs all present");

        // Strict equality vs on-chain.
        assertEq(earn, KPK_ETH_TERM.convertToAssets(KPK_ETH_TERM.balanceOf(BORROWER)), "earn == convertToAssets");
        assertEq(lend, E_USDC2.convertToAssets(E_USDC2.balanceOf(BORROWER)), "lend == convertToAssets");
        assertEq(borrow, IEulerEVaultDebt(address(E_WETH2)).debtOf(BORROWER), "borrow == debtOf");
        assertGt(borrow, 0, "real debt present");
    }

    /// @notice NAV signs the borrow leg negative: routing the core eVaults through NAV, the WETH-filtered positions
    ///         include the eWETH-2 debt as a negative-value entry attributed to the adapter.
    function test_navNetsEulerDebt() public {
        vm.startPrank(manager);
        bytes32[] memory add = new bytes32[](2);
        add[0] = bytes32(uint256(uint160(address(E_USDC2))));
        add[1] = bytes32(uint256(uint160(address(E_WETH2))));
        nav.addMetaInstances(address(adapter), add);
        vm.stopPrank();

        INAVCalculator.Position[] memory wethPos = nav.getAccountPositionsForAsset(BORROWER, address(WETH), address(0));
        bool foundDebt;
        for (uint256 i = 0; i < wethPos.length; i++) {
            if (wethPos[i].balanceAdapter == address(adapter) && wethPos[i].isDebt) {
                foundDebt = true;
                assertLt(wethPos[i].value, 0, "Euler debt leg prices to a negative value");
            }
        }
        assertTrue(foundDebt, "NAV surfaces the Euler borrow leg as signed debt");
    }

    /// @notice Real-holder check for the USDC instance: KPK Foundation's actual kpk_RWA_USDC position is reported as a
    ///         USDC supply leg equal to convertToAssets(its shares). Complements the synthetic SAFE deposit so both
    ///         configured eVaults are verified against a real on-chain holder.
    function test_realUsdcHolder_kpkFoundation() public view {
        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(uint160(address(KPK_RWA_USDC))));
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(USDC_HOLDER, one, address(0));

        assertEq(pos.length, 1, "KPK Foundation holds a kpk_RWA_USDC position");
        assertEq(pos[0].balanceAsset.asset, address(USDC));
        assertEq(pos[0].positionId, abi.encode(address(KPK_RWA_USDC)));
        assertTrue(pos[0].positionKind == PositionKind.Supplied);
        assertFalse(pos[0].isDebt);
        assertEq(
            pos[0].amount,
            KPK_RWA_USDC.convertToAssets(KPK_RWA_USDC.balanceOf(USDC_HOLDER)),
            "amount == convertToAssets(real holder shares)"
        );
        assertGt(pos[0].amount, 0);
    }
}
