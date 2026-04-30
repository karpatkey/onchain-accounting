// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Aura} from "src/balances/protocols/aura/Aura.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Aura unit tests (no fork)
contract AuraTest is Test {
    function test_constructorRevertsOnZeroPool() public {
        vm.expectRevert(InvalidArguments.selector);
        new Aura(address(0), address(1), address(1), 0, "Aura", "Pool", address(1));
    }

    function test_constructorRevertsOnZeroGauge() public {
        vm.expectRevert(InvalidArguments.selector);
        new Aura(address(1), address(0), address(1), 0, "Aura", "Pool", address(1));
    }
}
