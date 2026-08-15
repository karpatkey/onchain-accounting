// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;
import {LibraryPins} from "script/utils/LibraryPins.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    SymbioticVaultsMetaBalanceAdapter
} from "src/balances/MetaBalanceAdapters/SymbioticVaultsMetaBalanceAdapter.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

interface ISymbioticRegistry {
    function isEntity(address entity) external view returns (bool);
    function totalEntities() external view returns (uint256);
}

/// @notice Symbiotic's `Entity` base: the factory that cloned it, set immutable at clone time.
interface ISymbioticEntity {
    function FACTORY() external view returns (address);
}

interface IHasVault {
    function vault() external view returns (address);
}

interface IHasDelegator {
    function delegator() external view returns (address);
}
import {PositionKind} from "src/utils/PositionKind.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title SymbioticVaultsMetaBalanceAdapter fork tests
/// @notice Exercises the adapter against the REAL `KPK USDC LiquidLane` Symbiotic vault and the REAL KPK
///         Safe position at a pinned block, routed through a real NAVCalculator.
contract SymbioticVaultsMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    address constant PRICE_FEED_LIB = LibraryPins.PRICE_FEED_LIB;

    /// @dev `KPK USDC LiquidLane` (`KPK_USDC_LL`) — ERC-4626 over USDC, 18-decimal shares.
    IERC4626 public constant LIQUID_LANE = IERC4626(0x8BcD746976885b5832bAD07B4921E3f2dD1D3703);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    /// @dev The KPK Safe — a real holder of this vault at the pinned block.
    address public constant SAFE = 0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7;
    uint256 public constant FORK_BLOCK = 25_760_274;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    NAVCalculator public nav;
    SymbioticVaultsMetaBalanceAdapter public adapter;

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
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(PRICE_FEED_LIB, priceFeedLibImpl.code);
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

        Mock_CustomPriceFeed usdcFeed = new Mock_CustomPriceFeed("USDC", address(USDC), 1e8, 8);
        vm.prank(manager);
        nav.registerAsset(address(USDC), address(usdcFeed), IPrices.PriceType.Custom, type(uint256).max);

        adapter = new SymbioticVaultsMetaBalanceAdapter(address(nav));
        vm.startPrank(manager);
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(uint160(address(LIQUID_LANE))));
        nav.addMetaBalanceAdapter(address(adapter), instances);
        vm.stopPrank();
    }

    /// @dev Symbiotic's mainnet VaultFactory — canonical, and confirmed independently: the
    ///      VaultConfigurator `0x29300b1d3150B4E2b12fE80BE72f365E200441EC` reports this as `VAULT_FACTORY()`.
    address constant SYMBIOTIC_VAULT_FACTORY = 0xAEb6bdd95c502390db8f52c8909F703E9Af6a346;
    /// @dev **One of TWO** Symbiotic DelegatorFactories — the one that minted THIS vault's delegator (24
    ///      delegators). The VaultConfigurator-paired factory is `0x985Ed57AF9D475f1d83c1c1c8826A0E5A34E8C7B`
    ///      (333). 333 + 24 == 357 == VaultFactory.totalEntities(), and all share one owner. So this is NOT
    ///      "the canonical" delegator factory, and a Symbiotic vault delegated through the other one is
    ///      equally valid — which is why the assertions below bind through each entity's own `FACTORY()`
    ///      immutable rather than assuming a single registry.
    address constant SYMBIOTIC_DELEGATOR_FACTORY = 0xB5eFf01403C0dD3aDa1010919791d6EB82F6a84C;

    /// @dev **The POSITIVE evidence that this is a Symbiotic vault at all.** Review correctly objected
    ///      that "core-vault methods revert" only establishes what the vault is NOT — it ties nothing to
    ///      Symbiotic. This does: the vault is a registered entity of Symbiotic's VaultFactory, and its
    ///      `delegator()` is a registered entity of the paired DelegatorFactory, which points back at the
    ///      vault. If that ever ceases to hold, stamping `symbiotic` / `symbiotic-vaults` identity on this
    ///      instance is no longer justified and this test says so.
    function test_premise_vaultIsRegisteredInSymbioticFactory() public view {
        // Bind through the FACTORY() IMMUTABLE, set by the factory at clone time. This is strictly
        // stronger than `isEntity` — it binds from the entity outward, so it cannot be satisfied by a
        // lookalike registry that merely lists the address.
        assertEq(
            ISymbioticEntity(address(LIQUID_LANE)).FACTORY(),
            SYMBIOTIC_VAULT_FACTORY,
            "vault was cloned by Symbiotic's VaultFactory"
        );
        assertTrue(
            ISymbioticRegistry(SYMBIOTIC_VAULT_FACTORY).isEntity(address(LIQUID_LANE)),
            "and the factory lists it (both directions)"
        );

        address delegator = IHasDelegator(address(LIQUID_LANE)).delegator();
        assertEq(
            ISymbioticEntity(delegator).FACTORY(),
            SYMBIOTIC_DELEGATOR_FACTORY,
            "delegator was cloned by a Symbiotic DelegatorFactory"
        );
        // The adapter's docstring cites this back-pointer as part of the evidence; assert it rather than
        // just claiming it.
        assertEq(IHasVault(delegator).vault(), address(LIQUID_LANE), "delegator points back at the vault");

        assertGt(ISymbioticRegistry(SYMBIOTIC_VAULT_FACTORY).totalEntities(), 1, "a real registry, not a stub");
    }

    /// @dev Premise check: the vault really is a synchronous ERC-4626, not a Symbiotic CORE vault.
    ///      If this ever fails, the single-`Supplied`-leg model in the adapter is no longer valid.
    function test_premise_vaultIsSynchronousErc4626() public view {
        assertEq(LIQUID_LANE.asset(), address(USDC), "asset is USDC");
        uint256 shares = LIQUID_LANE.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE holds LiquidLane shares at the pinned block");
        assertEq(LIQUID_LANE.maxRedeem(SAFE), shares, "maxRedeem == balanceOf: fully, synchronously redeemable");
    }

    function test_metaInstances_registered() public view {
        assertEq(nav.getMetaInstances(address(adapter)).length, 1);
    }

    /// @dev In-EVM ground truth: the reported amount is exactly `previewRedeem(balanceOf)`.
    function test_adapterDirect_matchesPreviewRedeem() public view {
        bytes32[] memory instances = nav.getMetaInstances(address(adapter));
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(SAFE, instances, address(0));

        assertEq(pos.length, 1, "one Supplied leg");
        assertEq(pos[0].balanceAsset.asset, address(USDC));
        assertEq(pos[0].balanceAdapter, address(adapter), "balanceAdapter is address(this)");
        assertFalse(pos[0].isDebt);
        assertEq(pos[0].amount, LIQUID_LANE.previewRedeem(LIQUID_LANE.balanceOf(SAFE)), "amount == previewRedeem");
        assertGt(pos[0].amount, 0);
        assertEq(pos[0].positionId, abi.encode(address(LIQUID_LANE)));
    }

    /// @dev Identity must be Symbiotic on a real position, not just in the unit mocks.
    function test_identity_onRealPosition() public view {
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(SAFE, nav.getMetaInstances(address(adapter)), address(0));
        assertEq(pos[0].protocolBrand, ProtocolIds.SYMBIOTIC);
        assertEq(pos[0].protocolId, ProtocolIds.SYMBIOTIC);
        assertEq(pos[0].protocolSubId, ProtocolIds.SYMBIOTIC_VAULTS);
        assertEq(uint8(pos[0].positionKind), uint8(PositionKind.Supplied));
    }

    function test_navRouting_surfacesThePosition() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(SAFE, address(0));
        uint256 metaCount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAdapter == address(adapter)) metaCount++;
        }
        assertEq(metaCount, 1, "NAV surfaces the meta-adapter position");

        INAVCalculator.NAV memory snapshot = nav.getAccountNav(SAFE, address(0));
        assertGt(snapshot.value, 0, "NAV positive with the LiquidLane position");
    }

    /// @dev Cross-check the reported amount against an ACTUAL redemption on the fork — the strongest
    ///      available evidence that `previewRedeem` is the right accessor for this vault (mutating).
    function test_reportedAmountMatchesActualRedemption() public {
        bytes32[] memory instances = nav.getMetaInstances(address(adapter));
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(SAFE, instances, address(0));
        uint256 reported = pos[0].amount;

        uint256 shares = LIQUID_LANE.balanceOf(SAFE);
        uint256 before = USDC.balanceOf(SAFE);
        vm.prank(SAFE);
        LIQUID_LANE.redeem(shares, SAFE, SAFE);
        uint256 received = USDC.balanceOf(SAFE) - before;

        assertEq(received, reported, "adapter reported exactly what redemption paid out");
    }

    function test_underlyingAssetsForInstances() public view {
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(nav.getMetaInstances(address(adapter)));
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDC));
    }

    function test_positionLabels_realVaultName() public view {
        string[] memory labels = adapter.positionLabels(abi.encode(address(LIQUID_LANE)));
        assertEq(labels.length, 2, "category + vault name");
        assertEq(labels[0], "Vault");
        assertEq(labels[1], "KPK USDC LiquidLane", "on-chain ERC4626 name()");
    }
}
