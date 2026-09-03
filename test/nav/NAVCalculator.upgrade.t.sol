// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

/// @dev Deliberately EMPTY, and that is the whole point.
///
///      This fixture exists only to be a *second implementation* for the proxy to point at. It used to carry a
///      distinguishing member — first a `uint256 public foo` storage var, then an `external pure foo()` — so the
///      test could prove the swap by calling something that only V2 has. Both forms cost bytecode: a subclass of
///      an EIP-170-bound contract inherits its entire size, so ANY added external selector (~223 B measured) has
///      to fit in whatever margin `NAVCalculator` has left. That made the fixture, not the contract, the binding
///      limit — 9 bytes of headroom against the contract's 101 — and a change that fits `NAVCalculator` could
///      still fail CI here, in a file nobody edited. It did exactly that.
///
///      Proving the swap does not require a new member. The proxy already records its implementation in the
///      ERC-1967 slot, so the test reads that slot before and after instead. An empty subclass compiles to the
///      same size as `NAVCalculator`, the fixture stops taxing the contract's budget, and the assertion now
///      checks the actual upgrade mechanism rather than a stand-in for it.
///
///      Keep it empty. Adding a member here re-imposes the tax and re-breaks CI from an unexpected file.
/// @custom:oz-upgrades-from NAVCalculator
contract NAVCalculatorV2 is NAVCalculator {}

contract NAVCalculatorUpgradeTest is SuperTest {
    function setUp() public {
        setupAll();
    }

    /// @notice The proxy points at a different implementation after the upgrade.
    /// @dev Reads the ERC-1967 implementation slot rather than calling a marker member on the new
    ///      implementation. `NAVCalculatorV2` is bytecode-identical to `NAVCalculator`, so a fresh deployment is
    ///      what distinguishes it — hence the assertion is on the ADDRESS changing, not on any behaviour. Also
    ///      asserts the new implementation actually has code, so the test cannot pass by pointing the proxy at an
    ///      empty address.
    function test_upgrade() public {
        address implBefore = Upgrades.getImplementationAddress(address(nav));
        assertNotEq(implBefore, address(0), "proxy must start with an implementation");

        this.t_upgrade(admin, address(nav));

        address implAfter = Upgrades.getImplementationAddress(address(nav));
        assertNotEq(implAfter, implBefore, "upgrade must repoint the proxy");
        assertGt(implAfter.code.length, 0, "new implementation must have code");
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
