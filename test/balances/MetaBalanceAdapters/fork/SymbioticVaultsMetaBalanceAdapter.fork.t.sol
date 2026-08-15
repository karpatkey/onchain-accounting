// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
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
