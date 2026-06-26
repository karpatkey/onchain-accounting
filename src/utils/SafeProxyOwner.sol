// SPDX-License-Identifier: MIT
// solhint-disable one-contract-per-file
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Tuple describing a call to batch through `MultiSend` and `MultiSendCallOnly`
struct Tx {
    address to;
    uint256 value;
    bytes data;
    Enum.Operation operation; // default is Call
}

/// @title      Minimal interface of a Safe used by `SafeProxyOwner`
/// @notice     Exposes only the functions that the helper contract calls
interface ISafe {
    /// @notice Execute a transaction from the Safe
    /// @param to              Destination address of the Safe transaction
    /// @param value           ETH value to send
    /// @param data            Calldata to send
    /// @param operation       0 = `call`, 1 = `delegatecall`
    /// @param safeTxGas       Gas that should be supplied to the inner call
    /// @param baseGas         Gas overhead that is charged regardless of execution
    /// @param gasPrice        Gas price used when calculating the refund
    /// @param gasToken        Token used to pay the refund (0 = ETH)
    /// @param refundReceiver  Address that receives the gas refund (0 = `tx.origin`)
    /// @param signatures      Packed signatures approving the tx
    /// @return success        True if the Safe transaction succeeded
    function execTransaction(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    /// @notice Remove an owner and optionally change the threshold
    /// @param prevOwner  Owner that precedes `owner` in the linked-list
    /// @param owner      Owner address to remove
    /// @param threshold  New confirmation threshold
    function removeOwner(address prevOwner, address owner, uint256 threshold) external;

    /// @notice Current confirmation threshold
    /// @return threshold  Number of required owner signatures
    function getThreshold() external view returns (uint256 threshold);

    /// @notice List of all current Safe owners
    /// @return owners  Array of owner addresses
    function getOwners() external view returns (address[] memory owners);
}

interface IMultiSendCallOnly {
    /**
     * @dev Executes a batch of calls and reverts if any call fails.
     * @param transactions Packed, ABI-encoded list of transactions:
     *                     ─ operation   (1 byte, must be 0 for `call`)
     *                     ─ to          (20 bytes)
     *                     ─ value       (32 bytes, uint256)
     *                     ─ dataLength  (32 bytes, uint256)
     *                     ─ data        (N bytes)
     *
     */
    function multiSend(bytes calldata transactions) external payable;
}

/// @title  Helper enum mirroring Safe's `Enum.Operation`
// solhint-disable-next-line one-contract-per-file
contract Enum {
    /// @notice Type of low-level call executed by the Safe
    enum Operation {
        /// @dev A regular `call`
        Call,
        /// @dev A `delegatecall`
        DelegateCall
    }
}

/// @title      Helper contract that can execute and approve Safe transactions
/// @author KPK
/// @notice     Deploy this contract as a temporary owner of a Safe.
///             It can dispatch transactions (using its smart-contract
///             signature) and then remove itself from the owner list.
contract SafeProxyOwner is Ownable {
    /// @notice Error thrown when the contract is not an owner of the Safe
    error NotAnOwner();

    /// @notice Error thrown when a Safe transaction fails
    error SafeTransactionFailed();

    /// @param initialOwner Address that will own this helper contract
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Address of the `MultiSendCallOnly` contract.
    /// @dev    `SafeProxyOwner` performs a single `delegatecall` into this contract
    ///         to batch-execute multiple transactions from the Safe in one go.
    ///         The address is the same on every network where Gnosis has
    ///         deployed its standard tooling (see Gnosis docs).
    address public constant MULTISEND_CALL_ONLY = address(0x40A2aCCbd92BCA938b02010E17A5b8929b49130D);

    /// @notice Execute a transaction on a Safe using this contract as the signer
    /// @param safe Address of the target Gnosis Safe
    /// @param to          Destination address for the Safe transaction
    /// @param value       ETH value to send
    /// @param data        Calldata for the Safe transaction
    /// @param operation   Operation type (0 = call, 1 = delegatecall)
    function execute(address safe, address to, uint256 value, bytes memory data, Enum.Operation operation)
        public
        onlyOwner
    {
        _execFromSafe(safe, to, value, data, operation);
    }

    /**
     * @notice Batch-execute an array of calls from the Safe via `MultiSendCallOnly`.
     * @param safe              Address of the Gnosis Safe that will execute the batch
     * @param txs               Array of calls to execute (to, value, data)
     */
    function executeMultiSend(address safe, Tx[] calldata txs) external onlyOwner {
        uint256 totalValue; // ETH forwarded to MultiSend (sum of individual `value`s)
        bytes memory packed; // Packed list of transactions for `multiSend`

        for (uint256 i; i < txs.length; ++i) {
            Tx calldata t = txs[i];
            totalValue += t.value;

            // ─ operation (1 byte = 0) │ to (20) │ value (32) │ dataLen (32) │ data (N)
            bytes memory entry = abi.encodePacked(
                t.operation, // operation: Call
                t.to,
                t.value,
                uint256(t.data.length),
                t.data
            );
            packed = bytes.concat(packed, entry);
        }

        // Build calldata for `multiSend(bytes)`
        bytes memory callData = abi.encodeWithSelector(IMultiSendCallOnly.multiSend.selector, packed);

        // Send the aggregate ETH (`totalValue`) so MultiSend can forward each call’s value
        _execFromSafe(safe, MULTISEND_CALL_ONLY, totalValue, callData, Enum.Operation.DelegateCall);
    }

    /// @notice Remove this helper contract from the owner list of a Safe
    /// @dev    Discovers its predecessor in the linked list and dispatches
    ///         a `removeOwner` transaction via `executeOnSafe`
    /// @param safe Address of the target Safe
    function removeThisOwner(address safe) external onlyOwner {
        address[] memory owners = ISafe(safe).getOwners();
        address prev = address(0x1); // SENTINEL_OWNERS
        for (uint256 i = 0; i < owners.length; ++i) {
            if (owners[i] == address(this)) {
                bytes memory callData =
                    abi.encodeCall(ISafe.removeOwner, (prev, address(this), ISafe(safe).getThreshold()));
                _execFromSafe(safe, safe, 0, callData, Enum.Operation.Call);
                return;
            }
            prev = owners[i];
        }
        revert NotAnOwner();
    }

    /**
     * @notice Builds a 65-byte “pre-approved hash” signature for this contract.
     * @dev    The signature encodes `address(this)` in **r**, zero in **s**,
     *         and sets **v = 1** (the Safe’s sentinel for contract signatures).
     *         When `_execFromSafe` passes this blob to `execTransaction`,
     *         the Safe treats it as a valid signature coming from this helper.
     * @return sig A 65-byte `(r, s, v)` signature.
     */
    function _selfSignature() private view returns (bytes memory sig) {
        sig = new bytes(65);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(add(sig, 0x20), address()) // r = address(this)
            mstore(add(sig, 0x40), 0) // s = 0
            mstore8(add(sig, 0x60), 1) // v = 1
        }
    }

    /**
     * @notice Execute an arbitrary call from the Safe, signed by this contract.
     * @dev    Internally forwards the call to `ISafe.execTransaction`, passing
     *         the “pre-approved hash” signature built by `_selfSignature`.
     *
     * @param safe       Address of the Gnosis Safe that will perform the call.
     * @param to         Destination address for the Safe transaction.
     * @param value      ETH amount (in wei) to forward with the call.
     * @param data       Calldata that will be sent to `to`.
     * @param operation  0 = `call`, 1 = `delegatecall` (mirrors `Enum.Operation`).
     *
     * @custom:reverts  If the underlying Safe transaction returns `false`.
     */
    function _execFromSafe(address safe, address to, uint256 value, bytes memory data, Enum.Operation operation)
        private
    {
        bool ok = ISafe(safe)
            .execTransaction(
                to,
                value,
                data,
                operation,
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                payable(address(0)),
                _selfSignature()
            );
        if (!ok) revert SafeTransactionFailed();
    }
}
