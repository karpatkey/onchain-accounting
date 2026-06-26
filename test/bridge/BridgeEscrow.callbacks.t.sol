// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {BridgeAdapter} from "src/bridge/BridgeAdapter.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title BridgeEscrow Adapter Authorization Tests
/// @notice ADR 0012 removed the escrow callback dispatcher: there is no `fallback()`, no
///         `authorizeAdapterWithCallback`, no `updateAdapterConfig`, no `getCallbackAdapter`. Adapters are
///         authorized only via `authorizeAdapter(adapter)` and receive protocol messages directly. This
///         suite asserts the new (callback-free) authorization surface and that the escrow exposes no
///         dispatcher: an unauthenticated call carrying an arbitrary selector reverts (no fallback).
contract BridgeEscrowCallbacksTest is BridgeEscrowTestBase {
    bytes4 public constant FAKE_SELECTOR = bytes4(keccak256("fakeCallback()"));
    bytes4 public constant OTHER_SELECTOR = bytes4(keccak256("otherCallback()"));
    address public adapterAddress;

    function setUp() public override {
        super.setUp();
        adapterAddress = address(mockAdapter);
    }

    /// @notice Plain authorization works and is reflected by isAuthorizedAdapter / getAuthorizedAdapters.
    function test_authorizeAdapter_authorizesAndEnumerates() public {
        MockBridgeAdapter otherAdapter = _deploySecondMockAdapter();
        address otherAddr = address(otherAdapter);
        assertFalse(bridgeEscrow.isAuthorizedAdapter(otherAddr), "Should not be authorized yet");

        vm.prank(admin);
        bridgeEscrow.authorizeAdapter(otherAddr);

        assertTrue(bridgeEscrow.isAuthorizedAdapter(otherAddr), "Should be authorized");

        address[] memory adapters = bridgeEscrow.getAuthorizedAdapters();
        bool found;
        for (uint256 i; i < adapters.length; i++) {
            if (adapters[i] == otherAddr) found = true;
        }
        assertTrue(found, "Adapter should appear in getAuthorizedAdapters");
    }

    /// @notice authorizeAdapter is admin-gated.
    function test_RevertWhen_authorizeAdapter_notAdmin() public {
        MockBridgeAdapter otherAdapter = _deploySecondMockAdapter();
        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.authorizeAdapter(address(otherAdapter));
    }

    /// @notice revokeAdapter removes authorization (no callback config to clear under ADR 0012).
    function test_revokeAdapter_removesAuthorization() public {
        assertTrue(bridgeEscrow.isAuthorizedAdapter(adapterAddress), "Authorized in setUp");
        vm.prank(admin);
        bridgeEscrow.revokeAdapter(adapterAddress);
        assertFalse(bridgeEscrow.isAuthorizedAdapter(adapterAddress), "Adapter revoked");
    }

    /// @notice There is NO callback dispatcher: a raw call carrying an arbitrary selector hits no fallback
    ///         (the escrow has none) and reverts. This is the structural fix for C1 — the escrow can no
    ///         longer be coaxed into forwarding a forged protocol callback to an adapter.
    function test_noFallbackDispatcher_arbitrarySelectorReverts() public {
        (bool success,) = address(bridgeEscrow).call(abi.encodeWithSelector(FAKE_SELECTOR));
        assertFalse(success, "Escrow must not dispatch arbitrary selectors (no fallback)");

        // Even an attacker-controlled caller cannot reach any release path through a bare selector call.
        vm.prank(unauthorized);
        (bool success2,) = address(bridgeEscrow).call(abi.encodeWithSelector(OTHER_SELECTOR, uint256(123)));
        assertFalse(success2, "No fallback dispatch for unauthenticated callers");
    }

    function _deploySecondMockAdapter() internal returns (MockBridgeAdapter) {
        address impl = address(new MockBridgeAdapter());
        address payable proxy = payable(address(
                UnsafeUpgrades.deployUUPSProxy(
                    impl, abi.encodeCall(MockBridgeAdapter.initialize, (admin, address(bridgeEscrow), "Mock2", "1.0.0"))
                )
            ));
        return MockBridgeAdapter(proxy);
    }
}
