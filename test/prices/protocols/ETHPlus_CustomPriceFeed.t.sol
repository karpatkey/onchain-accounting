// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ETHPlus_CustomPriceFeed} from "src/prices/protocols/ETHPlus_CustomPriceFeed.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Constructs the feed from a NON-test contract, so the `new` is a real CREATE.
/// @dev    `dynamic_test_linking = true` rewrites `new` inside a TEST contract into a `vm.deployCode` cheatcode,
///         and a cheatcode's revert is not catchable by Solidity `try`/`catch` — it unwinds the whole test frame.
///         Doing the construction here and reaching it with a low-level call keeps the revert payload readable
///         under both linking modes, which is what the code-less-address test needs to assert.
contract ETHPlusDeployer {
    function deploy(address underlying, uint256 heartbeat) external returns (address) {
        return address(new ETHPlus_CustomPriceFeed(underlying, heartbeat));
    }
}

/// @title ETHPlus_CustomPriceFeed unit tests (no fork)
/// @dev The constructor runs two checks in order — `assertERC20Address(ethPlus_)` then
///      `assertNotZeroNumber(reserveProtocolHeartbeat_)` — and **both revert the same `InvalidArguments()`**.
///      That makes the two indistinguishable by error alone, so the only way to prove the second one runs is to
///      build an input the first one ACCEPTS. The previous version of this file did the opposite: its
///      zero-heartbeat case passed `address(0x1)`, which has no code, so `assertERC20Address` rejected it first
///      and the heartbeat check was never reached. With a bare `vm.expectRevert()` accepting any revert, both
///      tests passed for the same reason, and deleting `assertNotZeroNumber` entirely left them green.
contract ETHPlus_CustomPriceFeedTest is Test {
    Mock_ERC20 internal ethPlus;

    function setUp() public {
        ethPlus = new Mock_ERC20("ETH+", 18);
    }

    // --- the address guard, isolated: the heartbeat is valid, so only `assertERC20Address` can object ---

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new ETHPlus_CustomPriceFeed(address(0), 86_400);
    }

    /// @dev Asserts the ACTUAL behaviour, which is not `InvalidArguments`: a code-less address reverts with an
    ///      EMPTY payload. `OracleArgumentChecks.assertERC20Address` probes `totalSupply()` inside a `try`, but a
    ///      high-level call to a code-less address is rejected by solc's `extcodesize` precheck in the CALLER's
    ///      frame, before the call — so the `catch` that would raise `InvalidArguments` is never entered and the
    ///      revert carries no selector for an operator to read.
    ///
    ///      Noted rather than fixed: it is the same hazard `PriceFeedLib._validateFeedSupportInternal` already
    ///      guards against explicitly (`AddressCheckLib.requireContract(priceFeed, "priceFeed")`, added so a
    ///      code-less feed "must fail by name"), and `assertERC20Address` has no equivalent. Changing shared
    ///      argument-checking used by every price feed is outside this PR's scope; the empty-payload assertion
    ///      here pins today's behaviour so a later fix has to come past this test rather than sliding under it.
    ///
    ///      **Two corrections this test needed, both surfaced by `dynamic_test_linking`.**
    ///
    ///      The fixture was `address(0x1)`, which is the **ecrecover precompile**. It satisfies
    ///      `code.length == 0` — so the original assertion looked sound — but a CALL to it SUCCEEDS and returns
    ///      empty, which is nothing like a code-less address. The test was exercising the precompile path while
    ///      claiming to exercise the code-less one. `address(0xDEAD)` is genuinely code-less and outside the
    ///      precompile range, so the `extcodesize` precheck is what actually fires.
    ///
    ///      **On the payload assertion, and why the construction goes through a helper.** `reason.length == 0`
    ///      is the strong form: it pins ANY change to how the rejection is reported, so a later fix adding a
    ///      contract check cannot slide under it. It only works because construction is a plain `CREATE`.
    ///
    ///      This branch briefly carried `dynamic_test_linking = true`, which routed `new` in test sources through
    ///      a `vm.deployCode` cheatcode — FILE-scoped, so putting the `new` in a non-test helper did not escape
    ///      it — and forge substituted its own error: CI produced 160 bytes decoding as a bare
    ///      `abi.encode(string)` (offset `0x20`, length `0x47`) reading `"call to non-contract address 0x…dEaD"`,
    ///      while identical code and identical forge gave 0 bytes locally. The payload had become a property of
    ///      the harness rather than of this contract, and the assertion had to be weakened to survive it. **The
    ///      flag was measured, found to buy nothing, and removed** (see `foundry.toml`), so the strong form is
    ///      back. If anyone reinstates the flag, this test breaks again — that is a feature, not a nuisance.
    ///
    ///      The `ETHPlusDeployer` helper is kept even though a plain `CREATE` no longer needs it: reaching the
    ///      constructor through a low-level call is what makes the revert payload readable at all, rather than
    ///      unwinding the test frame the way `try new` does.
    function test_constructor_revertsWithoutDataOnCodelessAddress() public {
        address noCode = address(0xDEAD);
        assertEq(noCode.code.length, 0, "fixture must have no code for this test to mean anything");
        assertGt(uint160(noCode), 0xFF, "fixture must be outside the precompile range; see the dev note");

        ETHPlusDeployer deployer = new ETHPlusDeployer();
        (bool ok, bytes memory reason) =
            address(deployer).call(abi.encodeCall(ETHPlusDeployer.deploy, (noCode, 86_400)));

        assertFalse(ok, "a code-less underlying must be rejected");
        assertEq(reason.length, 0, "code-less address currently reverts with no data (extcodesize precheck)");
    }

    // --- the heartbeat guard, isolated: the address is a real ERC20, so only `assertNotZeroNumber` can object ---

    /// @dev Deleting `assertNotZeroNumber(reserveProtocolHeartbeat_)` makes this construction SUCCEED and this
    ///      test fail. That is the mutation the old file could not catch.
    function test_constructor_revertsOnZeroHeartbeat() public {
        vm.expectRevert(InvalidArguments.selector);
        new ETHPlus_CustomPriceFeed(address(ethPlus), 0);
    }

    /// @notice The positive control, so "reverts on a zero heartbeat" stays distinguishable from "always reverts".
    function test_constructor_acceptsValidArgs() public {
        ETHPlus_CustomPriceFeed feed = new ETHPlus_CustomPriceFeed(address(ethPlus), 86_400);
        assertEq(feed.RESERVE_PROTOCOL_HEARTBEAT(), 86_400, "heartbeat not stored");
        assertEq(feed.ETHPLUS(), address(ethPlus), "underlying not stored");
    }
}
