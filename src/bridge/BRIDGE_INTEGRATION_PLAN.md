# Bridge Integration Plan

## Executive Summary

This document outlines the bridge integration status and plan for the onchain-accounting bridge system.

### Currently Integrated Bridges ✅
1. **Circle Cross-Chain Transfer Protocol (CCTP)** - Multi-chain USDC transfers
2. **Chainlink Cross-Chain Interoperability Protocol (CCIP)** - Multi-chain token and message transfers

### Planned Bridge Integrations 🔄
1. **Gnosis Bridge (Omnibridge)** - For bridging between Gnosis Chain and Ethereum
2. **Brid.gg (Optimism Canonical Bridge)** - For mainnet → L2 ETH transfers
3. **Across Protocol** - For L2 ↔ mainnet ETH transfers
4. **Stargate Finance** - For ETH transfers across multiple chains

## Current Architecture Overview

The existing bridge system follows a standardized adapter pattern:

- **BridgeEscrow**: Manages invoice bookkeeping and asset custody
- **BridgeAdapter** (abstract base): Provides standardized interface for all bridges
- **Bridge-specific adapters**: Implement bridge-specific logic (CCTP, CCIP currently)

### Key Components

1. **IBridgeAdapter Interface**:
   - `bridge(bytes32 invoiceId, bytes calldata bridgeData)` - Initiates bridge
   - `completeBridge(bytes32 invoiceId, address portfolioSafe, uint256 amount, bytes calldata bridgeData)` - Completes bridge
   - `bridgeProvider()` - Returns bridge name
   - `version()` - Returns adapter version

2. **BridgeData Library**:
   - Standardized `BridgeParams` structure (asset, amount, destinationChainId, recipient, messagePayload)
   - Standardized `CompletionParams` structure (messagePayload, protocolData)

3. **Invoice System**:
   - Invoice IDs encode: sourceChainId, destinationChainId, portfolioSafe (full 20 bytes), assetSymbol, amount (64 bytes total)
   - Checksum (32 bytes) is calculated from invoiceId using keccak256 and included in messagePayload
- messagePayload format: `abi.encode(invoiceId, amount, timestamp, checksum)`
   - Uses 3 storage slots efficiently: bytes64 (2 slots) + bytes32 (1 slot)
   - Invoices track asset movement and maintain bookkeeping
   - **CRITICAL**: messagePayload is mandatory for fund release - all bridges must preserve it

## Bridge Analysis

### 1. Circle Cross-Chain Transfer Protocol (CCTP) - ✅ INTEGRATED                                                                                                                                   

#### Architecture
- Circle's official cross-chain protocol for USDC transfers
- Uses burn-and-mint mechanism (burn on source, mint on destination)
- Built on Circle's MessageTransmitter and TokenMessenger contracts
- Supports USDC transfers across multiple chains (Ethereum, Avalanche, Base, Arbitrum, Optimism, etc.)

#### Key Contracts
- **TokenMessenger** (Source Chain): Handles token deposits and burning
- **MessageTransmitter** (Both Chains): Handles cross-chain message transmission and attestation
- **USDC Token Contracts**: Standard ERC20 USDC on each chain

#### Dependencies
- Circle's CCTP contracts (TokenMessenger, MessageTransmitter)
- USDC token contracts (must be Circle's official USDC)
- Attestation service (off-chain, provided by Circle)

#### Features
- ✅ Official Circle protocol (highly trusted)
- ✅ Native USDC support (no wrapping needed)
- ✅ Fast bridging (typically < 15 minutes)
- ✅ Message passing support (via destinationCaller)
- ✅ InvoiceId correlation via domain + nonce mapping
- ✅ Two-way bridging

#### Limitations
- ⚠️ **USDC only** (does not support other tokens or native ETH)
- ⚠️ Requires attestation service (off-chain, Circle-operated)
- ⚠️ Message passing limited (destinationCaller mechanism)
- ⚠️ Domain ID mapping required (CCTP uses domain IDs, not chain IDs)

#### Integration Considerations
- **Asset Restriction**: Only USDC is supported - adapter validates this
- **Message Passing**: Uses `destinationCaller` parameter to specify recipient contract
- **InvoiceId Correlation**: Stored in mapping using `sourceDomain + nonce` as key
- **Completion**: Requires operator to provide attestation + message for `receiveMessage()`
- **messagePayload**: Must be preserved through CCTP message (invoiceId + amount + timestamp + checksum)
- **Native Tokens**: Not supported (reverts if native token attempted)

#### Current Implementation
- **Adapter**: `CctpBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: Calls `TokenMessenger.depositForBurnWithCaller()` to burn USDC
  2. Stores invoiceId mapping: `messageToInvoiceId[sourceDomain][nonce] = invoiceId`
  3. messagePayload is provided by BridgeEscrow and must be preserved through CCTP message
  4. `_completeBridge()`: Calls `MessageTransmitter.receiveMessage()` with attestation
  5. Extracts messagePayload from CompletionParams and validates checksum
  6. BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: Domain ID mappings via `setDomainMapping()`
- **messagePayload**: ✅ Handled correctly - extracted from CompletionParams and validated

#### Implementation Approach
```solidity
// Key functions implemented:
- _bridge(): Calls tokenMessenger.depositForBurnWithCaller()
- _completeBridge(): Calls messageTransmitter.receiveMessage() with attestation
- _extractInvoiceIdFromBridgeData(): Extracts from CCTP message using domain + nonce
```

---

### 2. Chainlink Cross-Chain Interoperability Protocol (CCIP) - ✅ INTEGRATED

#### Architecture
- Chainlink's cross-chain messaging and token transfer protocol
- Uses Chainlink's decentralized oracle network for message passing
- Supports arbitrary tokens and native tokens
- Multi-chain support (Ethereum, Polygon, Avalanche, Arbitrum, Optimism, Base, etc.)
- Programmable token transfers with message payloads

#### Key Contracts
- **Router (IRouterClient)**: Main CCIP router contract on each chain
- **Fee Token**: LINK token or native token for paying fees
- **Message Receiver**: Contracts implementing `IAny2EVMMessageReceiver`

#### Dependencies
- Chainlink CCIP Router contracts
- LINK token (optional, can use native token for fees)
- Chainlink's oracle network (off-chain infrastructure)

#### Features
- ✅ Multi-chain support (10+ chains)
- ✅ Native token support (ETH and other native tokens)
- ✅ ERC20 token support
- ✅ Automatic token transfer (tokens sent before callback)
- ✅ Message passing with payload support
- ✅ InvoiceId relay in message data
- ✅ Automatic callback via `ccipReceive()`
- ✅ Fee estimation via `getFee()`

#### Limitations
- ⚠️ Requires CCIP fees (paid in LINK or native token)
- ⚠️ Chain selector mapping required (CCIP uses selectors, not chain IDs)
- ⚠️ Gas limits must be configured per chain (via extraArgs)
- ⚠️ Tokens transferred before callback (must handle in adapter)
- ⚠️ Completion still requires operator call (tokens auto-transferred, but release needs operator)

#### Integration Considerations
- **Message Passing**: messagePayload contains `abi.encode(invoiceId, amount, timestamp, checksum)`
- **messagePayload Preservation**: Must be sent in CCIP message data and preserved for completion
- **Completion**: Tokens auto-transferred by router, but `completeBridge()` still needed to release from escrow
- **Completion Requirements**: messagePayload is mandatory - must be provided in CompletionParams
- **Fee Management**: Must estimate fees before bridging, pay in LINK or native token
- **Native Tokens**: Supported natively (no wrapping required)
- **Callback**: `ccipReceive()` stores invoiceId mapping and messagePayload, but doesn't auto-complete

#### Current Implementation
- **Adapter**: `CcipBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - Estimates fee via `router.getFee()`
    - Sends messagePayload (already contains invoiceId + amount + timestamp + checksum) in CCIP message data
     - Calls `router.ccipSend()` with tokens and messagePayload
     - Stores mapping: `messageIdToInvoiceId[messageId] = invoiceId`
  2. `ccipReceive()`: Called automatically by router when message arrives
     - Extracts messagePayload from message.data
     - Stores invoiceId mapping and messagePayload for later extraction
     - Tokens already transferred to adapter
  3. `_completeBridge()`: Operator calls with messagePayload in CompletionParams
    - Extracts and validates messagePayload (invoiceId + amount + timestamp + checksum)
     - BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: Chain selector mappings via `setChainSelectorMapping()`, extraArgs per chain
- **messagePayload**: ✅ Handled correctly - preserved through CCIP messages and validated

#### Implementation Approach
```solidity
// Key functions implemented:
- _bridge(): Calls router.ccipSend() with encoded invoiceId in message data
- ccipReceive(): Automatic callback from router (stores invoiceId mapping)
- _completeBridge(): Releases funds from BridgeEscrow (operator-triggered)
- _extractInvoiceIdFromBridgeData(): Extracts from messageId mapping or message data
```

---

### 3. Gnosis Bridge (Omnibridge)

#### Architecture
- Built on Arbitrary Message Bridge (AMB)
- Uses validator set for message passing
- Supports ERC20 tokens and native tokens (ETH/xDAI)
- Two-way bridge between Ethereum and Gnosis Chain

#### Key Contracts
- **Omnibridge Contract**: Main bridge contract on each chain
- **AMB (Arbitrary Message Bridge)**: Handles cross-chain message passing
- **Mediator Contracts**: Bridge mediators on each side

#### Dependencies
- Gnosis Chain AMB contracts
- Token contracts (ERC20 or native)
- Validator set (trusted validators)

#### Features
- ✅ Supports arbitrary message passing (can relay invoiceId)
- ✅ Native token support (ETH/xDAI)
- ✅ ERC20 token support
- ✅ Two-way bridging
- ✅ Message payload support via AMB

#### Limitations
- ⚠️ Only supports Ethereum ↔ Gnosis Chain (not other L2s)
- ⚠️ Relies on validator set (trust model)
- ⚠️ Message passing may have delays
- ⚠️ Requires separate mediator contracts per chain pair

#### Integration Considerations
- **Message Passing**: Must encode messagePayload (`abi.encode(invoiceId, amount, timestamp, checksum)`) in AMB message
- **messagePayload Size**: Verify AMB supports at least 96 bytes for message payload
- **Completion**: Requires monitoring AMB messages or operator intervention
- **Completion Requirements**: messagePayload must be extracted from AMB message and provided in CompletionParams
- **Native Tokens**: Supports ETH and xDAI natively
- **Token Mapping**: May require token registration on both sides

#### Implementation Approach
```solidity
// Key functions to implement:
- _bridge(): 
  - Call omnibridge.relayTokensAndCall() with messagePayload (`abi.encode(invoiceId, amount, timestamp, checksum)`)
  - Store messagePayload mapping for later retrieval
- _completeBridge(): 
  - Extract messagePayload from AMB message or stored mapping
  - Pass messagePayload in CompletionParams
  - BridgeAdapter base class handles releaseByInvoiceId() call
- messagePayload: Must be preserved through AMB message (74 bytes)
```

---

### 4. Brid.gg (Optimism Canonical Bridge)

#### Architecture
- Uses Optimism's native canonical bridge contracts
- Leverages `L1StandardBridge` and `L2StandardBridge`
- Built on `L1CrossDomainMessenger` and `OptimismPortal`
- Supports ETH and ERC20 tokens

#### Key Contracts
- **L1StandardBridge** (Mainnet): Handles deposits from L1 → L2
- **L2StandardBridge** (L2): Handles withdrawals from L2 → L1
- **L1CrossDomainMessenger**: Handles cross-domain messaging
- **OptimismPortal**: Portal contract for L1 ↔ L2 communication

#### Dependencies
- Optimism's core contracts (L1StandardBridge, L2StandardBridge)
- Optimism's CrossDomainMessenger system
- OptimismPortal contract

#### Features
- ✅ Native ETH support
- ✅ ERC20 token support
- ✅ Two-way bridging (L1 ↔ L2)
- ✅ Secure (canonical bridge, no trust assumptions beyond Optimism)
- ✅ Fast deposits (L1 → L2)
- ✅ Message passing via CrossDomainMessenger

#### Limitations
- ⚠️ Only supports Optimism L2s (OP Mainnet, Base, etc.)
- ⚠️ Withdrawals (L2 → L1) have 7-day challenge period
- ⚠️ Deposits (L1 → L2) are fast but withdrawals are slow
- ⚠️ Limited to Superchain ecosystem
- ⚠️ Message passing requires CrossDomainMessenger integration

#### Integration Considerations
- **Deposits (L1 → L2)**: Fast, can be completed immediately
- **Withdrawals (L2 → L1)**: Require 7-day challenge period + finalization
- **Message Passing**: Must use CrossDomainMessenger to relay messagePayload (`abi.encode(invoiceId, amount, timestamp, checksum)`)
- **messagePayload Size**: Verify CrossDomainMessenger supports at least 96 bytes for message payload
- **Native ETH**: Supported natively
- **Completion**: Deposits auto-complete; withdrawals need two-step process (prove + finalize)
- **Completion Requirements**: messagePayload must be preserved through both deposit and withdrawal flows

#### Implementation Approach
```solidity
// L1 → L2 (Deposit):
- _bridge(): 
  - Call L1StandardBridge.depositETHTo() or depositERC20To() with messagePayload
  - Use CrossDomainMessenger to relay messagePayload
- _completeBridge(): 
  - Extract messagePayload from CrossDomainMessenger message
  - Pass messagePayload in CompletionParams

// L2 → L1 (Withdrawal):
- _bridge(): 
  - Call L2StandardBridge.withdrawTo() with messagePayload
  - Store messagePayload for later use
- _completeBridge(): Two-step process:
  1. Prove withdrawal (after challenge period) - preserve messagePayload
  2. Finalize withdrawal - extract messagePayload and pass in CompletionParams
```

---

### 5. Across Protocol

#### Architecture
- Uses SpokePool contracts on each chain
- Relayer network fills deposits
- Supports instant fills via liquidity pools
- Uses UMA's optimistic oracle for dispute resolution

#### Key Contracts
- **SpokePool**: Main bridge contract on each chain
- **HubPool**: Central coordination contract (on mainnet)
- **Relayer Network**: Third-party relayers that fill deposits

#### Dependencies
- Across SpokePool contracts
- Relayer network (external)
- UMA optimistic oracle (for disputes)

#### Features
- ✅ Fast fills (relayers provide liquidity)
- ✅ Supports arbitrary message passing
- ✅ Two-way bridging (L2 ↔ mainnet)
- ✅ Multiple L2 support (Arbitrum, Optimism, Polygon, etc.)
- ✅ Native ETH support
- ✅ ERC20 token support
- ✅ Composable bridging (can call recipient contract)

#### Limitations
- ⚠️ Requires relayer network (depends on liquidity)
- ⚠️ Relayer fees (relayerFeePct)
- ⚠️ Message passing requires recipient to implement `handleAcrossMessage`
- ⚠️ Relayer may not fill immediately (depends on market conditions)
- ⚠️ Recipient must be a contract to receive messages

#### Integration Considerations
- **Deposit Flow**: 
  1. Call `SpokePool.deposit()` on source chain with messagePayload
  2. Relayer fills deposit on destination chain
  3. Recipient contract receives tokens + message
- **Message Passing**: Requires adapter to be recipient and implement `handleAcrossMessage`
- **messagePayload**: Must include `abi.encode(invoiceId, amount, timestamp, checksum)` in deposit message
- **messagePayload Size**: Verify SpokePool supports at least 96 bytes for message payload
- **Completion**: Can be automatic if adapter is recipient, or operator-triggered
- **Completion Requirements**: messagePayload must be extracted from `handleAcrossMessage` and provided in CompletionParams
- **Fees**: Must account for relayer fees in amount calculations

#### Implementation Approach
```solidity
// Source Chain:
- _bridge(): 
  - Call SpokePool.deposit() with message containing messagePayload (`abi.encode(invoiceId, amount, timestamp, checksum)`)
  - Set recipient as adapter address on destination chain

// Destination Chain:
- Implement IAcrossReceiver interface:
  function handleAcrossMessage(
    address tokenSent,
    uint256 amount,
    bool fillCompleted,
    address relayer,
    bytes memory message
  ) external;
- Extract messagePayload from message parameter
- Store messagePayload for completeBridge()
- Call completeBridge() with messagePayload in CompletionParams (automatic or via operator)
```

---

### 6. Stargate Finance

#### Architecture
- Built on LayerZero protocol for cross-chain messaging
- Uses unified liquidity pools
- Supports multiple chains (Ethereum, Arbitrum, Optimism, Polygon, etc.)
- Router contract handles swaps and bridging

#### Key Contracts
- **Router**: Main contract for swaps and bridging
- **Pool Contracts**: Liquidity pools for each asset on each chain
- **LayerZero Endpoint**: LayerZero protocol endpoint

#### Dependencies
- Stargate Router contract
- LayerZero protocol
- Stargate pool contracts
- LayerZero endpoint contracts

#### Features
- ✅ Multi-chain support (10+ chains)
- ✅ Native ETH support (via WETH pools)
- ✅ ERC20 token support
- ✅ Fast bridging (typically < 30 seconds)
- ✅ Unified liquidity pools
- ✅ Message passing via LayerZero
- ✅ Payload support

#### Limitations
- ⚠️ Requires LayerZero fees (paid in native token)
- ⚠️ Pool liquidity constraints (may not have ETH pool on all chains)
- ⚠️ Slippage protection (minAmountLD parameter)
- ⚠️ Gas costs for LayerZero messaging
- ⚠️ Message passing requires LayerZero receiver implementation

#### Integration Considerations
- **Swap Function**: Use `Router.swap()` for cross-chain transfers
- **Fee Estimation**: Must call `quoteLayerZeroFee()` before swapping
- **Message Passing**: Must include messagePayload (`abi.encode(invoiceId, amount, timestamp, checksum)`) in LayerZero payload
- **messagePayload Size**: Verify LayerZero supports at least 96 bytes for payload (typically supports much larger)
- **Completion**: Can use LayerZero's `lzReceive` callback for automatic completion
- **Completion Requirements**: messagePayload must be extracted from `lzReceive` payload and provided in CompletionParams
- **Native ETH**: May need to wrap to WETH for some chains

#### Implementation Approach
```solidity
// Source Chain:
- _bridge(): 
  1. Call Router.quoteLayerZeroFee() to get fee
  2. Call Router.swap() with payload containing messagePayload (`abi.encode(invoiceId, amount, timestamp, checksum)`)
  3. Pay LayerZero fee in native token

// Destination Chain:
- Implement ILayerZeroReceiver:
  function lzReceive(
    uint16 _srcChainId,
    bytes calldata _srcAddress,
    uint64 _nonce,
    bytes calldata _payload
  ) external;
- Extract messagePayload from payload (contains invoiceId + amount + timestamp + checksum)
- Call completeBridge() with messagePayload in CompletionParams
```

---

## Implementation Plan

### Phase 1: Stargate Finance Adapter (Recommended First)

#### Tasks
1. **Research & Design** (2-3 days)
   - Review Stargate Router interface
   - Understand LayerZero integration
   - Verify LayerZero payload size limits (must support ≥96 bytes)
   - Design messagePayload encoding (`abi.encode(invoiceId, amount, timestamp, checksum)`)

2. **Implementation** (4-5 days)
   - Create `StargateBridgeAdapter.sol`
   - Implement `ILayerZeroReceiver` interface
   - Implement `_bridge()` using Router.swap() with messagePayload
   - Implement fee estimation logic
   - Implement `lzReceive()` to extract and store messagePayload
   - Implement `_completeBridge()` to pass messagePayload in CompletionParams
   - Add pool ID and chain ID mapping configuration

3. **Testing** (3-4 days)
   - Test swap flow with fee estimation
   - Test LayerZero message receiving with 96-byte messagePayload
   - Test messagePayload preservation through bridge
   - Test automatic completion via lzReceive with messagePayload
   - Test checksum validation in completion flow
   - Test with different chains and assets
   - Integration tests with BridgeEscrow

4. **Documentation** (1 day)
   - Document pool ID configuration
   - Document LayerZero fee requirements
   - Document messagePayload requirements

**Estimated Time: 10-13 days**

---

### Phase 2: Optimism Canonical Bridge Adapter

#### Tasks
1. **Research & Design** (2-3 days)
   - Review L1StandardBridge and L2StandardBridge interfaces
   - Understand CrossDomainMessenger integration
   - Verify CrossDomainMessenger message size limits (must support ≥96 bytes)
   - Design two-step withdrawal process (prove + finalize)
   - Design messagePayload preservation through deposit/withdrawal flows

2. **Implementation** (4-5 days)
   - Create `OptimismBridgeAdapter.sol`
   - Implement L1 → L2 deposit flow with messagePayload
   - Implement L2 → L1 withdrawal flow (with prove + finalize) preserving messagePayload
   - Implement CrossDomainMessenger callback handling
   - Implement `_completeBridge()` to extract and pass messagePayload in CompletionParams
   - Add chain selector mapping (L1 vs L2)

3. **Testing** (3-4 days)
   - Test L1 → L2 deposits with messagePayload preservation
   - Test L2 → L1 withdrawals (prove + finalize) with messagePayload
   - Test messagePayload extraction from CrossDomainMessenger
   - Test checksum validation in completion flow
   - Test with different assets (ETH, ERC20)
   - Integration tests with BridgeEscrow

4. **Documentation** (1 day)
   - Document withdrawal challenge period
   - Document configuration requirements
   - Document messagePayload requirements

**Estimated Time: 10-13 days**

---

### Phase 3: Across Protocol Adapter

#### Tasks
1. **Research & Design** (2-3 days)
   - Review SpokePool contract interface
   - Understand relayer network and fill mechanism
   - Verify SpokePool message size limits (must support ≥96 bytes)
   - Design `handleAcrossMessage` implementation
   - Design messagePayload encoding in deposit message

2. **Implementation** (4-5 days)
   - Create `AcrossBridgeAdapter.sol`
   - Implement `IAcrossReceiver` interface
   - Implement `_bridge()` using SpokePool.deposit() with messagePayload
   - Implement `handleAcrossMessage()` to extract messagePayload and complete bridge
   - Implement operator-triggered completion fallback with messagePayload
   - Implement `_completeBridge()` to pass messagePayload in CompletionParams
   - Add relayer fee configuration

3. **Testing** (3-4 days)
   - Test deposit flow with messagePayload
   - Test messagePayload extraction from handleAcrossMessage
   - Test message handling and automatic completion with messagePayload
   - Test operator fallback completion with messagePayload
   - Test checksum validation in completion flow
   - Test with different assets and chains
   - Integration tests with BridgeEscrow

4. **Documentation** (1 day)
   - Document relayer fee structure
   - Document message handling requirements
   - Document messagePayload requirements

**Estimated Time: 10-13 days**

---

### Phase 4: Gnosis Bridge Adapter

#### Tasks
1. **Research & Design** (2-3 days)
   - Review Omnibridge contract interfaces
   - Understand AMB message passing mechanism
   - Verify AMB message size limits (must support ≥96 bytes)
   - Design messagePayload encoding in AMB messages (`abi.encode(invoiceId, amount, timestamp, checksum)`)

2. **Implementation** (3-4 days)
   - Create `GnosisBridgeAdapter.sol`
   - Implement `_bridge()` using Omnibridge relay functions with messagePayload
   - Implement `_completeBridge()` with AMB message handling
   - Implement messagePayload extraction from AMB messages
   - Implement `_completeBridge()` to pass messagePayload in CompletionParams
   - Add domain/chain ID mapping configuration

3. **Testing** (2-3 days)
   - Unit tests for bridge initiation with messagePayload
   - Unit tests for bridge completion with messagePayload extraction
   - Test messagePayload preservation through AMB
   - Test checksum validation in completion flow
   - Integration tests with BridgeEscrow
   - Test message passing and messagePayload extraction

4. **Documentation** (1 day)
   - Document configuration requirements
   - Document limitations and use cases
   - Document messagePayload requirements

**Estimated Time: 8-11 days**

---

## Common Implementation Patterns

### 1. MessagePayload Pattern (CRITICAL)

**All adapters MUST preserve messagePayload through the bridge protocol.** The messagePayload is mandatory for fund release and contains both invoiceId and checksum.

```solidity
// BridgeEscrow creates messagePayload during depositAndBridge():
bytes memory messagePayload = abi.encode(invoiceId, amount, timestamp, checksum);
// Total size: 96 bytes (64 bytes invoiceId + 32 bytes checksum when ABI encoded)
// Storage: Uses 3 slots efficiently (bytes64 = 2 slots, bytes32 = 1 slot)

// In _bridge(): Send messagePayload through bridge protocol
// Example for CCIP:
bytes memory messageData = params.messagePayload; // Already contains invoiceId + amount + timestamp + checksum
router.ccipSend(destinationChainSelector, message);

// In _completeBridge(): Extract and validate messagePayload
bytes memory messagePayload = params.messagePayload;
(bytes32 invoiceId, uint256 amount, uint256 timestamp, bytes32 checksum) =
    abi.decode(messagePayload, (bytes32, uint256, uint256, bytes32));

// Validate checksum before releasing funds
        if (!IBridgeEscrow(bridgeEscrow).validateInvoiceIdChecksum(invoiceId, amount, timestamp, checksum)) {
    revert InvalidInvoice();
}

// BridgeAdapter.completeBridge() automatically calls:
IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
```

**Key Requirements:**
- messagePayload format: `abi.encode(invoiceId, amount, timestamp, checksum)`
- Checksum is full 32-byte keccak256 hash (better security than truncated)
- Storage efficient: Uses 3 slots (bytes64 = 2 slots, bytes32 = 1 slot)
- messagePayload MUST be preserved through bridge protocol messages
- messagePayload MUST be provided in `CompletionParams.messagePayload`
- messagePayload is MANDATORY - cannot release funds without it
- Verify bridge protocol supports at least 96 bytes for message payload

### 2. Automatic vs Operator Completion

- **Automatic**: Use bridge protocol callbacks (CCIP, Across, Stargate)
  - Callbacks must extract messagePayload from protocol messages
  - Store messagePayload for later use in completeBridge()
- **Operator**: Manual completion for bridges without callbacks (Gnosis, Optimism withdrawals)
  - Operator must provide messagePayload in CompletionParams
  - messagePayload can be retrieved from bridge protocol events or stored mappings

### 3. Chain ID Mapping

Each adapter needs chain ID mapping:
- Gnosis: Domain ID mapping
- Optimism: L1/L2 chain ID mapping
- Across: Chain ID mapping (same as standard)
- Stargate: LayerZero chain ID mapping

### 4. Native Token Handling

- Wrap native tokens if needed (e.g., ETH → WETH for Stargate)
- Handle native token transfers carefully
- Ensure proper refund mechanisms

### 5. Fee Management

- Estimate fees before bridging (Stargate, Across)
- Handle fee token approvals (if needed)
- Account for fees in amount calculations

### 6. MessagePayload Size Verification

**CRITICAL**: Before implementing each bridge, verify the protocol supports at least 96 bytes for message payloads:

- **CCIP**: ✅ Supports arbitrary payloads (no limit issue)
- **CCTP**: ⚠️ Limited message passing - verify 96 bytes supported via destinationCaller
- **Gnosis AMB**: ⚠️ Check AMB message size limits (must support ≥96 bytes)
- **Optimism CrossDomainMessenger**: ⚠️ Check message size limits (must support ≥96 bytes)
- **Across SpokePool**: ⚠️ Check message size limits in deposit() (must support ≥96 bytes)
- **Stargate/LayerZero**: ✅ Typically supports much larger payloads (verify ≥96 bytes)

**Note**: messagePayload is 96 bytes (64 bytes invoiceId + 32 bytes checksum). The checksum uses the full keccak256 hash for better security and efficient storage (3 slots total).

If a bridge protocol has size limitations, consider:
1. Using alternative encoding (if protocol allows)
2. Storing messagePayload off-chain and using a hash reference
3. Using a different bridge protocol for that use case

---

## Testing Strategy

### Unit Tests
- Bridge initiation logic with messagePayload
- Bridge completion logic with messagePayload extraction
- messagePayload preservation through bridge protocol
- Checksum validation in completion flow
- InvoiceId extraction from messagePayload
- Chain ID mapping
- Fee calculations

### Integration Tests
- Full bridge flow with BridgeEscrow
- Invoice bookkeeping verification
- Asset custody verification
- Multi-chain scenarios

### Fork Tests
- Test on mainnet forks
- Test with real bridge contracts
- Test with real assets

---

## Configuration Requirements

### CCTP (Circle) - ✅ Integrated
- TokenMessenger contract addresses (per chain)
- MessageTransmitter contract addresses (per chain)
- Domain ID mappings (chain ID → CCTP domain)

### CCIP (Chainlink) - ✅ Integrated
- Router contract addresses (per chain)
- Chain selector mappings (chain ID → CCIP selector)
- Fee token configuration (LINK or native)
- ExtraArgs per chain (gas limits, etc.)

### Gnosis Bridge
- Omnibridge contract addresses (per chain)
- AMB mediator addresses
- Domain ID mappings

### Optimism Bridge
- L1StandardBridge address (mainnet)
- L2StandardBridge addresses (per L2)
- CrossDomainMessenger addresses
- Chain ID mappings (L1 vs L2)

### Across Protocol
- SpokePool addresses (per chain)
- Relayer fee percentages
- Chain ID mappings

### Stargate Finance
- Router contract addresses (per chain)
- Pool IDs (per asset per chain)
- LayerZero endpoint addresses
- LayerZero chain ID mappings

---

## Risk Assessment

### Technical Risks
1. **Message Passing Failures**: Some bridges rely on external validators/relayers
   - Mitigation: Implement operator fallback for manual completion

2. **messagePayload Loss**: If messagePayload is lost or corrupted, funds cannot be released
   - Mitigation: Store messagePayload in adapter state, emit events, verify preservation in tests

3. **Message Size Limitations**: Some bridges may not support 96-byte payloads
   - Mitigation: Verify size limits during research phase, have fallback encoding strategies

4. **Fee Estimation Errors**: Incorrect fee estimates can cause failed transactions
   - Mitigation: Add buffer to fee estimates, implement retry logic

5. **Chain ID Mappings**: Incorrect mappings can cause funds to be sent to wrong chains
   - Mitigation: Comprehensive testing, admin controls for mapping updates

6. **Withdrawal Delays**: Optimism withdrawals have 7-day challenge period
   - Mitigation: Document clearly, implement proper status tracking

### Operational Risks
1. **Relayer Availability**: Across and Stargate depend on external relayers
   - Mitigation: Monitor relayer status, have fallback bridges

2. **Liquidity Constraints**: Stargate pools may lack liquidity
   - Mitigation: Check pool liquidity before bridging, have fallback options

3. **Bridge Protocol Upgrades**: Bridge contracts may be upgraded
   - Mitigation: Monitor bridge protocol updates, implement upgradeable adapters

---

## Dependencies & External Contracts

### Required Interfaces
- Gnosis: IOmnibridge, IAMB
- Optimism: IL1StandardBridge, IL2StandardBridge, ICrossDomainMessenger
- Across: ISpokePool, IAcrossReceiver
- Stargate: IRouter, ILayerZeroReceiver, ILayerZeroEndpoint

### External Dependencies
- OpenZeppelin contracts (already in use)
- Chainlink contracts (for CCIP reference, if needed)

---

## Success Criteria

### Already Achieved ✅
1. ✅ CCTP bridge integrated and functional
2. ✅ CCIP bridge integrated and functional
3. ✅ Invoice bookkeeping maintained correctly
4. ✅ Asset custody handled securely
5. ✅ Message passing works for invoiceId relay
6. ✅ messagePayload with checksum validation implemented
7. ✅ Mandatory messagePayload requirement for fund release enforced

### Remaining Goals
1. ✅ All four new bridges integrated and functional
2. ✅ Comprehensive test coverage (>80%) for all bridges
3. ✅ Documentation complete for all bridges
4. ✅ Configuration management in place for all bridges

---

## Timeline Estimate

- **Phase 1 (Stargate)**: 10-13 days
- **Phase 2 (Optimism)**: 10-13 days
- **Phase 3 (Across)**: 10-13 days
- **Phase 4 (Gnosis)**: 8-11 days
- **Integration & Polish**: 5-7 days

**Total Estimated Time: 43-57 days**

---

## Next Steps

1. Review and approve this plan
2. Set up development environment with bridge contract interfaces
3. Begin Phase 1 (Stargate Bridge) implementation
4. Establish testing infrastructure
5. Create configuration management system

---

## References

- [Gnosis Omnibridge Documentation](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/omnibridge)
- [Optimism Standard Bridge Documentation](https://docs.optimism.io/app-developers/guides/bridging/standard-bridge)
- [Across Protocol Documentation](https://docs.across.to/)
- [Stargate Finance Documentation](https://stargateprotocol.gitbook.io/stargate/)
- [Brid.gg Documentation](https://docs.brid.gg/)
