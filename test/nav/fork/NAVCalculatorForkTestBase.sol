// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {DaiDsrBalanceOracle} from "src/balances/protocols/DaiDsr.sol";
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title Shared base for NAV fork tests (one file per chain extends this)
abstract contract NAVCalculatorForkHarness is TestEnvConfigurator {
    address public safe = address(0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f);

    AaveV3InstanceBalanceOracle public aaveOracle;
    CompoundV3Comet public compoundV3Comet;
    MorphoMarketBalanceOracle public morphoBlueOracle;
    DaiDsrBalanceOracle public daiDsr;
    sXDAI_PriceOracle public savingsXdaiPrice;
    sDAI_PriceOracle public sdaiPriceOracle;

    NAVCalculator public nav;

    uint256 public fork;
    address public admin = makeAddr("admin");
    address public ops = makeAddr("ops");

    uint256 public heartbeat = type(uint256).max;

    /// @notice When true, logAccountPositions does not emit console output. Default true; call togglePositionsLogging() in setUp to enable.
    bool public skipForkLogs = true;

    function forkRead() internal view returns (INAVCalculator.NAV memory) {
        return nav.getAccountNav(safe, address(0));
    }

    /// @notice Log NAV and all positions for an account to console (for debugging fork tests).
    /// @dev No-op when skipForkLogs is true (default). Call togglePositionsLogging() in setUp to enable.
    /// @param account Account to read positions for (e.g. safe).
    /// @param quoteAsset Quote asset for values (e.g. address(0) for USD).
    function logAccountPositions(address account, address quoteAsset) internal view {
        if (skipForkLogs) return;

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, quoteAsset);
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(account, quoteAsset);

        console2.log("--- NAV ---");
        console2.log("account", account);
        console2.log("quoteAsset", quoteAsset);
        console2.log("navTotal.value", navTotal.value);
        console2.log("navTotal.timestamp", navTotal.timestamp);
        console2.log("navTotal.sequencerDown", navTotal.sequencerDown);
        console2.log("stalePriceAssets.length", navTotal.stalePriceAssets.length);
        console2.log("--- POSITIONS (count)", positions.length);

        for (uint256 i = 0; i < positions.length; i++) {
            INAVCalculator.Position memory p = positions[i];
            console2.log("  index", i);
            console2.log("       underlyingAsset.asset", p.underlyingAsset.asset);
            console2.log("       underlyingAsset.symbol", p.underlyingAsset.symbol);
            console2.log("       underlyingAsset.decimals", p.underlyingAsset.decimals);
            console2.log("       balanceOracle", p.balanceOracle);
            console2.log("       amount", p.amount);
            console2.log("       isDebt", p.isDebt);
            console2.log("       quoteAsset.asset", p.quoteAsset.asset);
            console2.log("       quoteAsset.symbol", p.quoteAsset.symbol);
            console2.log("       value", p.value);
            console2.log("       price", p.price);
            console2.log("       priceDecimals", p.priceDecimals);
            console2.log("       stale", p.stale);
            console2.log("       protocol", p.protocol);
            console2.log("       positionDetail", p.positionDetail);
        }
    }

    /// @notice Toggles whether logAccountPositions emits console output. Call from setUp() to enable logging (default is off).
    function togglePositionsLogging() internal {
        skipForkLogs = !skipForkLogs;
    }

    function setupNavCalculator() internal {
        vm.selectFork(fork);

        vm.startPrank(admin);
        nav = NAVCalculator(
            Upgrades.deployUUPSProxy(
                "NAVCalculator.sol",
                abi.encodeCall(NAVCalculator.initialize, (admin, safe, address(0))),
                unsafeDeployOpts()
            )
        );

        nav.grantRole(MANAGER, admin);

        setupRegisterAssets();
        setupBalanceOracle();

        vm.stopPrank();
    }

    function setupRegisterAssets() internal virtual {}

    function setupBalanceOracle() internal virtual {}

    function unsafeDeployOpts() internal pure returns (UUPSDeployOptions memory opts) {
        opts.unsafeSkipAllChecks = true;
    }

    // Helper for try-catch in child (needs to be external)
    function createCompoundOracle(
        address compoundRewardContract_,
        address comet_,
        address compound_,
        string memory protocol_,
        address nav_
    ) external returns (CompoundV3Comet) {
        return new CompoundV3Comet(compoundRewardContract_, comet_, compound_, protocol_, nav_);
    }
}
