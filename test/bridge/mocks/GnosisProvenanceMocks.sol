// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOmnibridge, IAMB} from "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";

/// @title GnosisProvenanceMocks
/// @notice Provenance-model mocks for the Gnosis Omnibridge adapter (ADR 0012).
/// @dev These mirror the new completion model: the mediator delivers tokens to the *sibling adapter* and calls
///      `onTokenTransfer(address,uint256,bytes)` on it directly (no escrow fallback). The AMB mock exposes
///      configurable `messageSender()` / `messageSourceChainId()` so tests can drive the adapter's source
///      authentication. Lives in its own file (not the shared MockBridgeProtocols) because the new callback
///      signature and the configurable AMB getters differ from the legacy shared mocks.

/// @notice Mock AMB with configurable provenance getters (messageSender / messageSourceChainId / transactionHash)
contract MockProvenanceAMB is IAMB {
    address private _messageSender;
    bytes32 private _messageSourceChainId;
    bytes32 private _transactionHash;

    constructor() {
        _transactionHash = keccak256("mock-transaction-hash");
    }

    function setMessageSender(address sender) external {
        _messageSender = sender;
    }

    function setMessageSourceChainId(bytes32 srcChainId) external {
        _messageSourceChainId = srcChainId;
    }

    function setTransactionHash(bytes32 txHash) external {
        _transactionHash = txHash;
    }

    function messageSender() external view override returns (address) {
        return _messageSender;
    }

    function messageSourceChainId() external view override returns (bytes32) {
        return _messageSourceChainId;
    }

    function transactionHash() external view override returns (bytes32) {
        return _transactionHash;
    }

    // Remaining IAMB members: defaults sufficient for these tests.
    function maxGasPerTx() external pure override returns (uint256) {
        return 0;
    }

    function messageId() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function messageCallStatus(bytes32) external pure override returns (bool) {
        return false;
    }

    function failedMessageDataHash(bytes32) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function failedMessageReceiver(bytes32) external pure override returns (address) {
        return address(0);
    }

    function failedMessageSender(bytes32) external pure override returns (address) {
        return address(0);
    }

    function requireToPassMessage(address, bytes calldata, uint256) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function requireToConfirmMessage(address, bytes calldata, uint256) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function sourceChainId() external pure override returns (uint256) {
        return 0;
    }

    function destinationChainId() external pure override returns (uint256) {
        return 0;
    }
}

/// @notice Mock Omnibridge mediator for the provenance model.
/// @dev On the source chain `relayTokensAndCall` pulls tokens from the caller (the adapter) and records the
///      relay data. On the destination chain `deliverTokens` transfers tokens to the *recipient adapter* and then
///      calls `onTokenTransfer(address,uint256,bytes)` on it — the genuine mediator -> adapter callback.
contract MockProvenanceOmnibridge is IOmnibridge {
    using SafeERC20 for IERC20;

    event TokensBridged(address indexed token, address indexed recipient, uint256 amount, bytes data);

    bytes public lastRelayData;
    uint256 public lastRelayValue;
    address public lastRelayReceiver;
    address public lastRelayToken;

    function relayTokens(address _token, address _receiver, uint256 _value) external override {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _value);
        emit TokensBridged(_token, _receiver, _value, "");
    }

    function relayTokensAndCall(address token, address receiver, uint256 value, bytes memory data) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), value);
        lastRelayData = data;
        lastRelayValue = value;
        lastRelayReceiver = receiver;
        lastRelayToken = token;
        emit TokensBridged(token, receiver, value, data);
    }

    /// @notice Returns the last relay payload and value (for realistic tests: read from source after depositAndBridge)
    function getLastRelayData() external view returns (bytes memory data, uint256 value) {
        return (lastRelayData, lastRelayValue);
    }

    /// @notice Simulates Omnibridge delivery on the destination chain: transfer tokens to the recipient adapter,
    ///         then invoke its onTokenTransfer callback (mediator -> adapter), forwarding the call's return/revert.
    /// @dev This mock must hold `amount` of `token` before calling (mint to it in the test).
    function deliverTokens(address token, address recipientAdapter, uint256 amount, bytes calldata data) external {
        IERC20(token).safeTransfer(recipientAdapter, amount);
        // onTokenTransfer(address from, uint256 value, bytes data)
        (bool success, bytes memory ret) = recipientAdapter.call(
            abi.encodeWithSignature("onTokenTransfer(address,uint256,bytes)", address(this), amount, data)
        );
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
