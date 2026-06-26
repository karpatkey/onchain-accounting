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

    function setXDomainMessageSender(address sender_) external {
        sender = sender_;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function xDomainMessageSender() external view override returns (address) {
        return sender;
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

/// @notice Mock OptimismPortal that keys proven/finalize on the REAL OP withdrawal hash (abi.encode).
contract MockOptimismPortalReal is IOptimismPortal {
    mapping(bytes32 => bool) private _provenWithdrawals;
    uint256 public minimumWithdrawalDelay = 0;

    function _hash(Types.WithdrawalTransaction memory _tx) internal pure returns (bytes32) {
        return keccak256(abi.encode(_tx.nonce, _tx.sender, _tx.target, _tx.value, _tx.gasLimit, _tx.data));
    }

    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256,
        Types.OutputRootProof memory,
        bytes[] calldata
    ) external override {
        _provenWithdrawals[_hash(_tx)] = true;
    }

    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external override {
        require(_provenWithdrawals[_hash(_tx)], "withdrawal not proven");
        if (_tx.value > 0) {
            (bool ok,) = _tx.target.call{value: _tx.value}("");
            require(ok, "ETH transfer failed");
        }
    }

    function provenWithdrawals(bytes32 _withdrawalHash) external view override returns (bool) {
        return _provenWithdrawals[_withdrawalHash];
    }

    receive() external payable {}
}
