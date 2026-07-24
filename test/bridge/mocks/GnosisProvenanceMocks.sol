// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOmnibridge, IAMB} from "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

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
    ///         then invoke its `onTokenBridged` callback (the real multi-token mediator `IERC20Receiver` callback
    ///         for `relayTokensAndCall`), forwarding the call's return/revert.
    /// @dev This mock must hold `amount` of `token` before calling (mint to it in the test). Uses `onTokenBridged`
    ///      (not the ERC677 `onTokenTransfer`) to match the genuine OmniBridge delivery path.
    function deliverTokens(address token, address recipientAdapter, uint256 amount, bytes calldata data) external {
        IERC20(token).safeTransfer(recipientAdapter, amount);
        // onTokenBridged(address token, uint256 value, bytes data)
        (bool success, bytes memory ret) =
            recipientAdapter.call(abi.encodeWithSignature("onTokenBridged(address,uint256,bytes)", token, amount, data));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice Mock of the Gnosis USDCTransmuter (1:1, no fee) matching IUSDCTransmuter. `deposit` pulls legacy
///         (USDC_ON_XDAI) via transferFrom and mints USDC.e (USDC_E) to the caller; `withdraw` pulls+burns USDC.e
///         and pays legacy from a seeded reserve (reverts if under-reserved). `setEnabled(false)` simulates the
///         real contract's one-way disable. Mirrors the verified on-chain semantics closely enough to exercise the
///         adapter's swap paths + fail-safes.
contract MockUSDCTransmuter {
    using SafeERC20 for IERC20;

    address public immutable USDC_ON_XDAI;
    address public immutable USDC_E;
    bool public isEnabled = true;

    constructor(address legacy_, address usdce_) {
        USDC_ON_XDAI = legacy_;
        USDC_E = usdce_;
    }

    /// @notice Test hook: simulate the owner's one-way disable (or re-enable, for test convenience).
    function setEnabled(bool enabled_) external {
        isEnabled = enabled_;
    }

    /// @notice legacy -> USDC.e (mints). Caller must approve legacy first.
    function deposit(uint256 amount) external {
        require(isEnabled, "contract is not active!");
        require(amount > 0, "invalid deposit amount!");
        IERC20(USDC_ON_XDAI).safeTransferFrom(msg.sender, address(this), amount);
        Mock_ERC20(USDC_E).mint(msg.sender, amount);
    }

    /// @notice USDC.e -> legacy (from reserve). Caller must approve USDC.e first. Reverts if reserve < amount.
    function withdraw(uint256 amount) external {
        require(isEnabled, "contract is not active!");
        require(IERC20(USDC_ON_XDAI).balanceOf(address(this)) >= amount, "withdrawal amount exceeded!");
        IERC20(USDC_E).safeTransferFrom(msg.sender, address(this), amount);
        Mock_ERC20(USDC_E).burn(address(this), amount);
        IERC20(USDC_ON_XDAI).safeTransfer(msg.sender, amount);
    }
}
