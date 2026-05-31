// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

/// @custom:oz-upgrades-from NAVCalculator
contract NAVCalculatorV2 is NAVCalculator {
    // A distinguishing member proving the upgrade swapped the implementation. Implemented as a pure function
    // rather than a `uint256 public foo` storage var: the storage-var form perturbs the via_ir optimizer into a
    // pathologically larger contract (~320 bytes over EIP-170 on the CI toolchain, while NAVCalculator itself
    // fits). A pure function adds no storage slot and keeps the same surface the test asserts (`foo() == 0`).
    function foo() external pure returns (uint256) {
        return 0;
    }
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

    // we need the upgrade call to be done in an external function, so that vm.expectRevert catches inner reverts
    // Skip validation in tests (build info is often from partial compilation). Run `forge clean && forge build` and
    // validate separately in CI if needed.
    // forge-lint: disable-next-line(mixed-case-function) -- test helper name kept short for expectRevert
    function t_upgrade(address from, address target) external {
        Options memory opts;
        opts.unsafeSkipAllChecks = true;
        vm.startPrank(from);
        Upgrades.upgradeProxy(target, "NAVCalculator.upgrade.t.sol:NAVCalculatorV2", "", opts, from);
        vm.stopPrank();
    }
}
