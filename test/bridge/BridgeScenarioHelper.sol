// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {BridgeTestBase} from "test/bridge/BridgeTestBase.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/bridge/mocks/MockBridgeProtocols.sol";

/// @title BridgeScenarioHelper
/// @notice Helpers for realistic bridge adapter tests that mirror production flow
///
/// ## Real-world flow (what we emulate)
/// 1. SOURCE CHAIN: Account calls BridgeEscrow.depositAndBridge().
///    - Escrow creates invoice, pulls tokens, approves adapter, calls adapter.bridge(messagePayload).
///    - Adapter calls the real bridge contract (e.g. SpokePool.deposit) with messagePayload.
/// 2. [CROSS-CHAIN]: Relayer / attestation / L2 finality (we simulate by switching vm.chainId and
///    delivering via the mock's public relay API only—never calling the adapter's receive callback from the test).
/// 3. DESTINATION CHAIN: Bridge contract sends tokens to adapter and calls adapter.handleX(..., messagePayload).
///    - We simulate by calling mock.fillDeposit() / mock.deliverMessage() so the callback comes from the mock.
/// 4. Manager calls adapter.completeBridge(messagePayload, protocolData).
///    - Adapter transfers tokens to escrow and calls escrow.releaseByInvoiceId(messagePayload).
///
/// ## Realism rules
/// - messagePayload MUST come from the source run (e.g. from the deposit created in step 1), not hand-built.
/// - Delivery to the adapter MUST go through the mock's relay/deliver function (e.g. fillDeposit), not direct handleX from the test.
///
/// ## Reusing this pattern for other adapters
/// - Across: Use _getAcrossMessagePayloadFromLastDeposit(spokePool); deliver via spokePool.addRelayDeposit + fillDeposit.
/// - CCIP: After depositAndBridge, read message from mock router (e.g. last ccipSend payload); on destination use
///   MockCcipRouter.deliverMessage(msgId, destAdapter) so the adapter receives ccipReceive from the router.
/// - Stargate: Same idea—deliver via MockStargateRouter.deliverMessage(msgId, destAdapter, token, amount).
/// - CCTP: No callback; tokens mint to escrow. Use source-originated messagePayload and mock MessageTransmitter.receiveMessage.
/// - Gnosis: Register callback on dest escrow (adapter as delegatecall target); use MockOmnibridge.deliverTokens(token, destEscrow, amount, data) so escrow receives onTokenTransfer and delegatecalls adapter.
abstract contract BridgeScenarioHelper is BridgeTestBase {
    /// @notice Reads the message payload from the last deposit on source (after depositAndBridge + adapter.bridge)
    /// @param spokePool Source chain MockSpokePool that received the deposit
    /// @return messagePayload The exact bytes the adapter sent to the bridge (use this on destination)
    function _getAcrossMessagePayloadFromLastDeposit(MockSpokePool spokePool)
        internal
        view
        returns (bytes memory messagePayload)
    {
        uint256 id = spokePool.depositId();
        require(id > 0, "BridgeScenario: no deposit");
        return spokePool.getDepositMessage(id);
    }

    /// @notice Builds messagePayload from an existing invoice (for CCTP and others where the bridge mock does not store payload)
    /// @param escrow BridgeEscrow that holds the invoice
    /// @param invoiceHash Hash returned from depositAndBridge
    /// @return messagePayload Encoded InvoiceData matching the invoice (for use on destination in completeBridge)
    function _getMessagePayloadFromInvoiceHash(BridgeEscrow escrow, bytes32 invoiceHash)
        internal
        view
        returns (bytes memory messagePayload)
    {
        IBridgeEscrow.Invoice memory inv = escrow.getInvoice(invoiceHash);
        require(inv.invoiceId != bytes32(0), "BridgeScenario: no invoice");
        (, uint24 destChainId,, string memory assetSymbolStr) = escrow.decodeInvoiceId(inv.invoiceId);
        bytes24 checksum24 = _calculateChecksum(inv.invoiceId, inv.amount, uint64(inv.timestamp), inv.nonce);
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.InvoiceData({
            invoiceId: inv.invoiceId,
            sourceChainId: uint24(inv.sourceChainId),
            destinationChainId: destChainId,
            account: inv.account,
            assetSymbol: InvoiceDataLib.strToBytes6(assetSymbolStr),
            amount: inv.amount,
            nonce: inv.nonce,
            timestamp: uint64(inv.timestamp),
            checksum24: checksum24
        });
        return InvoiceDataLib.encode(data);
    }
}
