// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {BridgeAdapter} from "src/bridge/BridgeAdapter.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title BridgeEscrow Callback Config Tests
/// @notice Tests for callback config via authorizeAdapterWithCallback and updateAdapterConfig (adapter is callback target)
contract BridgeEscrowCallbacksTest is BridgeEscrowTestBase {
    bytes4 public constant FAKE_SELECTOR = bytes4(keccak256("fakeCallback()"));
    bytes4 public constant OTHER_SELECTOR = bytes4(keccak256("otherCallback()"));
    address public adapterAddress;

    function setUp() public override {
        super.setUp();
        adapterAddress = address(mockAdapter);
    }

    function test_updateAdapterConfig_setsAdapter() public {
        vm.prank(admin);
        bridgeEscrow.updateAdapterConfig(adapterAddress, FAKE_SELECTOR);
        assertEq(bridgeEscrow.getCallbackAdapter(FAKE_SELECTOR), adapterAddress, "Callback adapter should be set");
    }

    function test_RevertWhen_updateAdapterConfig_notAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.updateAdapterConfig(adapterAddress, FAKE_SELECTOR);
    }

    function test_authorizeAdapterWithCallback_setsAuthAndCallback() public {
        MockBridgeAdapter otherAdapter = _deploySecondMockAdapter();
        address otherAddr = address(otherAdapter);
        assertFalse(bridgeEscrow.isAuthorizedAdapter(otherAddr), "Should not be authorized yet");

        vm.prank(admin);
        bridgeEscrow.authorizeAdapterWithCallback(otherAddr, FAKE_SELECTOR);

        assertTrue(bridgeEscrow.isAuthorizedAdapter(otherAddr), "Should be authorized");
        assertEq(bridgeEscrow.getCallbackAdapter(FAKE_SELECTOR), otherAddr, "Callback adapter should be set");
    }

    function test_RevertWhen_authorizeAdapterWithCallback_alreadyAuthorized() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        bridgeEscrow.authorizeAdapterWithCallback(adapterAddress, FAKE_SELECTOR);
    }

    function test_updateAdapterConfig_changeThenClear() public {
        vm.startPrank(admin);
        bridgeEscrow.updateAdapterConfig(adapterAddress, FAKE_SELECTOR);
        assertEq(bridgeEscrow.getCallbackAdapter(FAKE_SELECTOR), adapterAddress);

        bridgeEscrow.updateAdapterConfig(adapterAddress, OTHER_SELECTOR);
        assertEq(bridgeEscrow.getCallbackAdapter(FAKE_SELECTOR), address(0), "Old selector cleared");
        assertEq(bridgeEscrow.getCallbackAdapter(OTHER_SELECTOR), adapterAddress, "New adapter set");

        bridgeEscrow.updateAdapterConfig(adapterAddress, bytes4(0));
        assertEq(bridgeEscrow.getCallbackAdapter(OTHER_SELECTOR), address(0), "Cleared");
        vm.stopPrank();
    }

    function test_revokeAdapter_clearsCallback() public {
        vm.prank(admin);
        bridgeEscrow.updateAdapterConfig(adapterAddress, FAKE_SELECTOR);
        assertEq(bridgeEscrow.getCallbackAdapter(FAKE_SELECTOR), adapterAddress);

        vm.prank(admin);
        bridgeEscrow.revokeAdapter(adapterAddress);

        assertEq(bridgeEscrow.getCallbackAdapter(FAKE_SELECTOR), address(0), "Cleared");
        assertFalse(bridgeEscrow.isAuthorizedAdapter(adapterAddress), "Adapter revoked");
    }

    /// @notice Fallback with no registered adapter for selector reverts (low-level call returns false)
    function test_fallback_revertsWhenNoAdapterRegistered() public {
        (bool success,) = address(bridgeEscrow).call(abi.encodeWithSelector(FAKE_SELECTOR));
        assertFalse(success, "Call should revert when no adapter registered for selector");
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
