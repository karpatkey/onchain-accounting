// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {MorphoVaultsMetaBalanceAdapter} from "src/balances/protocols/MorphoVaultsMeta.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @notice Plain OZ ERC4626 used as a second "Morpho-shaped" vault over real USDC on the fork.
contract TestUsdcVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Test USDC Vault", "tUSDCv") ERC4626(asset_) {}
}

/// @title MorphoVaultsMetaBalanceAdapter fork tests
/// @notice One meta-adapter serving multiple Morpho ERC4626 vaults, routed through a real NAVCalculator that holds
///         the configured instance set (setMetaInstances). Uses the real kpkUSDC V1 vault + a second ERC4626 over
///         real USDC at a pinned block.
contract MorphoVaultsMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    using Strings for address;

    // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml). Etch its runtime code on the
    // fork so NAVCalculator pricing DELEGATECALLs succeed.
    address constant PRICE_FEED_LIB = 0xf6cb8f59B182B7BdefC6975874419028034f9379;

    IERC4626 public constant KPK_USDC_VAULT = IERC4626(0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    uint256 public constant FORK_BLOCK = 23_641_970;
    address public constant SAFE = 0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    NAVCalculator public nav;
    MorphoVaultsMetaBalanceAdapter public oracle;
    TestUsdcVault public vault2;

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
        // Etch the pre-linked PriceFeedLib so pricing works on the fork.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(PRICE_FEED_LIB, priceFeedLibImpl.code);

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

        // Register USDC with a (non-stale) custom price feed of $1.
        Mock_CustomPriceFeed usdcFeed = new Mock_CustomPriceFeed("USDC", address(USDC), 1e8, 8);
        vm.prank(manager);
        nav.registerAsset(address(USDC), address(usdcFeed), IPrices.PriceType.Custom, type(uint256).max);

        // Second ERC4626 over real USDC; deposit on behalf of SAFE so it holds a non-zero position.
        vault2 = new TestUsdcVault(USDC);
        deal(address(USDC), SAFE, 2_000e6);
        vm.startPrank(SAFE);
        USDC.approve(address(vault2), 2_000e6);
        vault2.deposit(2_000e6, SAFE);
        vm.stopPrank();

        // Deploy the meta-adapter and register it on NAV with both vaults as instances.
        oracle = new MorphoVaultsMetaBalanceAdapter("Morpho", address(nav));
        vm.startPrank(manager);
        nav.addBalanceOracle(address(oracle));
        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(KPK_USDC_VAULT))));
        instances[1] = bytes32(uint256(uint160(address(vault2))));
        nav.setMetaInstances(address(oracle), instances);
        vm.stopPrank();
    }

    function test_metaInstances_registered() public view {
        assertEq(nav.getMetaInstances(address(oracle)).length, 2);
    }

    function test_adapterDirect_aggregatesBothVaults() public view {
        bytes32[] memory instances = nav.getMetaInstances(address(oracle));
        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(SAFE, instances, address(0));

        assertEq(pos.length, 2, "two USDC positions from one adapter");
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].underlyingAsset.asset, address(USDC));
            assertEq(pos[i].balanceOracle, address(oracle));
            assertEq(pos[i].protocol, "Morpho");
            assertFalse(pos[i].isDebt);
            assertGt(pos[i].amount, 0);
        }
        // Identity derived on-chain from the instance coordinate.
        assertEq(pos[0].positionId, address(KPK_USDC_VAULT).toHexString());
        assertEq(pos[1].positionId, address(vault2).toHexString());
    }

    function test_navRouting_aggregatesViaMetaOracle() public view {
        INAVCalculator.PositionBalance[] memory expected =
            oracle.getOraclePositionsForInstances(SAFE, nav.getMetaInstances(address(oracle)), address(0));

        // NAVCalculator should route through the meta interface and surface both positions, attributed to the adapter.
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(SAFE, address(0));

        uint256 metaCount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceOracle == address(oracle)) metaCount++;
        }
        assertEq(metaCount, expected.length, "NAV surfaces every meta-adapter position");
        assertEq(metaCount, 2);

        INAVCalculator.NAV memory snapshot = nav.getAccountNav(SAFE, address(0));
        assertGt(snapshot.value, 0, "NAV positive with two USDC vault positions");
    }

    function test_adapterDirect_matchesRedemption_realVault() public {
        // Cross-check the real Morpho vault leg against an actual redemption (mutating; isolated per test).
        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(uint160(address(KPK_USDC_VAULT))));
        INAVCalculator.PositionBalance[] memory pos = oracle.getOraclePositionsForInstances(SAFE, one, address(0));
        assertEq(pos.length, 1);

        uint256 shares = KPK_USDC_VAULT.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE holds kpkUSDC shares at fork block");
        uint256 before = USDC.balanceOf(SAFE);
        vm.prank(SAFE);
        KPK_USDC_VAULT.redeem(shares, SAFE, SAFE);
        uint256 redeemed = USDC.balanceOf(SAFE) - before;

        assertEq(pos[0].amount, redeemed, "adapter amount equals redeemable USDC");
    }

    function test_assetFilter_usdc() public view {
        bytes32[] memory instances = nav.getMetaInstances(address(oracle));
        INAVCalculator.PositionBalance[] memory pos =
            oracle.getOraclePositionsForInstances(SAFE, instances, address(USDC));
        assertEq(pos.length, 2);

        INAVCalculator.PositionBalance[] memory none =
            oracle.getOraclePositionsForInstances(SAFE, instances, address(0xdead));
        assertEq(none.length, 0);
    }
}
