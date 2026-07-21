// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BridgeAdapter} from "src/bridge/BridgeAdapter.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";

/// @title MockBridgeAdapter
/// @notice Minimal concrete implementation of BridgeAdapter for testing base behavior
/// @dev _bridge and _completeBridge are no-ops; used to test bridge(), completeBridge(), recoverStuckAssets()
contract MockBridgeAdapter is BridgeAdapter {
    /// @param expectedInitializer_ Address permitted to call initialize (address(0) allows anyone).
    constructor(address expectedInitializer_) BridgeAdapter(expectedInitializer_) {}

    /// @notice Initializer for tests (single external entrypoint; base initializer is internal)
    function initialize(address admin_, address bridgeEscrow_, string memory providerName_, string memory version_)
        external
    {
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, providerName_, version_);
    }

    /// @notice No-op bridge implementation for unit testing base adapter
    function _bridge(InvoiceDataLib.InvoiceData memory) internal pure override {
        // No-op: base tests verify caller check and event emission only
    }

    /// @notice No-op completion implementation; releaseByInvoiceId is called by base after this
    function _completeBridge(bytes calldata, bytes calldata) internal pure override {
        // No-op
    }

    /// @notice Accept native ETH (e.g. when BridgeEscrow sends ETH to adapter for native bridging)
    receive() external payable {}
}
