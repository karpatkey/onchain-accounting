// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {SkySavingsUsdsBalanceAdapter} from "src/balances/protocols/SkySavingsUsds.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title SkySavingsUSDS unit tests (no fork)
contract SkySavingsUSDSTest is Test {
    MockBalances mockBalances;

    function setUp() public {
        mockBalances = new MockBalances();
    }

    function test_constructorRevertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new SkySavingsUsdsBalanceAdapter(address(0), address(mockBalances));
    }
}
