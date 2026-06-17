// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console2} from "forge-std/console2.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {DaiDsrBalanceAdapter} from "src/balances/protocols/DaiDsr.sol";
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title Shared base for NAV fork tests (one file per chain extends this)
abstract contract NAVCalculatorForkHarness is TestEnvConfigurator {
    address public safe = address(0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f);

    IBalanceAdapter public aaveAdapter;
    IBalanceAdapter public compoundV3Comet;
    IBalanceAdapter public morphoBlueAdapter;
    DaiDsrBalanceAdapter public daiDsr;
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
            console2.log("       underlyingAsset.asset", p.balanceAsset.asset);
            console2.log("       underlyingAsset.symbol", p.balanceAsset.symbol);
            console2.log("       underlyingAsset.decimals", p.balanceAsset.decimals);
            console2.log("       balanceAdapter", p.balanceAdapter);
            console2.log("       amount", p.amount);
            console2.log("       isDebt", p.isDebt);
            console2.log("       quoteAsset.asset", p.quoteAsset.asset);
            console2.log("       quoteAsset.symbol", p.quoteAsset.symbol);
            console2.log("       value", p.value);
            console2.log("       price", p.price);
            console2.log("       priceDecimals", p.priceDecimals);
            console2.log("       stale", p.stale);
            console2.logBytes32(p.protocolId);
        }
    }

    /// @notice Toggles whether logAccountPositions emits console output. Call from setUp() to enable logging (default is off).
    function togglePositionsLogging() internal {
        skipForkLogs = !skipForkLogs;
    }

    function setupNavCalculator() internal {
        vm.selectFork(fork);

        // PriceFeedLib is pre-linked at this deterministic CREATE2 address (foundry.toml libraries config).
        // Etch its runtime code so DELEGATECALL succeeds on any fork where it hasn't been deployed yet.
        address priceFeedLibImpl = vm.deployCode("PriceFeedLib.sol:PriceFeedLib");
        vm.etch(0x6F0C6f68728Ec474FecB4DE7cdd72E28C2D42715, priceFeedLibImpl.code);
        vm.etch(0x706cD291D3164B7F50e8FEBDE5d744a3eb12Ed56, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);

        vm.startPrank(admin);
        nav = NAVCalculator(
            Upgrades.deployUUPSProxy(
                "NAVCalculator.sol",
                abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH")),
                unsafeDeployOpts()
            )
        );

        nav.grantRole(MANAGER, admin);

        setupRegisterAssets();
        setupBalanceAdapter();

        vm.stopPrank();
    }

    function setupRegisterAssets() internal virtual {}

    function setupBalanceAdapter() internal virtual {}

    function unsafeDeployOpts() internal pure returns (UUPSDeployOptions memory opts) {
        opts.unsafeSkipAllChecks = true;
    }
}
