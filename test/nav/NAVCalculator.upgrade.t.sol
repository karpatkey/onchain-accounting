// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "test/SuperTest.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @custom:oz-upgrades-from NAVCalculator
contract NAVCalculatorV2 is NAVCalculator {
    uint256 public foo;
}

contract NAVCalculatorUpgradeTest is SuperTest {
    function setUp() public {
        setupAll();
    }

    function test_upgrade() public {
        this.t_upgrade(admin, address(nav));

        assertEq(NAVCalculatorV2(address(nav)).foo(), 0);
    }

    function test_upgrade_notAuthorized() public {
        vm.expectRevert(NotAuthorized.selector);
        this.t_upgrade(alice, address(nav));
    }

    // we need the upgrade call to be done in an external function, so that `vm.expectRevert catches inner reverts
    function t_upgrade(address from, address target) external {
        vm.startPrank(from);
        Upgrades.upgradeProxy(target, "NAVCalculator.upgrade.t.sol:NAVCalculatorV2", "");
        vm.stopPrank();
    }
}
