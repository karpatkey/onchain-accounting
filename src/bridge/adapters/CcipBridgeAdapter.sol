// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgeAdapter} from "../BridgeAdapter.sol";
import {IBridgeEscrow} from "../IBridgeEscrow.sol";
import {InvoiceDataLib} from "../InvoiceDataLib.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICcipBridgeAdapter} from "./interfaces/ICcipBridgeAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title CcipBridgeAdapter
/// @notice Bridge adapter for Chainlink's Cross-Chain Interoperability Protocol (CCIP)
/// @dev The destination recipient is the sibling adapter (this contract, same address across chains via
///      CREATE2). The CCIP Router calls `ccipReceive` directly on the adapter; the adapter authenticates the
///      router, the source chain selector and the source sender against `trustedRemoteAdapter`, then funds the
///      escrow and releases (funded pass-through, ADR 0012).
/// @author KPK
contract CcipBridgeAdapter is BridgeAdapter, ICcipBridgeAdapter {
    using SafeERC20 for IERC20;

    //
    // State Variables
    //

    /// @notice Default destination gas limit used when no per-lane extraArgs are configured
    /// @dev Covers ccipReceive -> _fundAndRelease (token transfer + escrow release) with headroom.
    uint256 private constant DEFAULT_CCIP_GAS_LIMIT = 500_000;

    /// @notice CCIP Router contract address
    IRouterClient public router;

    /// @notice Fee token address (address(0) for native, or LINK token address)
    address public feeToken;

    /// @notice Mapping from CCIP message ID to invoice ID
    /// @dev Used to correlate CCIP messages with invoice IDs
    ///      Format: messageIdToInvoiceId[messageId] = invoiceId
    mapping(bytes32 => bytes32) public messageIdToInvoiceId;

    /// @notice Mapping from invoice ID to CCIP message ID
    /// @dev Used to track which messageId was used for each invoice
    mapping(bytes32 => bytes32) public invoiceToMessageId;

    /// @notice Mapping from chain ID to CCIP chain selector
    mapping(uint64 => uint64) public chainIdToSelector;

    /// @notice Mapping from CCIP chain selector to chain ID
    mapping(uint64 => uint64) public selectorToChainId;

    /// @notice Mapping to store CCIP extraArgs per chain selector
    /// @dev Used to configure gas limits and other CCIP-specific parameters
    mapping(uint64 => bytes) public chainExtraArgs;

    /// @notice Mapping to store message payloads by invoice ID
    /// @dev Used to retrieve payloads on destination chain
    mapping(bytes32 => bytes) public messagePayloads;

    /// @dev Internal helper to set both chainId <-> chainSelector mappings
    function _setChainSelector(uint64 chainId, uint64 chainSelector) internal {
        chainIdToSelector[chainId] = chainSelector;
        selectorToChainId[chainSelector] = chainId;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address router_,
        address feeToken_,
        string memory version_
    ) external {
        // Initialize parent BridgeAdapter (single source of truth for admin, bridgeEscrow, provider name, version)
        super._initializeBridgeAdapter(admin_, bridgeEscrow_, "CCIP", version_);

        if (router_ == address(0)) revert InvalidRouter();
        router = IRouterClient(router_);
        feeToken = feeToken_;

        // Approve router to spend fee token if not native
        if (feeToken_ != address(0)) {
            IERC20(feeToken_).forceApprove(router_, type(uint256).max);
        }

        // Pre-configure known CCIP chain selectors (mainnet). Source: https://docs.chain.link/ccip/directory/mainnet
        _setChainSelector(1, 5009297550715157269); // Ethereum
        _setChainSelector(43114, 6433500567565415381); // Avalanche
        _setChainSelector(10, 3734403246176062136); // OP Mainnet
        _setChainSelector(42161, 4949039107694359620); // Arbitrum One
        _setChainSelector(8453, 15971525489660198786); // Base
        _setChainSelector(100, 465200170687744372); // Gnosis Chain (CCIP live since 2024-06-17)
        _setChainSelector(137, 4051577828743386545); // Polygon PoS
    }

    //
    // Configuration
    //

    /// @inheritdoc ICcipBridgeAdapter
    function setChainSelectorMapping(uint64 chainId, uint64 chainSelector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setChainSelector(chainId, chainSelector);
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router_ == address(0)) revert InvalidRouter();
        router = IRouterClient(router_);
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setFeeToken(address feeToken_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Revoke old approval if needed
        if (feeToken != address(0) && feeToken != feeToken_) {
            IERC20(feeToken).forceApprove(address(router), 0);
        }

        feeToken = feeToken_;

        // Approve new fee token if not native
        if (feeToken_ != address(0)) {
            IERC20(feeToken_).forceApprove(address(router), type(uint256).max);
        }
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setChainExtraArgs(uint64 chainSelector, bytes calldata extraArgs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainExtraArgs[chainSelector] = extraArgs;
    }

    //
    // BridgeAdapter Implementation
    //

    /// @inheritdoc BridgeAdapter
    /// @dev Receives decoded invoice data struct and converts it to CCIP-specific format
    function _bridge(InvoiceDataLib.InvoiceData memory data) internal override {
        // Encode messagePayload for CCIP message data
        bytes memory messagePayload = InvoiceDataLib.encode(data);

        // Convert chain ID to CCIP chain selector
        uint64 destinationChainSelector = chainIdToSelector[uint64(data.destinationChainId)];
        if (destinationChainSelector == 0) {
            revert InvalidChainSelector();
        }

        // Validate chain is supported by CCIP router
        if (!router.isChainSupported(destinationChainSelector)) {
            revert UnsupportedChain(destinationChainSelector);
        }

        // Get asset address from escrow
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Pull ERC20 tokens from escrow if not native (escrow approved us in depositAndBridge)
        // CCIP doesn't bridge native tokens directly - only ERC20 tokens
        if (!_isNativeToken(asset) && data.amount > 0) {
            IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount);
        }

        // Prepare token amounts array
        // CCIP doesn't bridge native tokens directly - only ERC20 tokens
        // Native tokens (address(0) or NATIVE_ADDRESS_ERC7528) are not included in tokenAmounts
        Client.EVMTokenAmount[] memory tokenAmounts;
        if (!_isNativeToken(asset) && data.amount > 0) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: data.amount});

            // Approve router to spend tokens
            IERC20(asset).forceApprove(address(router), data.amount);
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        // Recipient is the sibling adapter on the destination chain (same address via CREATE2).
        // The destination CCIP Router calls ccipReceive on it; it authenticates and funds the release.
        bytes memory receiver = abi.encode(address(this));

        // extraArgs: use the per-lane configured value, or a non-empty default. Some CCIP lanes reject
        // empty extraArgs, so default to EVMExtraArgsV1 with a gas limit covering the destination
        // ccipReceive -> release. V1 is accepted on all lanes; lanes that *enforce* out-of-order execution
        // require EVMExtraArgsV2{allowOutOfOrderExecution: true} and must set it per-lane via setChainExtraArgs.
        bytes memory extraArgsToUse = chainExtraArgs[destinationChainSelector];
        if (extraArgsToUse.length == 0) {
            extraArgsToUse = Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: DEFAULT_CCIP_GAS_LIMIT}));
        }

        // Build CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: messagePayload,
            tokenAmounts: tokenAmounts,
            feeToken: feeToken,
            extraArgs: extraArgsToUse
        });

        // Get fee and send message
        uint256 fee = router.getFee(destinationChainSelector, message);
        bytes32 messageId;

        if (feeToken == address(0)) {
            // Pay with native token
            messageId = router.ccipSend{value: fee}(destinationChainSelector, message);
        } else {
            // Pay with fee token (already approved)
            messageId = router.ccipSend(destinationChainSelector, message);
        }

        // Store invoiceId mapping for correlation
        messageIdToInvoiceId[messageId] = data.invoiceId;
        invoiceToMessageId[data.invoiceId] = messageId;

        emit CcipBridgeInitiated(data.invoiceId, destinationChainSelector, messageId, bytes32(data.amount));
    }

    /// @inheritdoc BridgeAdapter
    /// @dev MANAGER fallback completion: the CCIP Router normally calls `ccipReceive` directly (auto path).
    ///      This manager path is used only if that did not run. `protocolData` carries the delivered
    ///      Any2EVMMessage so we can authenticate the source the same way. The adapter must already hold the
    ///      delivered tokens (CCIP delivered them to this adapter as the receiver); the base then funds+releases.
    function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
        Client.Any2EVMMessage memory message = abi.decode(protocolData, (Client.Any2EVMMessage));
        if (message.data.length == 0) revert InvalidCompletionData();
        _authenticateSource(message.sourceChainSelector, message.sender);
        // The base completeBridge funds + releases against `messagePayload`, so it MUST equal the payload we
        // authenticated from the CCIP message — otherwise a manager could release a different invoice than the
        // one provenance vouches for.
        if (keccak256(messagePayload) != keccak256(message.data)) revert InvalidCompletionData();
        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(message.data);
        messagePayloads[data.invoiceId] = message.data;
        emit CcipBridgeCompleted(data.invoiceId, message.messageId, message.sourceChainSelector);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev Auto completion path. Called by the genuine CCIP Router on the destination chain. Authenticates
    ///      the router, the source chain selector and the source sender, verifies the delivered token matches
    ///      the invoice, then funds the escrow and releases (funded pass-through).
    function ccipReceive(Client.Any2EVMMessage calldata message) external override nonReentrant {
        if (msg.sender != address(router)) revert InvalidRouter();
        _authenticateSource(message.sourceChainSelector, message.sender);
        if (message.data.length == 0) revert InvalidCompletionData();

        InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(message.data);
        address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));

        // Verify CCIP actually delivered the invoiced asset+amount to this adapter.
        bool delivered;
        for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
            if (message.destTokenAmounts[i].token == asset && message.destTokenAmounts[i].amount >= data.amount) {
                delivered = true;
                break;
            }
        }
        if (!delivered) revert InvalidBridgeData();

        messagePayloads[data.invoiceId] = message.data;
        _fundAndRelease(message.data, asset, data.amount);

        emit CcipBridgeCompleted(data.invoiceId, message.messageId, message.sourceChainSelector);
    }

    /// @dev Authenticates that an inbound CCIP message came from a known sibling adapter on a known source chain.
    function _authenticateSource(uint64 sourceChainSelector, bytes memory sender) internal view {
        uint64 srcChainId = selectorToChainId[sourceChainSelector];
        if (srcChainId == 0) revert UnsupportedChain(sourceChainSelector);
        address remote = abi.decode(sender, (address));
        if (_toBytes32(remote) != trustedRemoteAdapter[srcChainId]) revert InvalidBridgeData();
    }

    //
    // View Functions
    //

    /// @inheritdoc ICcipBridgeAdapter
    function getMessagePayload(bytes32 invoiceId) external view returns (bytes memory) {
        return messagePayloads[invoiceId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getSelectorForChain(uint64 chainId) external view returns (uint64) {
        return chainIdToSelector[chainId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getChainForSelector(uint64 chainSelector) external view returns (uint64) {
        return selectorToChainId[chainSelector];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getFee(
        uint64 destinationChainSelector,
        bytes memory messageData,
        Client.EVMTokenAmount[] memory tokenAmounts,
        bytes memory extraArgs
    ) external view returns (uint256) {
        bytes memory receiver = abi.encode(address(this));
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver, data: messageData, tokenAmounts: tokenAmounts, feeToken: feeToken, extraArgs: extraArgs
        });
        return router.getFee(destinationChainSelector, message);
    }

    //
    // ERC165 Support
    //

    /// @notice Checks if the contract supports an interface
    /// @param interfaceId The interface ID to check
    /// @return True if supported
    /// @dev Overrides to include IAny2EVMMessageReceiver interface support
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
