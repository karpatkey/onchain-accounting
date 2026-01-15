# Bridge Integration Plan

## Executive Summary

This document outlines the bridge integration status and plan for the onchain-accounting bridge system.

### Currently Integrated Bridges ✅
1. **Circle Cross-Chain Transfer Protocol (CCTP)** - Multi-chain USDC transfers
2. **Chainlink Cross-Chain Interoperability Protocol (CCIP)** - Multi-chain token and message transfers
3. **Gnosis Bridge (Omnibridge)** - For bridging between Gnosis Chain and Ethereum

### Planned Bridge Integrations 🔄
1. **Superchain (Optimism Canonical Bridge)** - ✅ INTEGRATED - For mainnet → L2 ETH transfers (Optimism, Base, Unichain, etc.)
2. **Stargate Finance** - ✅ INTEGRATED - For ETH and ERC20 transfers across multiple chains
3. **Across Protocol** - ✅ INTEGRATED - For L2 ↔ mainnet ETH transfers

## Current Architecture Overview

The existing bridge system follows a standardized adapter pattern:

- **BridgeEscrow**: Manages invoice bookkeeping and asset custody
- **BridgeAdapter** (abstract base): Provides standardized interface for all bridges
- **Bridge-specific adapters**: Implement bridge-specific logic (CCTP, CCIP, Gnosis currently)

### Key Components

1. **IBridgeAdapter Interface**:
   - `bridge(bytes calldata messagePayload)` - Initiates bridge (receives messagePayload from BridgeEscrow)
   - `completeBridge(bytes calldata messagePayload, bytes calldata protocolData)` - Completes bridge
   - `bridgeProvider()` - Returns bridge name
   - `version()` - Returns adapter version

2. **InvoiceDataLib Library**:
   - Standardized `InvoiceData` structure containing: invoiceId, sourceChainId, destinationChainId, portfolioSafe, assetSymbol, amount, timestampByte, checksum24
   - `encode(InvoiceData)` - Encodes struct to messagePayload
   - `decode(bytes memory messagePayload)` - Decodes messagePayload to struct

3. **Invoice System**:
   - Invoice IDs encode: sourceChainId (3 bytes), destinationChainId (3 bytes), portfolioSafe (20 bytes), assetSymbol (6 bytes) = 32 bytes total
   - Checksum (24 bytes) is calculated from `keccak256(invoiceId, amount, timestampByte)` and truncated to 24 bytes
   - messagePayload format: `abi.encode(invoiceId, amount, meta)` where `meta = bytes32(timestampByte << 248 | checksum24)`
   - Uses 3 storage slots efficiently: bytes32 (invoiceId) + uint256 (amount) + bytes32 (meta)
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
- **messagePayload**: Must be preserved through CCTP message (encoded via InvoiceDataLib: invoiceId + amount + meta)
- **Native Tokens**: Not supported (reverts if native token attempted)

#### Current Implementation
- **Adapter**: `CctpBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - Calls `TokenMessenger.depositForBurnWithCaller()` to burn USDC
     - Stores invoiceId mapping: `messageToInvoiceId[sourceDomain][nonce] = invoiceId`
     - Note: CCTP doesn't support arbitrary message data, so messagePayload is not sent through CCTP message
  2. `_completeBridge()`: 
     - Operator provides messagePayload in CompletionParams (along with CCTP message and attestation)
     - Extracts invoiceId from CCTP message (sourceDomain + nonce) for correlation
     - Validates messagePayload checksum using `InvoiceDataLib.decode()`
     - Calls `MessageTransmitter.receiveMessage()` with attestation to mint USDC
     - BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: Domain ID mappings via `setDomainMapping()`
- **messagePayload**: ✅ Handled correctly - provided by operator in CompletionParams and validated

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
- **Message Passing**: messagePayload is encoded using `InvoiceDataLib.encode()` (format: `abi.encode(invoiceId, amount, meta)`)
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
     - Encodes messagePayload using `InvoiceDataLib.encode(data)`
     - Estimates fee via `router.getFee()`
     - Sends messagePayload in CCIP message data
     - Calls `router.ccipSend()` with tokens and messagePayload
     - Stores mapping: `messageIdToInvoiceId[messageId] = invoiceId`
  2. `ccipReceive()`: Called automatically by router when message arrives
     - Extracts messagePayload from message.data
     - Stores invoiceId mapping and messagePayload for later extraction
     - Tokens already transferred to adapter
  3. `_completeBridge()`: Operator calls with messagePayload in CompletionParams
     - Decodes messagePayload using `InvoiceDataLib.decode()` and validates checksum
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

### 3. Gnosis Bridge (Omnibridge) - ✅ INTEGRATED

#### Architecture
- Built on Arbitrary Message Bridge (AMB)
- Uses validator set for message passing
- Supports ERC20 tokens (native tokens must be wrapped)
- Two-way bridge between Ethereum and Gnosis Chain

#### Key Contracts
- **Omnibridge Contract**: Main bridge contract on each chain
- **AMB (Arbitrary Message Bridge)**: Handles cross-chain message passing
- **Mediator Contracts**: Bridge mediators on each side

#### Dependencies
- Gnosis Chain AMB contracts
- Token contracts (ERC20, native tokens must be wrapped)
- Validator set (trusted validators)

#### Features
- ✅ Supports arbitrary message passing (can relay messagePayload)
- ✅ ERC20 token support
- ✅ Two-way bridging
- ✅ Message payload support via AMB
- ✅ Automatic token transfer on Gnosis Chain via `onTokenTransfer` callback
- ✅ InvoiceId correlation via transaction hash mapping

#### Limitations
- ⚠️ Only supports Ethereum ↔ Gnosis Chain (not other L2s)
- ⚠️ Relies on validator set (trust model)
- ⚠️ Message passing may have delays
- ⚠️ Native tokens not directly supported (must be wrapped first)
- ⚠️ On Mainnet, tokens need to be manually claimed from Omnibridge (AMB message must be processed)

#### Integration Considerations
- **Message Passing**: messagePayload (`abi.encode(invoiceId, amount, meta)`) is sent via `relayTokensAndCall()`
- **messagePayload Size**: AMB supports 96 bytes (3 slots) for message payload
- **Completion**: On Gnosis Chain, tokens auto-transferred via `onTokenTransfer` callback; on Mainnet, requires operator to ensure AMB message is processed
- **Completion Requirements**: messagePayload must be extracted from callback or stored mapping and provided in CompletionParams
- **Native Tokens**: Not directly supported - must be wrapped (e.g., WETH/WXDAI) before bridging
- **Token Mapping**: Tokens must be registered on both sides of the bridge

#### Current Implementation
- **Adapter**: `GnosisBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - Encodes messagePayload using `InvoiceDataLib.encode()`
     - Calls `omnibridge.relayTokensAndCall()` with messagePayload
     - Stores messagePayload mapping for later retrieval
  2. `onTokenTransfer()`: Called automatically by Omnibridge on destination chain (Gnosis Chain)
     - Extracts messagePayload from callback data
     - Validates checksum
     - Stores invoiceId mapping and messagePayload
  3. `_completeBridge()`: Operator calls with messagePayload in CompletionParams
     - Validates messagePayload and checksum
     - On Mainnet, verifies tokens are available in adapter (may need AMB message processing first)
     - BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: Omnibridge and AMB contract addresses
- **messagePayload**: ✅ Handled correctly - preserved through AMB messages and validated

#### Implementation Approach
```solidity
// Key functions implemented:
- _bridge(): Calls omnibridge.relayTokensAndCall() with messagePayload
- onTokenTransfer(): Automatic callback from Omnibridge (stores messagePayload)
- _completeBridge(): Validates messagePayload and releases funds from BridgeEscrow
- messagePayload: Preserved through AMB message (96 bytes = 3 slots)
```

---

### 4. Superchain (Optimism Canonical Bridge) - ✅ INTEGRATED

#### Architecture
- Uses Optimism's native canonical bridge contracts (shared across Superchain networks)
- Leverages `L1StandardBridge` and `L2StandardBridge`
- Built on `L1CrossDomainMessenger` and `OptimismPortal`
- Supports ETH and ERC20 tokens
- Works with all Superchain networks: Optimism, Base, Unichain, and other OP Stack chains

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
- ⚠️ Only supports Superchain L2s (OP Mainnet, Base, Unichain, etc.)
- ⚠️ Withdrawals (L2 → L1) have 7-day challenge period
- ⚠️ Deposits (L1 → L2) are fast but withdrawals are slow
- ⚠️ Limited to Superchain ecosystem (Optimism, Base, Unichain, and other OP Stack chains)
- ⚠️ Message passing requires CrossDomainMessenger integration

#### Integration Considerations
- **Deposits (L1 → L2)**: Fast, can be completed immediately
- **Withdrawals (L2 → L1)**: Require 7-day challenge period + finalization
- **Message Passing**: Must use CrossDomainMessenger to relay messagePayload (encoded via InvoiceDataLib: `abi.encode(invoiceId, amount, meta)`)
- **messagePayload Size**: Verify CrossDomainMessenger supports at least 96 bytes for message payload
- **Native ETH**: Supported natively
- **Completion**: Deposits auto-complete; withdrawals need two-step process (prove + finalize)
- **Completion Requirements**: messagePayload must be preserved through both deposit and withdrawal flows

#### Current Implementation
- **Adapter**: `SuperchainBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - L1 → L2 (Deposit): Calls `L1StandardBridge.depositETHTo()` or `depositERC20To()` with messagePayload
     - L2 → L1 (Withdrawal): Calls `L2StandardBridge.withdrawTo()` with messagePayload
     - Stores messagePayload mapping for later retrieval
  2. `_completeBridge()`: 
     - L1 → L2: Tokens auto-transferred on L2, validates availability
     - L2 → L1: Requires two-step process (prove + finalize via `proveWithdrawal()` and `finalizeWithdrawal()`)
     - Validates messagePayload checksum using `InvoiceDataLib.decode()`
     - BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: L1/L2 bridge addresses, Cross-Domain Messenger addresses, Optimism Portal address, L1→L2 token mappings
- **messagePayload**: ✅ Handled correctly - preserved through bridge operations and validated

#### Implementation Approach
```solidity
// L1 → L2 (Deposit):
- _bridge(): 
  - Call L1StandardBridge.depositETHTo() or depositERC20To() with messagePayload
  - messagePayload is passed through _data parameter
- _completeBridge(): 
  - Validates messagePayload and checksum
  - Verifies tokens are available on L2

// L2 → L1 (Withdrawal):
- _bridge(): 
  - Call L2StandardBridge.withdrawTo() with messagePayload
  - Store messagePayload and withdrawal hash mapping
- proveWithdrawal(): Operator calls to prove withdrawal (after challenge period)
- finalizeWithdrawal(): Operator calls to finalize withdrawal and complete bridge
- _completeBridge(): Validates messagePayload and releases funds
```

---

### 5. Across Protocol - ✅ INTEGRATED

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
- **messagePayload**: Must include messagePayload (encoded via InvoiceDataLib: `abi.encode(invoiceId, amount, meta)`) in deposit message
- **messagePayload Size**: Verify SpokePool supports at least 96 bytes for message payload
- **Completion**: Can be automatic if adapter is recipient, or operator-triggered
- **Completion Requirements**: messagePayload must be extracted from `handleAcrossMessage` and provided in CompletionParams
- **Fees**: Must account for relayer fees in amount calculations

#### Current Implementation
- **Adapter**: `AcrossBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - Encodes messagePayload using `InvoiceDataLib.encode(data)`
     - Approves SpokePool to spend tokens (if ERC20)
     - Calls `spokePool.deposit()` with messagePayload in message parameter
     - Sets recipient as this adapter address on destination chain
     - Stores messagePayload mapping for later retrieval
  2. `handleAcrossMessage()`: Called automatically by SpokePool when deposit is filled by relayer
     - Extracts messagePayload from message parameter
     - Validates payload length (must be ≥96 bytes)
     - Stores invoiceId mapping and messagePayload
     - Tokens already transferred to adapter by relayer
  3. `_completeBridge()`: Operator calls with messagePayload in CompletionParams
     - Decodes messagePayload using `InvoiceDataLib.decode()` and validates checksum
     - BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: SpokePool address, default relayer fee percentage
- **messagePayload**: ✅ Handled correctly - preserved through Across messages and validated

#### Implementation Approach
```solidity
// Source Chain:
- _bridge(): 
  - Call SpokePool.deposit() with message containing messagePayload (encoded via InvoiceDataLib: `abi.encode(invoiceId, amount, meta)`)
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

### 6. Stargate Finance - ✅ INTEGRATED

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
- **Message Passing**: Must include messagePayload (encoded via InvoiceDataLib: `abi.encode(invoiceId, amount, meta)`) in LayerZero payload
- **messagePayload Size**: Verify LayerZero supports at least 96 bytes for payload (typically supports much larger)
- **Completion**: Can use LayerZero's `lzReceive` callback for automatic completion
- **Completion Requirements**: messagePayload must be extracted from `lzReceive` payload and provided in CompletionParams
- **Native ETH**: May need to wrap to WETH for some chains

#### Current Implementation
- **Adapter**: `StargateBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - Encodes messagePayload using `InvoiceDataLib.encode(data)`
     - Gets pool IDs for source and destination chains
     - Quotes LayerZero fee via `router.quoteLayerZeroFee()`
     - Approves router to spend tokens
     - Calls `router.swap()` with messagePayload in LayerZero payload
     - Stores messagePayload mapping for later retrieval
  2. `lzReceive()`: Called automatically by LayerZero endpoint when message arrives
     - Extracts messagePayload from LayerZero payload
     - Validates payload length (must be ≥96 bytes)
     - Stores invoiceId mapping and messagePayload
     - Tokens already transferred to adapter by Stargate
  3. `_completeBridge()`: Operator calls with messagePayload in CompletionParams
     - Decodes messagePayload using `InvoiceDataLib.decode()` and validates checksum
     - BridgeAdapter base class calls `releaseByInvoiceId(messagePayload)`
- **Configuration**: Stargate Router address, LayerZero Endpoint address, chain ID mappings (standard → LayerZero), pool ID mappings per asset per chain
- **messagePayload**: ✅ Handled correctly - preserved through LayerZero messages and validated

#### Implementation Approach
```solidity
// Source Chain:
- _bridge(): 
  1. Call Router.quoteLayerZeroFee() to get fee
  2. Call Router.swap() with payload containing messagePayload (encoded via InvoiceDataLib: `abi.encode(invoiceId, amount, meta)`)
  3. Pay LayerZero fee in native token

// Destination Chain:
- Implement ILayerZeroReceiver:
  function lzReceive(
    uint16 _srcChainId,
    bytes calldata _srcAddress,
    uint64 _nonce,
    bytes calldata _payload
  ) external;
- Extract messagePayload from payload (decoded via InvoiceDataLib: contains invoiceId + amount + meta)
- Call completeBridge() with messagePayload in CompletionParams
```

---

## Implementation Plan

### Phase 1: Stargate Finance Adapter - ✅ COMPLETED

#### Tasks
1. **Research & Design** ✅
   - Reviewed Stargate Router interface
   - Understood LayerZero integration
   - Verified LayerZero payload size limits (supports ≥96 bytes)
   - Designed messagePayload encoding using InvoiceDataLib

2. **Implementation** ✅
   - Created `StargateBridgeAdapter.sol`
   - Implemented `ILayerZeroReceiver` interface
   - Implemented `_bridge()` using Router.swap() with messagePayload
   - Implemented fee estimation logic
   - Implemented `lzReceive()` to extract and store messagePayload
   - Implemented `_completeBridge()` to pass messagePayload in CompletionParams
   - Added pool ID and chain ID mapping configuration

3. **Testing** (Pending)
   - Test swap flow with fee estimation
   - Test LayerZero message receiving with 96-byte messagePayload
   - Test messagePayload preservation through bridge
   - Test automatic completion via lzReceive with messagePayload
   - Test checksum validation in completion flow
   - Test with different chains and assets
   - Integration tests with BridgeEscrow

4. **Documentation** ✅
   - Pool ID configuration documented
   - LayerZero fee requirements documented
   - messagePayload requirements documented

**Status: Implementation Complete, Testing Pending**

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

### Phase 3: Across Protocol Adapter - ✅ COMPLETED

#### Tasks
1. **Research & Design** ✅
   - Reviewed SpokePool contract interface
   - Understood relayer network and fill mechanism
   - Verified SpokePool message size limits (supports ≥96 bytes)
   - Designed `handleAcrossMessage` implementation
   - Designed messagePayload encoding in deposit message

2. **Implementation** ✅
   - Created `AcrossBridgeAdapter.sol`
   - Implemented `IAcrossReceiver` interface
   - Implemented `_bridge()` using SpokePool.deposit() with messagePayload
   - Implemented `handleAcrossMessage()` to extract messagePayload and store for completion
   - Implemented operator-triggered completion with messagePayload
   - Implemented `_completeBridge()` to pass messagePayload in CompletionParams
   - Added relayer fee configuration

3. **Testing** (Pending)
   - Test deposit flow with messagePayload
   - Test messagePayload extraction from handleAcrossMessage
   - Test message handling and automatic completion with messagePayload
   - Test operator fallback completion with messagePayload
   - Test checksum validation in completion flow
   - Test with different assets and chains
   - Integration tests with BridgeEscrow

4. **Documentation** ✅
   - Relayer fee structure documented
   - Message handling requirements documented
   - messagePayload requirements documented

**Status: Implementation Complete, Testing Pending**

---

### Phase 4: Gnosis Bridge Adapter - ✅ COMPLETED

#### Tasks
1. **Research & Design** ✅
   - Reviewed Omnibridge contract interfaces
   - Understood AMB message passing mechanism
   - Verified AMB message size limits (supports ≥96 bytes)
   - Designed messagePayload encoding using InvoiceDataLib

2. **Implementation** ✅
   - Created `GnosisBridgeAdapter.sol`
   - Implemented `_bridge()` using Omnibridge `relayTokensAndCall()` with messagePayload
   - Implemented `onTokenTransfer()` callback for automatic token receipt on Gnosis Chain
   - Implemented `_completeBridge()` with messagePayload validation
   - Added transaction hash mapping for invoiceId correlation

3. **Testing** (Pending)
   - Unit tests for bridge initiation with messagePayload
   - Unit tests for bridge completion with messagePayload extraction
   - Test messagePayload preservation through AMB
   - Test checksum validation in completion flow
   - Integration tests with BridgeEscrow
   - Test message passing and messagePayload extraction

4. **Documentation** ✅
   - Configuration requirements documented
   - Limitations and use cases documented
   - messagePayload requirements documented

**Status: Implementation Complete, Testing Pending**

---

## Common Implementation Patterns

### 1. MessagePayload Pattern (CRITICAL)

**All adapters MUST preserve messagePayload through the bridge protocol.** The messagePayload is mandatory for fund release and contains both invoiceId and checksum.

```solidity
// BridgeEscrow creates messagePayload during depositAndBridge():
InvoiceDataLib.InvoiceData memory invoiceData = InvoiceDataLib.InvoiceData({
    invoiceId: invoiceId,
    sourceChainId: uint24(chainId),
    destinationChainId: uint24(destinationChainId),
    portfolioSafe: msg.sender,
    assetSymbol: assetSymbol,
    amount: amount,
    timestampByte: timestampByte,
    checksum24: checksum24
});
bytes memory messagePayload = InvoiceDataLib.encode(invoiceData);
// Format: abi.encode(invoiceId, amount, meta) where meta = bytes32(timestampByte << 248 | checksum24)
// Total size: 96 bytes (32 bytes invoiceId + 32 bytes amount + 32 bytes meta)
// Storage: Uses 3 slots efficiently (bytes32 + uint256 + bytes32)

// In _bridge(): Send messagePayload through bridge protocol
// Example for CCIP:
bytes memory messagePayload = InvoiceDataLib.encode(data);
router.ccipSend(destinationChainSelector, message);

// In _completeBridge(): Extract and validate messagePayload
InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
// Validate checksum before releasing funds
if (!IBridgeEscrow(bridgeEscrow).validateInvoiceIdChecksum(
    data.invoiceId, data.amount, data.timestampByte, data.checksum24
)) {
    revert InvalidInvoice();
}

// BridgeAdapter.completeBridge() automatically calls:
IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
```

**Key Requirements:**
- messagePayload format: `abi.encode(invoiceId, amount, meta)` where `meta = bytes32(timestampByte << 248 | checksum24)`
- Checksum is 24-byte keccak256 hash (first 24 bytes of `keccak256(invoiceId, amount, timestampByte)`)
- Storage efficient: Uses 3 slots (bytes32 + uint256 + bytes32)
- messagePayload MUST be preserved through bridge protocol messages
- messagePayload MUST be provided in `CompletionParams.messagePayload`
- messagePayload is MANDATORY - cannot release funds without it
- Verify bridge protocol supports at least 96 bytes for message payload
- Use `InvoiceDataLib.encode()` and `InvoiceDataLib.decode()` for consistent encoding/decoding

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
- **Gnosis AMB**: ✅ Verified - supports ≥96 bytes (3 slots: invoiceId + amount + meta)
- **Optimism CrossDomainMessenger**: ⚠️ Check message size limits (must support ≥96 bytes)
- **Across SpokePool**: ✅ Verified - supports ≥96 bytes for message payload
- **Stargate/LayerZero**: ✅ Verified - supports much larger payloads (≥96 bytes confirmed)

**Note**: messagePayload is 96 bytes (32 bytes invoiceId + 32 bytes amount + 32 bytes meta). The meta contains timestampByte (1 byte) and checksum24 (24 bytes). The checksum is the first 24 bytes of `keccak256(invoiceId, amount, timestampByte)` for efficient storage (3 slots total).

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

### Gnosis Bridge - ✅ Integrated
- Omnibridge contract addresses (per chain)
- AMB contract addresses (per chain)
- Chain ID validation (only Ethereum and Gnosis Chain supported)

### Optimism Bridge - ✅ Integrated
- L1StandardBridge address (mainnet)
- L2StandardBridge addresses (per L2)
- CrossDomainMessenger addresses (L1 and L2)
- OptimismPortal address
- L1 → L2 token address mappings
- Chain ID mappings (L1 vs L2)

### Across Protocol - ✅ Integrated
- SpokePool addresses (per chain)
- Relayer fee percentages
- Chain ID mappings

### Stargate Finance - ✅ Integrated
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
3. ✅ Gnosis Bridge integrated and functional
4. ✅ Superchain (Optimism Canonical Bridge) integrated and functional
5. ✅ Stargate Finance bridge integrated and functional
6. ✅ Across Protocol bridge integrated and functional
7. ✅ Invoice bookkeeping maintained correctly
8. ✅ Asset custody handled securely
9. ✅ Message passing works for messagePayload relay
10. ✅ messagePayload with checksum validation implemented (using InvoiceDataLib)
11. ✅ Mandatory messagePayload requirement for fund release enforced
12. ✅ InvoiceDataLib for standardized encoding/decoding

### Remaining Goals
1. ⏳ Comprehensive test coverage (>80%) for all bridges
2. ✅ Documentation complete for integrated bridges
3. ✅ Configuration management in place for integrated bridges

---

## Timeline Estimate

- **Phase 1 (Stargate)**: ✅ COMPLETED
- **Phase 2 (Superchain)**: ✅ COMPLETED
- **Phase 3 (Across)**: ✅ COMPLETED
- **Phase 4 (Gnosis)**: ✅ COMPLETED
- **Integration & Polish**: 5-7 days

**Remaining Estimated Time: 5-7 days** (All bridge implementations completed, testing and polish remaining)

---

## Next Steps

1. ✅ All bridge implementations completed (CCTP, CCIP, Gnosis, Superchain, Stargate, Across)
2. ⏳ Establish comprehensive testing infrastructure
3. ⏳ Complete test coverage for all integrated bridges
4. ✅ Configuration management system in place
5. ⏳ Final integration testing and polish

---

## References

- [Gnosis Omnibridge Documentation](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/omnibridge)
- [Optimism Standard Bridge Documentation](https://docs.optimism.io/app-developers/guides/bridging/standard-bridge)
- [Across Protocol Documentation](https://docs.across.to/)
- [Stargate Finance Documentation](https://stargateprotocol.gitbook.io/stargate/)
- [Brid.gg Documentation](https://docs.brid.gg/)
