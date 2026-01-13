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
   - Invoice IDs encode: sourceChainId, destinationChainId, portfolioSafe (truncated), assetSymbol, checksum
   - Invoices track asset movement and maintain bookkeeping

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
- **Native Tokens**: Not supported (reverts if native token attempted)

#### Current Implementation
- **Adapter**: `CctpBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: Calls `TokenMessenger.depositForBurnWithCaller()` to burn USDC
  2. Stores invoiceId mapping: `messageToInvoiceId[sourceDomain][nonce] = invoiceId`
  3. `_completeBridge()`: Calls `MessageTransmitter.receiveMessage()` with attestation
  4. `_extractInvoiceIdFromBridgeData()`: Extracts from message using domain + nonce lookup
- **Configuration**: Domain ID mappings via `setDomainMapping()`

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
- **Message Passing**: InvoiceId encoded in message data: `abi.encode(invoiceId, messagePayload)`
- **Completion**: Tokens auto-transferred by router, but `completeBridge()` still needed to release from escrow
- **Fee Management**: Must estimate fees before bridging, pay in LINK or native token
- **Native Tokens**: Supported natively (no wrapping required)
- **Callback**: `ccipReceive()` stores invoiceId mapping, but doesn't auto-complete

#### Current Implementation
- **Adapter**: `CcipBridgeAdapter.sol`
- **Bridge Flow**:
  1. `_bridge()`: 
     - Estimates fee via `router.getFee()`
     - Encodes invoiceId in message data
     - Calls `router.ccipSend()` with tokens and message
     - Stores mapping: `messageIdToInvoiceId[messageId] = invoiceId`
  2. `ccipReceive()`: Called automatically by router when message arrives
     - Stores invoiceId mapping for later extraction
     - Tokens already transferred to adapter
  3. `_completeBridge()`: Operator calls with message data
     - Extracts invoiceId from message
     - Releases funds from BridgeEscrow
  4. `_extractInvoiceIdFromBridgeData()`: Extracts from messageId mapping or message data
- **Configuration**: Chain selector mappings via `setChainSelectorMapping()`, extraArgs per chain

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
- **Message Passing**: Can encode invoiceId in AMB message
- **Completion**: Requires monitoring AMB messages or operator intervention
- **Native Tokens**: Supports ETH and xDAI natively
- **Token Mapping**: May require token registration on both sides

#### Implementation Approach
```solidity
// Key functions to implement:
- _bridge(): Call omnibridge.relayTokens() or omnibridge.relayTokensAndCall()
- _completeBridge(): Monitor AMB messages or use operator to complete
- _extractInvoiceIdFromBridgeData(): Extract from AMB message data
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
- **Message Passing**: Can use CrossDomainMessenger to relay invoiceId
- **Native ETH**: Supported natively
- **Completion**: Deposits auto-complete; withdrawals need two-step process (prove + finalize)

#### Implementation Approach
```solidity
// L1 → L2 (Deposit):
- _bridge(): Call L1StandardBridge.depositETHTo() or depositERC20To()
- _completeBridge(): Auto-completes on L2 (can use CrossDomainMessenger callback)

// L2 → L1 (Withdrawal):
- _bridge(): Call L2StandardBridge.withdrawTo()
- _completeBridge(): Two-step process:
  1. Prove withdrawal (after challenge period)
  2. Finalize withdrawal
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
  1. Call `SpokePool.deposit()` on source chain
  2. Relayer fills deposit on destination chain
  3. Recipient contract receives tokens + message
- **Message Passing**: Requires adapter to be recipient and implement `handleAcrossMessage`
- **Completion**: Can be automatic if adapter is recipient, or operator-triggered
- **Fees**: Must account for relayer fees in amount calculations

#### Implementation Approach
```solidity
// Source Chain:
- _bridge(): Call SpokePool.deposit() with message containing invoiceId
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
- Extract invoiceId from message
- Call completeBridge() automatically or via operator
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
- **Message Passing**: Can include payload in swap call
- **Completion**: Can use LayerZero's `lzReceive` callback for automatic completion
- **Native ETH**: May need to wrap to WETH for some chains

#### Implementation Approach
```solidity
// Source Chain:
- _bridge(): 
  1. Call Router.quoteLayerZeroFee() to get fee
  2. Call Router.swap() with payload containing invoiceId
  3. Pay LayerZero fee in native token

// Destination Chain:
- Implement ILayerZeroReceiver:
  function lzReceive(
    uint16 _srcChainId,
    bytes calldata _srcAddress,
    uint64 _nonce,
    bytes calldata _payload
  ) external;
- Extract invoiceId from payload
- Call completeBridge() automatically
```

---

## Implementation Plan

### Phase 1: Stargate Finance Adapter (Recommended First)

#### Tasks
1. **Research & Design** (2-3 days)
   - Review Stargate Router interface
   - Understand LayerZero integration
   - Design payload encoding for invoiceId

2. **Implementation** (4-5 days)
   - Create `StargateBridgeAdapter.sol`
   - Implement `ILayerZeroReceiver` interface
   - Implement `_bridge()` using Router.swap()
   - Implement fee estimation logic
   - Implement `lzReceive()` for automatic completion
   - Add pool ID and chain ID mapping configuration

3. **Testing** (3-4 days)
   - Test swap flow with fee estimation
   - Test LayerZero message receiving
   - Test automatic completion via lzReceive
   - Test with different chains and assets
   - Integration tests with BridgeEscrow

4. **Documentation** (1 day)
   - Document pool ID configuration
   - Document LayerZero fee requirements

**Estimated Time: 10-13 days**

---

### Phase 2: Optimism Canonical Bridge Adapter

#### Tasks
1. **Research & Design** (2-3 days)
   - Review L1StandardBridge and L2StandardBridge interfaces
   - Understand CrossDomainMessenger integration
   - Design two-step withdrawal process (prove + finalize)

2. **Implementation** (4-5 days)
   - Create `OptimismBridgeAdapter.sol`
   - Implement L1 → L2 deposit flow
   - Implement L2 → L1 withdrawal flow (with prove + finalize)
   - Implement CrossDomainMessenger callback handling
   - Add chain selector mapping (L1 vs L2)

3. **Testing** (3-4 days)
   - Test L1 → L2 deposits
   - Test L2 → L1 withdrawals (prove + finalize)
   - Test with different assets (ETH, ERC20)
   - Integration tests with BridgeEscrow

4. **Documentation** (1 day)
   - Document withdrawal challenge period
   - Document configuration requirements

**Estimated Time: 10-13 days**

---

### Phase 3: Across Protocol Adapter

#### Tasks
1. **Research & Design** (2-3 days)
   - Review SpokePool contract interface
   - Understand relayer network and fill mechanism
   - Design `handleAcrossMessage` implementation

2. **Implementation** (4-5 days)
   - Create `AcrossBridgeAdapter.sol`
   - Implement `IAcrossReceiver` interface
   - Implement `_bridge()` using SpokePool.deposit()
   - Implement `handleAcrossMessage()` for automatic completion
   - Implement operator-triggered completion fallback
   - Add relayer fee configuration

3. **Testing** (3-4 days)
   - Test deposit flow
   - Test message handling and automatic completion
   - Test operator fallback completion
   - Test with different assets and chains
   - Integration tests with BridgeEscrow

4. **Documentation** (1 day)
   - Document relayer fee structure
   - Document message handling requirements

**Estimated Time: 10-13 days**

---

### Phase 4: Gnosis Bridge Adapter

#### Tasks
1. **Research & Design** (2-3 days)
   - Review Omnibridge contract interfaces
   - Understand AMB message passing mechanism
   - Design invoiceId encoding in messages

2. **Implementation** (3-4 days)
   - Create `GnosisBridgeAdapter.sol`
   - Implement `_bridge()` using Omnibridge relay functions
   - Implement `_completeBridge()` with AMB message handling
   - Implement `_extractInvoiceIdFromBridgeData()` from AMB messages
   - Add domain/chain ID mapping configuration

3. **Testing** (2-3 days)
   - Unit tests for bridge initiation
   - Unit tests for bridge completion
   - Integration tests with BridgeEscrow
   - Test message passing and invoiceId extraction

4. **Documentation** (1 day)
   - Document configuration requirements
   - Document limitations and use cases

**Estimated Time: 8-11 days**

---

## Common Implementation Patterns

### 1. InvoiceId Relay Pattern

All adapters should support relaying invoiceId in bridge messages:

```solidity
// Encode invoiceId in message payload
bytes memory messageData = abi.encode(invoiceId, messagePayload);

// Extract on destination
(bytes32 extractedInvoiceId, bytes memory payload) = abi.decode(messageData, (bytes32, bytes));
```

### 2. Automatic vs Operator Completion

- **Automatic**: Use bridge protocol callbacks (CCIP, Across, Stargate)
- **Operator**: Manual completion for bridges without callbacks (Gnosis, Optimism withdrawals)

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

---

## Testing Strategy

### Unit Tests
- Bridge initiation logic
- Bridge completion logic
- InvoiceId extraction
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

2. **Fee Estimation Errors**: Incorrect fee estimates can cause failed transactions
   - Mitigation: Add buffer to fee estimates, implement retry logic

3. **Chain ID Mappings**: Incorrect mappings can cause funds to be sent to wrong chains
   - Mitigation: Comprehensive testing, admin controls for mapping updates

4. **Withdrawal Delays**: Optimism withdrawals have 7-day challenge period
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
