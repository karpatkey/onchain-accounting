// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenMessenger} from "@chainlink/src/v0.8/ccip/pools/USDC/ITokenMessenger.sol";
import {IMessageTransmitter} from "@chainlink/src/v0.8/ccip/pools/USDC/IMessageTransmitter.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {IStargateRouter} from "src/bridge/adapters/interfaces/IStargateInterfaces.sol";
import {IOmnibridge, IAMB} from "src/bridge/adapters/interfaces/IGnosisInterfaces.sol";
import {Types} from "@optimism/libraries/Types.sol";
import {IOptimismPortal} from "src/bridge/adapters/interfaces/ISuperchainInterfaces.sol";

/// @notice Extended ERC20 with mint function for testing
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title MockBridgeProtocols
/// @notice Mock contracts for bridge protocols used in testing
/// @dev These mocks simulate bridge protocol behavior without requiring real bridge contracts

// ============ CCTP Mocks ============

/// @notice Mock TokenMessenger for CCTP
contract MockTokenMessenger is ITokenMessenger {
    using SafeERC20 for IERC20;

    uint64 public nonce;
    address private _localMessageTransmitter;
    uint32 public constant MESSAGE_BODY_VERSION = 0;
    mapping(uint32 => mapping(uint64 => bytes32)) public messageToInvoiceId; // domain -> nonce -> invoiceId

    constructor(address _messageTransmitter) {
        _localMessageTransmitter = _messageTransmitter;
    }

    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external override returns (uint64) {
        IERC20 token = IERC20(burnToken);
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Burn tokens (in real CCTP, this would burn the tokens)
        // For testing, we just hold them
        // token.burn(amount); // Would need burnable token

        nonce++;
        messageToInvoiceId[destinationDomain][nonce] = destinationCaller;

        emit DepositForBurn(
            nonce,
            burnToken,
            amount,
            msg.sender,
            mintRecipient,
            destinationDomain,
            bytes32(0), // destinationTokenMessenger
            destinationCaller
        );
        return nonce;
    }

    function messageBodyVersion() external pure override returns (uint32) {
        return MESSAGE_BODY_VERSION;
    }

    function localMessageTransmitter() external view override returns (address) {
        return _localMessageTransmitter;
    }
}

/// @notice Mock MessageTransmitter for CCTP
contract MockMessageTransmitter is IMessageTransmitter {
    using SafeERC20 for IERC20;

    uint32 private immutable _LOCAL_DOMAIN;
    uint32 public constant VERSION = 0;
    IERC20 public usdc;
    mapping(bytes32 => bool) public receivedMessages;

    constructor(uint32 _domain, address _usdc) {
        _LOCAL_DOMAIN = _domain;
        usdc = IERC20(_usdc);
    }

    event MessageReceived(bytes32 messageHash, uint32 sourceDomain, uint64 nonce);

    function receiveMessage(
        bytes calldata message,
        bytes calldata /* attestation */
    )
        external
        override
        returns (bool)
    {
        bytes32 messageHash = keccak256(message);
        require(!receivedMessages[messageHash], "Message already received");

        // Extract fields from message (simplified CCTP message format)
        // version (4 bytes), sourceDomain (4 bytes), destinationDomain (4 bytes), nonce (8 bytes)
        // sender (32 bytes), recipient (32 bytes), destinationCaller (32 bytes), messageBody (dynamic)
        require(message.length >= 116, "Message too short");

        uint32 sourceDomain = uint32(bytes4(message[4:8]));
        uint64 nonce = uint64(uint256(bytes32(message[12:20])));
        bytes32 mintRecipient = bytes32(message[52:84]);
        address recipient = address(uint160(uint256(mintRecipient)));

        receivedMessages[messageHash] = true;

        // Extract amount from messageBody (simplified - in real CCTP, this would be more complex)
        // For testing, we'll use a stored mapping or extract from messageBody
        uint256 amount = uint256(bytes32(message[116:148])); // Simplified extraction

        // Mint USDC to recipient
        // In real CCTP, USDC would be minted by the TokenMessenger contract
        // For testing, we'll mint directly
        IMintableERC20(address(usdc)).mint(recipient, amount);

        emit MessageReceived(messageHash, sourceDomain, nonce);
        return true;
    }

    function localDomain() external view override returns (uint32) {
        return _LOCAL_DOMAIN;
    }

    function version() external pure override returns (uint32) {
        return VERSION;
    }
}

// ============ CCIP Mocks ============

/// @notice Mock CCIP Router implementing IRouterClient
contract MockCcipRouter is IRouterClient {
    using SafeERC20 for IERC20;

    mapping(uint64 => bool) public supportedChains;
    uint64 public messageId;

    // Store message components separately to avoid dynamic array in storage
    mapping(uint64 => bytes) public messageData;
    mapping(uint64 => bytes) public messageReceiver;
    mapping(uint64 => address) public messageToken;
    mapping(uint64 => uint256) public messageAmount;
    mapping(uint64 => bool) public receivedMessages;

    event MessageSent(uint64 indexed messageId, address indexed sender);

    constructor() {
        // Support common chains by default
        supportedChains[5009297550715157269] = true; // Ethereum mainnet
        supportedChains[3734403246176062136] = true; // Optimism
    }

    function isChainSupported(uint64 destChainSelector) external view override returns (bool) {
        return supportedChains[destChainSelector];
    }

    function setChainSupported(uint64 destChainSelector, bool supported) external {
        supportedChains[destChainSelector] = supported;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        override
        returns (bytes32)
    {
        require(supportedChains[destinationChainSelector], "Chain not supported");

        messageId++;

        // Store message components separately
        messageData[messageId] = message.data;
        messageReceiver[messageId] = message.receiver;

        // For simplicity, only store first token amount (sufficient for tests)
        if (message.tokenAmounts.length > 0) {
            messageToken[messageId] = message.tokenAmounts[0].token;
            messageAmount[messageId] = message.tokenAmounts[0].amount;
        }

        // Transfer tokens from sender
        for (uint256 i = 0; i < message.tokenAmounts.length; i++) {
            if (message.tokenAmounts[i].token != address(0)) {
                IERC20(message.tokenAmounts[i].token)
                    .safeTransferFrom(msg.sender, address(this), message.tokenAmounts[i].amount);
            }
        }

        emit MessageSent(messageId, msg.sender);
        return bytes32(uint256(messageId));
    }

    /// @notice Returns the data payload of the last sent message (for realistic tests: read from source)
    function getLastMessageData() external view returns (bytes memory) {
        require(messageId > 0, "BridgeScenario: no message");
        return messageData[messageId];
    }

    /// @notice Add a message on "destination" for realistic delivery via deliverMessage (simulates CCIP delivery)
    /// @param data Message payload (must match what was sent from source)
    /// @param token Token address to deliver
    /// @param amount Amount to deliver to receiver
    /// @return msgId The message ID to pass to deliverMessage; caller must mint token to this contract first
    function addMessageForDelivery(bytes memory data, address token, uint256 amount) external returns (uint64 msgId) {
        messageId++;

        // Store message components separately
        messageData[messageId] = data;
        messageReceiver[messageId] = abi.encode(address(0));
        messageToken[messageId] = token;
        messageAmount[messageId] = amount;

        return messageId;
    }

    function getFee(
        uint64,
        /* destinationChainSelector */
        Client.EVM2AnyMessage memory /* message */
    )
        external
        pure
        override
        returns (uint256)
    {
        // Return a fixed fee for testing
        return 0.01 ether;
    }

    // Simulate message delivery (for testing)
    function deliverMessage(uint64 msgId, address receiver) external {
        require(!receivedMessages[msgId], "Message already delivered");
        receivedMessages[msgId] = true;

        // Retrieve message components
        bytes memory data = messageData[msgId];
        address token = messageToken[msgId];
        uint256 amount = messageAmount[msgId];

        // Transfer tokens to receiver
        if (token != address(0) && amount > 0) {
            IERC20(token).safeTransfer(receiver, amount);
        }

        // Create token amounts array
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        // Create Any2EVMMessage for ccipReceive
        Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(msgId)),
            sourceChainSelector: 5009297550715157269, // Mock source chain
            sender: abi.encode(msg.sender),
            data: data,
            destTokenAmounts: tokenAmounts
        });

        // Call receiver's ccipReceive function
        (bool receiveSuccess,) = receiver.call(
            abi.encodeWithSignature("ccipReceive((bytes32,uint64,bytes,bytes,(address,uint256)[]))", any2EvmMessage)
        );
        require(receiveSuccess, "ccipReceive failed");
    }
}

// ============ Stargate Mocks ============

/// @notice Mock Stargate Router implementing IStargateRouter
contract MockStargateRouter is IStargateRouter {
    using SafeERC20 for IERC20;

    struct MockSwapParams {
        uint16 dstChainId;
        uint256 srcPoolId;
        uint256 dstPoolId;
        address refundTo;
        uint256 amountLd;
        uint256 minAmountLd;
        bytes payload;
    }

    uint64 public messageId;
    mapping(uint64 => MockSwapParams) public swaps;
    mapping(uint64 => bool) public receivedMessages;
    address public endpoint; // Mock LayerZero endpoint

    event Swap(uint64 indexed messageId, address indexed sender, uint16 dstChainId);

    constructor() {
        endpoint = address(this); // Use self as mock endpoint
    }

    function swap(
        uint16 _lzChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLd,
        uint256 _minAmountLd,
        IStargateRouter.LzTxObj memory,
        /* _lzTxParams */
        bytes calldata,
        /* _to */
        bytes calldata _payload
    ) external payable override {
        messageId++;
        swaps[messageId] = MockSwapParams({
            dstChainId: _lzChainId,
            srcPoolId: _srcPoolId,
            dstPoolId: _dstPoolId,
            refundTo: _refundAddress,
            amountLd: _amountLd,
            minAmountLd: _minAmountLd,
            payload: _payload
        });

        // Transfer tokens from sender
        // In real Stargate, tokens would be transferred to the pool
        // For testing, we just track the swap

        emit Swap(messageId, msg.sender, _lzChainId);
    }

    /// @notice Returns the payload of the last swap (for realistic tests: read from source)
    function getLastSwapPayload() external view returns (bytes memory) {
        require(messageId > 0, "BridgeScenario: no swap");
        return swaps[messageId].payload;
    }

    /// @notice Add a swap on "destination" for realistic delivery via deliverMessage
    /// @param payload Message payload (must match what was sent from source)
    /// @return msgId The message ID to pass to deliverMessage; caller must fund this contract with token/ETH first
    function addSwapForDelivery(bytes memory payload) external returns (uint64 msgId) {
        messageId++;
        swaps[messageId] = MockSwapParams({
            dstChainId: 0,
            srcPoolId: 0,
            dstPoolId: 0,
            refundTo: address(0),
            amountLd: 0,
            minAmountLd: 0,
            payload: payload
        });
        return messageId;
    }

    function quoteLayerZeroFee(
        uint16,
        /* _dstChainId */
        uint8,
        /* _functionType */
        bytes calldata,
        /* _toAddress */
        bytes calldata,
        /* _transferAndCallPayload */
        IStargateRouter.LzTxObj memory /* _lzTxParams */
    )
        external
        pure
        override
        returns (uint256 nativeFee, uint256 zroFee)
    {
        // Return fixed fee for testing
        return (0.01 ether, 0);
    }

    // Simulate message delivery (for testing)
    function deliverMessage(uint64 msgId, address receiver, address token, uint256 amount) external {
        require(!receivedMessages[msgId], "Message already delivered");
        receivedMessages[msgId] = true;

        MockSwapParams memory swapParams = swaps[msgId];

        // Transfer tokens to receiver
        if (token != address(0)) {
            IERC20(token).safeTransfer(receiver, amount);
        } else {
            (bool transferSuccess,) = receiver.call{value: amount}("");
            require(transferSuccess, "Native transfer failed");
        }

        // Call receiver's lzReceive function (simulating LayerZero endpoint call)
        bytes memory srcAddress = abi.encodePacked(address(this));
        (bool receiveSuccess,) = receiver.call(
            abi.encodeWithSignature(
                "lzReceive(uint16,bytes,uint64,bytes)", swapParams.dstChainId, srcAddress, msgId, swapParams.payload
            )
        );
        require(receiveSuccess, "lzReceive failed");
    }
}

// ============ Across Mocks ============

/// @notice Mock Across SpokePool
contract MockSpokePool {
    using SafeERC20 for IERC20;

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        uint256 relayerFeePct;
        uint32 quoteTimestamp;
        bytes message;
    }

    uint256 public depositId;
    mapping(uint256 => Deposit) public deposits;
    mapping(uint256 => bool) public filledDeposits;

    event DepositCreated(
        address indexed depositor,
        address indexed recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 destinationChainId,
        uint256 depositId
    );

    function deposit(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 /* maxCount */
    ) external payable {
        depositId++;

        // Transfer tokens from depositor
        if (originToken != address(0)) {
            IERC20(originToken).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            require(msg.value >= amount, "Insufficient native token");
        }

        deposits[depositId] = Deposit({
            depositor: msg.sender,
            recipient: recipient,
            inputToken: originToken,
            inputAmount: amount,
            outputAmount: amount, // For testing, output equals input
            destinationChainId: destinationChainId,
            // casting to 'uint256' is safe because relayerFeePct is expected to be non-negative in tests
            // forge-lint: disable-next-line(unsafe-typecast)
            relayerFeePct: uint256(int256(relayerFeePct)),
            quoteTimestamp: quoteTimestamp,
            message: message
        });

        emit DepositCreated(msg.sender, recipient, originToken, amount, destinationChainId, depositId);
    }

    // Simulate relayer filling deposit (for testing)
    function fillDeposit(uint256 _depositId, address token, uint256 amount) external {
        require(!filledDeposits[_depositId], "Deposit already filled");
        filledDeposits[_depositId] = true;

        Deposit memory depositData = deposits[_depositId];

        // Transfer tokens to recipient
        if (token != address(0)) {
            IERC20(token).safeTransfer(depositData.recipient, amount);
        } else {
            (bool transferSuccess,) = depositData.recipient.call{value: amount}("");
            require(transferSuccess, "Native transfer failed");
        }

        // Call recipient's handleAcrossMessage function
        (bool receiveSuccess,) = depositData.recipient
            .call(
                abi.encodeWithSignature(
                    "handleAcrossMessage(address,uint256,bool,address,bytes)",
                    token,
                    amount,
                    true,
                    msg.sender,
                    depositData.message
                )
            );
        require(receiveSuccess, "handleAcrossMessage failed");
    }

    /// @notice Returns the message payload of a deposit (for realistic tests: read payload from source deposit)
    /// @param _depositId Deposit ID
    /// @return Message bytes from the deposit
    function getDepositMessage(uint256 _depositId) external view returns (bytes memory) {
        return deposits[_depositId].message;
    }

    /// @notice Add a relay deposit on "destination" for realistic tests (simulates a deposit that was initiated on source and is now filled by relayer)
    /// @param recipient Address that will receive tokens and handleAcrossMessage (e.g. destination adapter)
    /// @param message Message payload (must match what was sent from source chain)
    /// @return _depositId The deposit ID to pass to fillDeposit when simulating relay
    /// @dev Caller must fund this contract with token/ETH before fillDeposit so the transfer to recipient succeeds
    function addRelayDeposit(address recipient, bytes memory message) external returns (uint256 _depositId) {
        depositId++;
        deposits[depositId] = Deposit({
            depositor: address(0),
            recipient: recipient,
            inputToken: address(0),
            inputAmount: 0,
            outputAmount: 0,
            destinationChainId: 0,
            relayerFeePct: 0,
            quoteTimestamp: 0,
            message: message
        });
        return depositId;
    }
}

// ============ Superchain Mocks ============

/// @notice Mock L1StandardBridge
contract MockL1StandardBridge {
    using SafeERC20 for IERC20;

    event ETHDepositInitiated(address indexed from, address indexed to, uint256 amount, bytes data);
    event ERC20DepositInitiated(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    // forge-lint: disable-next-line(mixed-case-function) -- matches Optimism L1StandardBridge ABI
    function depositETHTo(
        address to,
        uint32,
        /* l2Gas */
        bytes calldata data
    )
        external
        payable
    {
        emit ETHDepositInitiated(msg.sender, to, msg.value, data);
    }

    function depositERC20To(
        address l1Token,
        address l2Token,
        address to,
        uint256 amount,
        uint32,
        /* l2Gas */
        bytes calldata data
    ) external {
        IERC20(l1Token).safeTransferFrom(msg.sender, address(this), amount);
        emit ERC20DepositInitiated(l1Token, l2Token, msg.sender, to, amount, data);
    }
}

/// @notice Mock L2StandardBridge (IL2StandardBridge 5-param withdrawTo)
contract MockL2StandardBridge {
    using SafeERC20 for IERC20;

    event ETHWithdrawalInitiated(address indexed from, address indexed to, uint256 amount, bytes data);
    event ERC20WithdrawalInitiated(
        address indexed l1Token, address indexed l2Token, address indexed from, address to, uint256 amount, bytes data
    );

    /// @dev IL2StandardBridge.withdrawTo(address _l2Token, address _to, uint256 _amount, uint32 _l1Gas, bytes _data)
    function withdrawTo(
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32,
        /* _l1Gas */
        bytes calldata _data
    )
        external
        payable
    {
        address legacyEth = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;
        if (_l2Token == legacyEth) {
            require(msg.value >= _amount, "Insufficient native token");
            emit ETHWithdrawalInitiated(msg.sender, _to, _amount, _data);
        } else {
            IERC20(_l2Token).safeTransferFrom(msg.sender, address(this), _amount);
            emit ERC20WithdrawalInitiated(_l2Token, _l2Token, msg.sender, _to, _amount, _data);
        }
    }
}

/// @notice Mock Optimism Portal for proving and finalizing L2->L1 withdrawals
contract MockOptimismPortal is IOptimismPortal {
    mapping(bytes32 => bool) private _provenWithdrawals;
    uint256 public minimumWithdrawalDelay = 0;

    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256,
        Types.OutputRootProof memory,
        bytes[] calldata
    ) external override {
        bytes32 h = keccak256(abi.encodePacked(_tx.nonce, _tx.sender, _tx.target, _tx.value, _tx.gasLimit, _tx.data));
        _provenWithdrawals[h] = true;
    }

    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external override {
        bytes32 h = keccak256(abi.encodePacked(_tx.nonce, _tx.sender, _tx.target, _tx.value, _tx.gasLimit, _tx.data));
        require(_provenWithdrawals[h], "withdrawal not proven");
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

// ============ Gnosis Mocks ============

/// @notice Mock Omnibridge implementing IOmnibridge
contract MockOmnibridge is IOmnibridge {
    using SafeERC20 for IERC20;

    event TokensBridged(address indexed token, address indexed recipient, uint256 amount, bytes data);

    function relayTokens(address _token, address _receiver, uint256 _value) external override {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _value);
        emit TokensBridged(_token, _receiver, _value, "");
    }

    bytes public lastRelayData;
    uint256 public lastRelayValue;

    function relayTokensAndCall(address token, address receiver, uint256 value, bytes memory data) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), value);
        lastRelayData = data;
        lastRelayValue = value;
        emit TokensBridged(token, receiver, value, data);

        // Simulate callback on destination chain (for testing)
        // In real Gnosis bridge, this would happen via AMB
        if (receiver.code.length > 0) {
            // onTokenTransfer signature: onTokenTransfer(address,bytes32,bytes)
            bytes32 valueBytes32 = bytes32(value);
            (bool success,) = receiver.call(
                abi.encodeWithSignature("onTokenTransfer(address,bytes32,bytes)", token, valueBytes32, data)
            );
            if (!success) {
                // If callback fails, tokens remain in bridge
            }
        }
    }

    /// @notice Returns the last relay payload and value (for realistic tests: read from source after depositAndBridge)
    function getLastRelayData() external view returns (bytes memory data, uint256 value) {
        return (lastRelayData, lastRelayValue);
    }

    // Simulate token transfer on destination chain (for testing)
    function deliverTokens(address token, address receiver, uint256 amount, bytes calldata data) external {
        IERC20(token).safeTransfer(receiver, amount);

        // Call onTokenTransfer callback
        if (receiver.code.length > 0) {
            bytes32 valueBytes32 = bytes32(amount);
            (bool success,) = receiver.call(
                abi.encodeWithSignature("onTokenTransfer(address,bytes32,bytes)", token, valueBytes32, data)
            );
            require(success, "onTokenTransfer failed");
        }
    }
}

/// @notice Mock AMB (Arbitrary Message Bridge)
contract MockAMB is IAMB {
    bytes32 public _transactionHash;

    constructor() {
        _transactionHash = keccak256("mock-transaction-hash");
    }

    function setTransactionHash(bytes32 _txHash) external {
        _transactionHash = _txHash;
    }

    function transactionHash() external view override returns (bytes32) {
        return _transactionHash;
    }

    // Implement other required IAMB functions (return default values for testing)
    function messageSender() external pure override returns (address) {
        return address(0);
    }

    function maxGasPerTx() external pure override returns (uint256) {
        return 0;
    }

    function messageId() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function messageSourceChainId() external pure override returns (bytes32) {
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
