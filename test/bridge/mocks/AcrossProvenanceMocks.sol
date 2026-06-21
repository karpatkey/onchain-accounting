// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockSpokePoolV3
/// @notice Mock Across V3 SpokePool for the provenance-model Across adapter tests (ADR 0012).
/// @dev Implements the V3 `depositV3` entrypoint and a test-only relay/fill simulator. On a fill it transfers
///      the delivered token/amount to the recipient (the destination sibling adapter) and then calls
///      `handleV3AcrossMessage` on it — i.e. the protocol contract calls the adapter directly, as in production.
contract MockSpokePoolV3 {
    using SafeERC20 for IERC20;

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        bytes message;
    }

    uint256 public depositId;
    mapping(uint256 => Deposit) public deposits;
    mapping(uint256 => bool) public filledDeposits;

    event V3DepositCreated(
        address indexed depositor,
        address indexed recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 destinationChainId,
        uint256 depositId
    );

    /// @notice Mirrors the real SpokePool getter the adapter reads to set a valid fillDeadline.
    function fillDeadlineBuffer() external pure returns (uint32) {
        return 21_600; // 6h, a representative mainnet value
    }

    /// @notice Across V3 deposit entrypoint (subset used by the adapter)
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address, /* exclusiveRelayer */
        uint32, /* quoteTimestamp */
        uint32, /* fillDeadline */
        uint32, /* exclusivityDeadline */
        bytes calldata message
    ) external payable {
        depositId++;

        // Pull funds from the depositor (the adapter), mirroring the real SpokePool taking custody.
        if (inputToken != address(0)) {
            IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        } else {
            require(msg.value >= inputAmount, "Insufficient native token");
        }

        deposits[depositId] = Deposit({
            depositor: depositor,
            recipient: recipient,
            inputToken: inputToken,
            outputToken: outputToken,
            inputAmount: inputAmount,
            outputAmount: outputAmount,
            destinationChainId: destinationChainId,
            message: message
        });

        emit V3DepositCreated(depositor, recipient, inputToken, inputAmount, destinationChainId, depositId);
    }

    /// @notice Returns the message payload of a deposit (read the source-originated payload in round-trip tests)
    function getDepositMessage(uint256 _depositId) external view returns (bytes memory) {
        return deposits[_depositId].message;
    }

    /// @notice Register a relay deposit on the "destination" SpokePool (simulates a deposit initiated on source
    ///         that a relayer will fill here). Fund this mock with the delivery token/ETH before fillDeposit.
    /// @param recipient Address that will receive tokens and the handleV3AcrossMessage callback (dest adapter)
    /// @param message Message payload (must match what was sent from the source chain)
    /// @return _depositId The deposit id to pass to fillDeposit
    function addRelayDeposit(address recipient, bytes memory message) external returns (uint256 _depositId) {
        depositId++;
        deposits[depositId] = Deposit({
            depositor: address(0),
            recipient: recipient,
            inputToken: address(0),
            outputToken: address(0),
            inputAmount: 0,
            outputAmount: 0,
            destinationChainId: 0,
            message: message
        });
        return depositId;
    }

    /// @notice Simulate a relayer filling a V3 deposit: deliver token/amount to the recipient, then call its
    ///         handleV3AcrossMessage (the genuine protocol-driven path).
    function fillDeposit(uint256 _depositId, address token, uint256 amount) external {
        require(!filledDeposits[_depositId], "Deposit already filled");
        filledDeposits[_depositId] = true;

        Deposit memory d = deposits[_depositId];

        if (token != address(0)) {
            IERC20(token).safeTransfer(d.recipient, amount);
        } else {
            (bool ok,) = d.recipient.call{value: amount}("");
            require(ok, "Native transfer failed");
        }

        (bool receiveOk,) = d.recipient
            .call(
                abi.encodeWithSignature(
                    "handleV3AcrossMessage(address,uint256,address,bytes)", token, amount, msg.sender, d.message
                )
            );
        require(receiveOk, "handleV3AcrossMessage failed");
    }

    receive() external payable {}
}
