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
    ///      **The fixture was wrong too, and the assertion could not have caught it.** It used `address(0x1)`,
    ///      which is the **ecrecover precompile**. That satisfies `code.length == 0` — so the fixture check
    ///      looked sound — but a CALL to it SUCCEEDS and returns empty, which is nothing like a code-less
    ///      address: the test exercised the precompile path while claiming the code-less one. `address(0xDEAD)`
    ///      is genuinely code-less and outside the precompile range, so the `extcodesize` precheck is what fires.
    ///
    ///      **Why the payload length is NOT asserted, and what would let it be.** `reason.length == 0` is the
    ///      strong form — it pins ANY change to how the rejection is reported. It is unavailable here, and the
    ///      reason is not what an earlier revision of this comment claimed.
    ///
    ///      Measured: CI reports 160 bytes, decoding as a bare `abi.encode(string)` (offset `0x20`, length
    ///      `0x47`) reading `"call to non-contract address 0x…dEaD"` — forge's own error, not this contract's —
    ///      while identical code and identical forge 1.7.1 give 0 bytes locally.
    ///
    ///      That earlier revision blamed `dynamic_test_linking` and said the strong form would return once the
    ///      flag was dropped. **The flag has since been dropped and CI still reports 160.** The flag governed how
    ///      `type(X).creationCode` resolved; it never governed cheatcode revert-payload shape, so it was never
    ///      the cause. The actual cause is **artifact provenance: CI's Unit job does not build — it consumes
    ///      artifacts downloaded from the Build job** — which is orthogonal to the flag.
    ///
    ///      **So the precondition for restoring `assertEq(reason.length, 0)` is CI's Unit job building rather
    ///      than consuming downloaded artifacts.** Do not retry it by changing anything about linking flags;
    ///      that path is already eliminated by measurement.
    ///
    ///      What is asserted instead is the property that belongs to the contract: the rejection is **nameless**.
    ///      If `assertERC20Address` ever gains an `AddressCheckLib.requireContract`-style guard the revert starts
    ///      carrying a selector, and checking the leading word against `InvalidArguments` and `NotAContract` —
    ///      the two such a fix would raise — fails then, while surviving both payload shapes today (CI's begins
    ///      with an ABI offset word, so it reads `0x00000000`). Weaker than the strong form, deliberately.
    ///
    ///      The `ETHPlusDeployer` helper stays: reaching the constructor through a low-level call is what makes
    ///      the revert payload readable at all, rather than unwinding the test frame the way `try new` does.
    function test_constructor_revertsWithoutDataOnCodelessAddress() public {
        address noCode = address(0xDEAD);
        assertEq(noCode.code.length, 0, "fixture must have no code for this test to mean anything");
        assertGt(uint160(noCode), 0xFF, "fixture must be outside the precompile range; see the dev note");

        ETHPlusDeployer deployer = new ETHPlusDeployer();
        (bool ok, bytes memory reason) =
            address(deployer).call(abi.encodeCall(ETHPlusDeployer.deploy, (noCode, 86_400)));

        assertFalse(ok, "a code-less underlying must be rejected");

        bytes4 selector;
        if (reason.length >= 4) {
            // Leading word's high 4 bytes are the selector, if the payload carries one at all.
            assembly {
                selector := mload(add(reason, 0x20))
            }
        }
        assertTrue(
            selector != InvalidArguments.selector && selector != NotAContract.selector,
            "code-less address must still fail NAMELESSLY: a named error means assertERC20Address gained a contract check, and this tripwire has done its job"
        );
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
