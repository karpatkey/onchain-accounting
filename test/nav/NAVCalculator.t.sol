// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "test/SuperTest.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract NAVCalculatorHarness is NAVCalculator {
    constructor(address admin, address safe, address chainlinkUptimeFeed) {
        NAVCalculator.initialize(admin, safe, chainlinkUptimeFeed);
    }
}

contract NAVCalculatorTest is SuperTest {
    Mock_PriceOracleChainlink public chainlinkOracle;

    Mock_CustomBalanceOracle public depositedWethOracle;

    function setUp() public {
        setupAll();
        chainlinkOracle = new Mock_PriceOracleChainlink("Chainlink Oracle", 1, 8);
    }

    function test_setUp() public {
        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, 86_400);
        vm.stopPrank();

        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        address[] memory assets = nav.assets();
        assertEq(assets.length, 4);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(dai));
        assertEq(assets[2], address(weth));
        assertEq(assets[3], nav.NATIVE_ADDRESS());

        (address address_, uint8 decimals, uint256 chainlinkHeartbeat_, IPrices.PriceType priceType_) =
            nav.priceOracles(address(usdc));
        assertEq(address_, address(usdcOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, type(uint256).max);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Custom));

        (address_, decimals, chainlinkHeartbeat_, priceType_) = nav.priceOracles(address(dai));
        assertEq(address_, address(daiOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, 86_400);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Chainlink));

        (address_, decimals, chainlinkHeartbeat_, priceType_) = nav.priceOracles(address(weth));
        assertEq(address_, address(wethOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, type(uint256).max);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Custom));

        (address_, decimals, chainlinkHeartbeat_, priceType_) = nav.priceOracles(nav.NATIVE_ADDRESS());
        assertEq(address_, address(ethOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, 86_400);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Chainlink));

        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(usdc), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        nav.addBalance(address(dai), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        nav.addBalance(address(weth), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        address[] memory balanceOracles = nav.balanceOracles(address(usdc));
        assertEq(balanceOracles.length, 2);
        assertEq(balanceOracles[0], address(usdc));
        assertEq(balanceOracles[1], address(mockBalanceOracle));

        balanceOracles = nav.balanceOracles(address(dai));
        assertEq(balanceOracles.length, 2);
        assertEq(balanceOracles[0], address(dai));
        assertEq(balanceOracles[1], address(mockBalanceOracle));

        balanceOracles = nav.balanceOracles(address(weth));
        assertEq(balanceOracles.length, 2);
        assertEq(balanceOracles[0], address(weth));
        assertEq(balanceOracles[1], address(mockBalanceOracle));

        balanceOracles = nav.balanceOracles(nav.NATIVE_ADDRESS());
        assertEq(balanceOracles.length, 1);
        assertEq(balanceOracles[0], nav.NATIVE_ADDRESS());

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 3600);
        assertEq(nav.assetRecoverer(), safe);
    }

    function test_addBalance() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();
    }

    function test_addBalance_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();
    }

    function test_addPrice() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addPrice_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addBalance_withoutPrice() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.prank(navCalculatorManager);
        vm.expectRevert(INAVCalculator.AssetNotFound.selector);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
    }

    function test_removeBalance_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        nav.removeBalance(address(usdc), address(usdc));
        vm.stopPrank();
    }

    function test_removeBalance_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.removeBalance(address(usdc), address(usdc));
        vm.stopPrank();
    }

    function test_removePrice_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);

        nav.removePrice(address(usdc));
        vm.stopPrank();
    }

    function test_removePrice_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.removePrice(address(usdc));
        vm.stopPrank();
    }

    function test_read() public {
        vm.roll(1);

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.block, 1);

        assertEq(r.issues, 0);
        assertEq(r.usd, 0);

        vm.roll(2);
        r = nav.read(safe);
        assertEq(r.block, 2);
        assertEq(r.issues, 0);
        assertEq(r.usd, 0);
    }

    function test_read_usdc() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 1e8);
        assertEq(r.issues, 0);

        INAVCalculator.Position memory p = nav.readPosition(safe, address(usdc), 0);
        assertEq(p.underlyingAsset, address(usdc));
        assertEq(p.balance, int256(10 ** usdc.decimals()));
        assertEq(p.usd, 1e8);
        assertEq(p.usdRate, 1e8);
        assertEq(p.usdRateDecimals, 8);
        assertEq(p.bridging, false);
        assertEq(p.stale, false);
    }

    function test_read_eth() public {
        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max);
        vm.stopPrank();

        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 3_564_627_000_000);
        assertEq(r.issues, 0);

        INAVCalculator.Position memory p = nav.readPosition(safe, nav.NATIVE_ADDRESS(), 0);
        assertEq(p.underlyingAsset, nav.NATIVE_ADDRESS());
        assertEq(p.balance, int256(11 ether));
        assertEq(p.usd, 3_564_627_000_000);
        assertEq(p.usdRate, 324_057_000_000);
        assertEq(p.usdRateDecimals, 8);
        assertEq(p.bridging, false);
        assertEq(p.stale, false);
    }

    function test_read_eth_with_metadata() public {
        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max);
        vm.stopPrank();
        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 3_564_627_000_000);
        assertEq(r.issues, 0);

        INAVCalculator.PositionWithMetadata memory p = nav.readPositionWithMetadata(safe, nav.NATIVE_ADDRESS(), 0);
        assertEq(p.protocol, "Portfolio balance");
        assertEq(p.position, "ETH");
        assertEq(p.positionType, "Native");
        assertEq(p.underlyingAssetSymbol, "ETH");
        assertEq(p.underlyingAssetDecimals, 18);
        assertEq(p.underlyingAsset, nav.NATIVE_ADDRESS());
        assertEq(p.usdRate, 324_057_000_000);
        assertEq(p.usdRateDecimals, 8);
        assertEq(p.bridging, false);
        assertEq(p.balance, int256(11e18));
        assertEq(p.usd, 3_564_627_000_000);
        assertEq(p.stale, false);
    }

    function test_read_usdc_ERC20_with_metadata() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 1e8);
        assertEq(r.issues, 0);

        INAVCalculator.PositionWithMetadata memory p = nav.readPositionWithMetadata(safe, address(usdc), 0);
        assertEq(p.protocol, "Portfolio balance");
        assertEq(p.position, "USDC");
        assertEq(p.positionType, "ERC20");
        assertEq(p.underlyingAssetSymbol, "USDC");
        assertEq(p.underlyingAssetDecimals, usdc.decimals());
        assertEq(p.underlyingAsset, address(usdc));
        assertEq(p.usdRate, 1e8);
        assertEq(p.usdRateDecimals, 8);
        assertEq(p.bridging, false);
        assertEq(p.balance, int256(10 ** usdc.decimals()));
        assertEq(p.usd, 1e8);
        assertEq(p.stale, false);
    }

    function test_read_usdc_with_metadata_customOracle() public {
        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(usdc), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        INAVCalculator.PositionWithMetadata memory p = nav.readPositionWithMetadata(safe, address(usdc), 1);
        assertEq(p.protocol, "Mock Protocol");
        assertEq(p.position, "Mock Position");
        assertEq(p.positionType, "Mock Type");
        assertEq(p.underlyingAssetSymbol, "USDC");
        assertEq(p.underlyingAssetDecimals, usdc.decimals());
        assertEq(p.underlyingAsset, address(usdc));
        assertEq(p.usdRate, 1e8);
        assertEq(p.usdRateDecimals, 8);
        assertEq(p.bridging, false);
        assertEq(p.balance, int256(123 * 10 ** usdc.decimals()));
        assertEq(p.usd, 123e8);
        assertEq(p.stale, false);
    }

    function test_read_dai() public {
        dai.mint(safe, 10 ** dai.decimals());
        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 100_000_000);
        assertEq(r.issues, 0);

        INAVCalculator.Position memory p = nav.readPosition(safe, address(dai), 0);
        assertEq(p.usd, 1e8);
        assertEq(p.balance, int256(10 ** dai.decimals()));
        assertEq(p.underlyingAsset, address(dai));
        assertEq(p.bridging, false);
        assertEq(p.stale, false);

        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(dai), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        INAVCalculator.NAV memory r_2 = nav.read(safe);
        assertEq(r_2.usd, 45_700_000_000);
        assertEq(r_2.issues, 0);

        INAVCalculator.Position memory p_2 = nav.readPosition(safe, address(dai), 1);
        assertEq(p_2.usd, 45_600_000_000);
        assertEq(p_2.balance, int256(456 * 10 ** dai.decimals()));
        assertEq(p_2.underlyingAsset, address(dai));
        assertEq(p_2.bridging, false);
        assertEq(p_2.stale, false);
    }

    function test_read_dai_bridging() public {
        vm.prank(ops);
        nav.bridgeStart(address(dai));

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.issues, 1);

        INAVCalculator.Position memory p = nav.readPosition(safe, address(dai), 0);
        assertEq(p.bridging, true);
    }

    function test_read_weth() public {
        weth.mint(safe, 10 ** weth.decimals());
        INAVCalculator.NAV memory r = nav.read(safe);
        assertApproxEqRel(r.usd, 3240 * 1e8, 0.01 ether);
        assertEq(r.issues, 0);

        INAVCalculator.Position memory p = nav.readPosition(safe, address(weth), 0);
        assertApproxEqRel(p.usd, 3240 * 1e8, 0.01 ether);
        assertEq(p.balance, int256(10 ** weth.decimals()));
        assertEq(p.underlyingAsset, address(weth));
        assertEq(p.bridging, false);
        assertEq(p.stale, false);
    }

    function test_read_multiple() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());
        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 2 * 1e8);
        assertEq(r.issues, 0);

        INAVCalculator.Position memory p1 = nav.readPosition(safe, address(usdc), 0);
        assertEq(p1.underlyingAsset, address(usdc));
        assertEq(p1.usd, 1e8);
        assertEq(p1.balance, int256(10 ** usdc.decimals()));

        INAVCalculator.Position memory p2 = nav.readPosition(safe, address(dai), 0);
        assertEq(p2.underlyingAsset, address(dai));
        assertEq(p2.usd, 1e8);
        assertEq(p2.balance, int256(10 ** dai.decimals()));
    }

    function test_read_sequencerDown() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeedDown));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 1e8);
        assertEq(r.issues, 1);

        INAVCalculator.Position memory p = nav.readPosition(safe, address(usdc), 0);
        assertEq(p.underlyingAsset, address(usdc));
        assertEq(p.stale, true);
    }

    function test_read_sequencerWithinGracePeriod() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeedtWithinGracePeriod));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.addPrice(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.addBalance(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 1e8);
        assertEq(r.issues, 1);

        INAVCalculator.Position memory p = nav.readPosition(safe, address(usdc), 0);
        assertEq(p.underlyingAsset, address(usdc));
        assertEq(p.stale, true);
    }

    function test_read_multipleBalancesSameAsset() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(usdc), address(stakingBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        // mint 1 USDC to both the safe and the custom oracle
        stakingBalanceOracle.setBalance(address(usdc), safe, int256(10 ** usdc.decimals()));
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 2 * 1e8);
        assertEq(r.issues, 0);
    }

    function test_read_singleNegativeBalanceAndOnePositiveBalance() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(usdc), address(stakingBalanceOracle), IBalances.BalanceType.Custom);

        //Set the custom oracle to -1 USDC  and  mint 1 USDC to the safe
        stakingBalanceOracle.setBalance(address(usdc), safe, -1 * int256(10 ** usdc.decimals()));
        vm.stopPrank();
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, 0 * 1e8);
        assertEq(r.issues, 0);
    }

    function test_read_negativeBalances() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        Mock_CustomBalanceOracle aaveBalanceOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(usdc), address(stakingBalanceOracle), IBalances.BalanceType.Custom);
        nav.addBalance(address(dai), address(aaveBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        // mint 1 USDC to both the safe and the custom oracle
        stakingBalanceOracle.setBalance(address(usdc), safe, -1 * int256(10 ** usdc.decimals()));
        aaveBalanceOracle.setBalance(address(dai), safe, -1 * int256(10 ** dai.decimals()));

        INAVCalculator.NAV memory r = nav.read(safe);
        assertEq(r.usd, -(2 * 1e8));
        assertEq(r.issues, 0);
    }

    function test_read_BalanceOracleNotSet() public {
        assertEq(nav.balanceOracleCountFor(address(usdc)), 1);
        vm.expectRevert(IBalances.BalanceOracleNotSet.selector);
        nav.readPosition(safe, address(usdc), 2);

        vm.startPrank(navCalculatorManager);
        nav.addBalance(address(usdc), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();
        assertEq(nav.balanceOracleCountFor(address(usdc)), 2);
        vm.expectRevert(IBalances.BalanceOracleNotSet.selector);
        nav.readPosition(safe, address(usdc), 3);
    }

    function test_read_noAssets_doesNotRevert() public {
        vm.startPrank(navCalculatorManager);

        nav.removeBalance(address(usdc), address(usdc));
        nav.removePrice(address(usdc));

        nav.removeBalance(address(dai), address(dai));
        nav.removePrice(address(dai));

        nav.removeBalance(address(weth), address(weth));
        nav.removePrice(address(weth));
        vm.stopPrank();

        assertEq(nav.assetCount(), 0);

        INAVCalculator.NAV memory n = nav.read(safe);
        assertEq(n.usd, 0);
        assertEq(n.issues, 0);
        assertEq(n.block, block.number);
        assertEq(n.timestamp, block.timestamp);
    }

    function test_recoverAssets() public {
        assertEq(nav.assetRecoverer(), safe);

        usdc.mint(address(nav), 100);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        vm.expectEmit(true, true, true, true, address(usdc));
        emit Transfer(address(nav), address(safe), 100);
        nav.recoverAssets(assets);
    }

    function test_setAssetRecoverer() public {
        assertEq(nav.assetRecoverer(), safe);

        usdc.mint(address(nav), 100);

        vm.prank(admin);
        nav.setAssetRecoverer(alice);

        assertEq(nav.assetRecoverer(), alice);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        vm.expectEmit(true, true, true, true, address(usdc));
        emit Transfer(address(nav), address(alice), 100);
        nav.recoverAssets(assets);
    }

    function test_setAssetRecoverer_notAuthorized() public {
        usdc.mint(address(nav), 100);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccessControlUnauthorizedAccount.selector, alice, bytes32(0)));
        nav.setAssetRecoverer(alice);
    }

    function test_setChainlinkUptimeFeed() public {
        assertEq(address(nav.chainlinkL2SequencerUptimeFeed()), address(sequencerUptimeFeed));

        vm.prank(navCalculatorManager);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeedDown));

        assertEq(address(nav.chainlinkL2SequencerUptimeFeed()), address(sequencerUptimeFeedDown));
    }

    function test_setChainlinkUptimeFeed_notAuthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeedDown));
    }

    function test_setSequencerGracePeriod() public {
        assertEq(nav.chainlinkL2SequencerGracePeriod(), 1 hours);

        vm.startPrank(navCalculatorManager);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));
        nav.setChainlinkL2SequencerGracePeriod(2 hours);

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 2 hours);
    }

    function test_setSequencerGracePeriod_notAuthorized() public {
        vm.startPrank(alice);
        vm.expectRevert();
        nav.setChainlinkL2SequencerGracePeriod(2 hours);
    }
}
