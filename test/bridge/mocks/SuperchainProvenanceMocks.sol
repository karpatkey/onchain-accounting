// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Types} from "@optimism/libraries/Types.sol";
import {IOptimismPortal, ICrossDomainMessenger} from "src/bridge/adapters/interfaces/ISuperchainInterfaces.sol";

/// @title SuperchainProvenanceMocks
/// @notice Provenance-aware OP Stack mocks for the re-architected SuperchainBridgeAdapter tests (ADR 0012).
/// @dev Kept separate from the shared `MockBridgeProtocols.sol` so the shared mocks stay untouched.
///      - `MockCrossDomainMessenger` exposes a settable `xDomainMessageSender` and can relay an arbitrary
///        call (mimicking the L2CrossDomainMessenger relaying a deposit message to the destination adapter).
///      - `MockOptimismPortalReal` keys proven/finalize on the REAL OP withdrawal hash
///        (`keccak256(abi.encode(nonce, sender, target, value, gasLimit, data))`, matching
///        `Hashing.hashWithdrawal`), so it lines up with the adapter's `_hashWithdrawal`.

/// @notice Mock L2CrossDomainMessenger with a settable xDomainMessageSender and a relay helper.
contract MockCrossDomainMessenger is ICrossDomainMessenger {
    /// @dev Source-chain sender to report during a relayed call. Settable so tests can simulate both a
    ///      trusted sibling adapter and a spoofed/unknown sender.
    address public sender;

    /// @dev Captured by `sendMessage` so a deposit test can inspect + relay the outbound completion message.
    address public lastMessageTarget;
    bytes public lastMessage;

    /// @dev Records whether a relayed cross-domain message was delivered (keyed by the versioned message hash).
    mapping(bytes32 => bool) public successfulMessages;

    function setSuccessfulMessage(bytes32 messageHash, bool ok) external {
        successfulMessages[messageHash] = ok;
    }

    function setXDomainMessageSender(address sender_) external {
        sender = sender_;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function xDomainMessageSender() external view override returns (address) {
        return sender;
    }

    /// @notice Captures an outbound cross-domain message (mirrors the L1CrossDomainMessenger enqueuing a deposit
    ///         message). The test then delivers it with `relayMessage` to the L2 sibling. Payable for parity.
    function sendMessage(address _target, bytes calldata _message, uint32) external payable override {
        lastMessageTarget = _target;
        lastMessage = _message;
    }

    /// @notice Relays `data` to `target` as `msg.sender == this messenger` (the genuine relayer), after
    ///         setting the reported source sender. Mirrors L2CrossDomainMessenger.relayMessage.
    /// @param target The destination contract (the L2 adapter)
    /// @param xSender The source-chain sender to report via xDomainMessageSender (the L1 sibling adapter)
    /// @param data The calldata to relay (e.g. completeDeposit(messagePayload))
    function relayMessage(address target, address xSender, bytes calldata data) external returns (bytes memory) {
        sender = xSender;
        (bool ok, bytes memory ret) = target.call(data);
        // Clear after relaying (matches the real messenger zeroing the transient sender).
        sender = address(0);
        require(ok, _revertReason(ret));
        return ret;
    }

    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "MockCrossDomainMessenger: relay failed";
        assembly {
            ret := add(ret, 0x04)
        }
        return abi.decode(ret, (string));
    }
}

/// @notice Mock fault-proof OptimismPortal (OP2) that keys proven withdrawals by (real OP withdrawal hash, proof
///         submitter) and finalized withdrawals globally by hash — matching the live mainnet portals (OP v5.6.1,
///         Base v5.2.0): `provenWithdrawals(bytes32,address) -> (address disputeGameProxy, uint64 timestamp)`
///         (proven ⟺ disputeGameProxy != 0), `finalizedWithdrawals(bytes32) -> bool`, and a finalize that uses
///         `msg.sender` as the proof submitter and reverts on a second call for the same hash.
contract MockOptimismPortalReal is IOptimismPortal {
    // (withdrawal hash => proof submitter => dispute game proxy) — nonzero means proven by that submitter.
    mapping(bytes32 => mapping(address => address)) private _disputeGameProxy;
    mapping(bytes32 => bool) private _finalizedWithdrawals;

    // A nonzero sentinel dispute game — the real portal records the game the withdrawal was proven against.
    address internal constant SENTINEL_GAME = address(uint160(0xDEAD));

    function _hash(Types.WithdrawalTransaction memory _tx) internal pure returns (bytes32) {
        return keccak256(abi.encode(_tx.nonce, _tx.sender, _tx.target, _tx.value, _tx.gasLimit, _tx.data));
    }

    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256,
        Types.OutputRootProof memory,
        bytes[] calldata
    ) external override {
        // Fault-proof portal keys the proof by the submitter (msg.sender = the proving adapter).
        _disputeGameProxy[_hash(_tx)][msg.sender] = SENTINEL_GAME;
    }

    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external override {
        bytes32 h = _hash(_tx);
        // Fault-proof portal uses msg.sender as the proof submitter: the finalizer must have proven it.
        require(_disputeGameProxy[h][msg.sender] != address(0), "withdrawal not proven");
        // Faithful to the real permissionless portal: reverts on a second finalize for the same hash.
        require(!_finalizedWithdrawals[h], "OptimismPortal: withdrawal has already been finalized");
        _finalizedWithdrawals[h] = true;
        if (_tx.value > 0) {
            (bool ok,) = _tx.target.call{value: _tx.value}("");
            require(ok, "ETH transfer failed");
        }
    }

    function provenWithdrawals(bytes32 _withdrawalHash, address _proofSubmitter)
        external
        view
        override
        returns (address disputeGameProxy, uint64 timestamp)
    {
        return (_disputeGameProxy[_withdrawalHash][_proofSubmitter], 0);
    }

    function finalizedWithdrawals(bytes32 _withdrawalHash) external view override returns (bool) {
        return _finalizedWithdrawals[_withdrawalHash];
    }

    receive() external payable {}
}

/// @notice Models the L1CrossDomainMessenger → L1StandardBridge relay for an ETH withdrawal: the portal delivers
///         `value` to the withdrawal `target` (this contract), which forwards it to the real recipient (the sibling
///         adapter, the `withdrawTo` receiver). Lets tests exercise the REALISTIC OP withdrawal shape where the
///         portal `target` is NOT the adapter — the shape a `L2StandardBridge.withdrawTo` withdrawal actually
///         produces. `setRecipient(address(0))` (or forwarding less) models a withdrawal that does not fund the
///         adapter, so finalize's balance-delta guard must reject it.
contract MockL1WithdrawalRelay {
    address payable public recipient;

    /// @dev Stands in for the L1CrossDomainMessenger's `successfulMessages` — the adapter's finalize skip-branch
    ///      (RE4-M-01) casts the withdrawal `target` to `ICrossDomainMessenger` and reads this to confirm delivery.
    mapping(bytes32 => bool) public successfulMessages;

    function setRecipient(address payable r) external {
        recipient = r;
    }

    function setSuccessfulMessage(bytes32 messageHash, bool ok) external {
        successfulMessages[messageHash] = ok;
    }

    receive() external payable {
        if (recipient != address(0) && msg.value > 0) {
            (bool ok,) = recipient.call{value: msg.value}("");
            require(ok, "relay forward failed");
        }
    }
}
