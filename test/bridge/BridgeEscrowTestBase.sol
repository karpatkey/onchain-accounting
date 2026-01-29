// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {BridgeTestBase} from "test/bridge/BridgeTestBase.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {BridgeAdapter} from "src/bridge/BridgeAdapter.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BridgeEscrowTestBase
/// @notice Base for BridgeEscrow test suites (unit, errors, fuzz, invariant)
/// @dev Provides escrow + mock adapter setup and shared helpers
abstract contract BridgeEscrowTestBase is BridgeTestBase {
    MockBridgeAdapter public mockAdapter;

    function setUp() public virtual override {
        super.setUp();
        _deployMockAdapter();
        _authorizeAdapter(address(mockAdapter));
    }

    function _deployMockAdapter() internal {
        address impl = address(new MockBridgeAdapter());
        address payable proxy = payable(address(
                UnsafeUpgrades.deployUUPSProxy(
                    impl, abi.encodeCall(BridgeAdapter.initialize, (admin, address(bridgeEscrow), "Mock", "1.0.0"))
                )
            ));
        mockAdapter = MockBridgeAdapter(proxy);
        vm.label(address(mockAdapter), "MockBridgeAdapter");
    }

    /// @notice Destination chain + valid payload for releaseByInvoiceId tests
    function _setupDestinationAndValidPayload(
        address,
        /* asset */
        uint256 amount
    )
        internal
        returns (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock)
    {
        vm.chainId(uint256(DEST_CHAIN_ID));
        destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        destMock = _deployMockAdapterForEscrow(destEscrow);
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(address(destMock));
        vm.stopPrank();
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, portfolioSafe, USDC_SYMBOL, amount);
        messagePayload = InvoiceDataLib.encode(data);
        return (destEscrow, messagePayload, destMock);
    }

    function _deployMockAdapterForEscrow(BridgeEscrow escrow) internal returns (MockBridgeAdapter destMock) {
        address impl = address(new MockBridgeAdapter());
        address payable proxy = payable(address(
                UnsafeUpgrades.deployUUPSProxy(
                    impl, abi.encodeCall(BridgeAdapter.initialize, (admin, address(escrow), "Mock", "1.0.0"))
                )
            ));
        return MockBridgeAdapter(proxy);
    }

    function _createInvoiceDataWithTimestamp(
        uint64 sourceChainId,
        uint64 destChainId,
        address safe,
        bytes6 assetSymbol,
        uint256 amount,
        uint64 timestamp
    ) internal pure returns (InvoiceDataLib.InvoiceData memory) {
        bytes32 invoiceId = _generateInvoiceId(sourceChainId, destChainId, safe, assetSymbol);
        bytes24 checksum24 = _calculateChecksum(invoiceId, amount, timestamp);
        return InvoiceDataLib.InvoiceData({
            invoiceId: invoiceId,
            sourceChainId: SafeCast.toUint24(sourceChainId),
            destinationChainId: SafeCast.toUint24(destChainId),
            portfolioSafe: safe,
            assetSymbol: assetSymbol,
            amount: amount,
            timestamp: timestamp,
            checksum24: checksum24
        });
    }

    function _array(bytes32 a) internal pure returns (bytes32[] memory) {
        bytes32[] memory arr = new bytes32[](1);
        arr[0] = a;
        return arr;
    }
}
