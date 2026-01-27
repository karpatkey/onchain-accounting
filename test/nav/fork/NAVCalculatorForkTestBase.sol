// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {CompoundV3CometWithMultiplier} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
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
    CompoundV3CometWithMultiplier public compoundV3CometWithMultiplier;
    MorphoMarketBalanceOracle public morphoBlueOracle;
    DaiDsrBalanceOracle public daiDsr;
    sXDAI_PriceOracle public savingsXdaiPrice;
    sDAI_PriceOracle public sdaiPriceOracle;

    NAVCalculator public nav;

    uint256 public fork;
    address public admin = makeAddr("admin");
    address public ops = makeAddr("ops");

    uint256 public heartbeat = type(uint256).max;

    function forkRead() internal view returns (INAVCalculator.NAV memory) {
        return nav.getAccountNav(safe, address(0));
    }

    /// @notice Checks if fork tests should be skipped (no-op: fork tests always run)
    function _checkSkipForkTests() internal {
        // Fork tests always run; no skip logic
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
    function createCompoundOracle(address compoundRewardContract_, address cUsdCv3_, address compound_, address nav_)
        external
        returns (CompoundV3CometWithMultiplier)
    {
        return new CompoundV3CometWithMultiplier(
            compoundRewardContract_, cUsdCv3_, compound_, "Compound v3", "USDC Comet", nav_
        );
    }
}
