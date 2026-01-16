# Bridge Architecture Documentation

## Overview

The bridge system consists of two main components working together to enable secure cross-chain asset transfers:

1. **BridgeEscrow**: The central contract that manages invoice lifecycle, asset custody, and release
2. **BridgeAdapter**: Abstract base contract for bridge protocol-specific implementations

This document explains the architecture, their relationship, and the complete flow of cross-chain bridging operations.

---

## Core Components

### BridgeEscrow

**Purpose**: Central ledger and escrow contract that:
- Tracks assets in transit across chains
- Maintains invoice records on the source chain
- Validates and releases assets on the destination chain
- Manages authorized portfolio safes and bridge adapters

**Key Responsibilities**:
1. **Invoice Management**: Creates and tracks invoices with unique checksums
2. **Asset Custody**: Holds assets during bridging and releases them upon completion
3. **Access Control**: Manages authorized portfolio safes and adapters
4. **Cross-Chain Validation**: Validates invoice checksums on destination chain

**Key State Variables**:
- `invoices`: Mapping of invoice hashes to Invoice structs (source chain only)
- `completedInvoices`: Mapping tracking completed invoices (both chains)
- `assetRegistry`: Maps asset symbols to addresses
- `_authorizedPortfolioSafes`: Set of authorized portfolio safe addresses
- `_authorizedAdapters`: Set of authorized bridge adapter addresses
- `chainId`: The chain ID where this contract is deployed

**Important Design Decisions**:
- Invoices are **only stored on the source chain** for bookkeeping
- On the destination chain, only `completedInvoices` mapping is used to prevent double-spending
- Checksum validation ensures invoice authenticity without requiring invoice storage on destination

### BridgeAdapter

**Purpose**: Abstract base contract that provides:
- Standardized interface for bridge protocol integrations
- Common validation and completion logic
- Bridge protocol abstraction layer

**Key Responsibilities**:
1. **Bridge Initiation**: Receives assets and initiates bridge protocol-specific operations
2. **Bridge Completion**: Handles protocol-specific completion logic and transfers tokens to BridgeEscrow
3. **Token Transfer**: Ensures tokens are transferred from adapter to BridgeEscrow before release

**Key State Variables**:
- `bridgeEscrow`: Reference to the BridgeEscrow contract
- `bridgeProviderName`: Name of the bridge provider (e.g., "CCTP", "Across")
- `adapterVersion`: Version of the adapter implementation

**Abstract Functions**:
- `_bridge(InvoiceDataLib.InvoiceData memory data)`: Bridge-specific initiation logic
- `_completeBridge(bytes calldata messagePayload, bytes calldata protocolData)`: Bridge-specific completion logic

---

## Architecture Relationship

### Contract Hierarchy

```
BridgeEscrow (UUPS Upgradeable)
    ├── Manages invoices and asset custody
    ├── Authorizes adapters
    └── Calls adapters to initiate bridges

BridgeAdapter (Abstract, UUPS Upgradeable)
    ├── Receives calls from BridgeEscrow
    ├── Implements bridge-specific logic
    └── Calls BridgeEscrow.releaseByInvoiceId() on completion

Concrete Adapters (Extend BridgeAdapter)
    ├── CctpBridgeAdapter
    ├── AcrossBridgeAdapter
    ├── StargateBridgeAdapter
    ├── GnosisBridgeAdapter
    ├── CcipBridgeAdapter
    └── SuperchainBridgeAdapter
```

### Authorization Model

1. **Portfolio Safes**: Must be authorized in BridgeEscrow to deposit and bridge assets
2. **Bridge Adapters**: Must be authorized in BridgeEscrow to:
   - Receive bridge initiation calls
   - Call `releaseByInvoiceId()` on destination chain
3. **Operators**: Role-based access for:
   - Completing bridges (OPERATOR_ROLE in adapters)
   - Cancelling invoices (OPERATOR_ROLE in BridgeEscrow)

---

## Complete Bridge Flow

### Phase 1: Source Chain - Bridge Initiation

```
1. Portfolio Safe calls BridgeEscrow.depositAndBridge()
   ├── Validates portfolio safe is authorized
   ├── Validates adapter is authorized
   ├── Validates asset is registered
   ├── Creates invoice with BRIDGING status
   ├── Transfers assets from portfolio safe to BridgeEscrow
   ├── Transfers assets from BridgeEscrow to adapter
   └── Calls adapter.bridge(messagePayload)

2. Adapter.bridge() receives call
   ├── Validates caller is BridgeEscrow
   ├── Decodes messagePayload to InvoiceData struct
   └── Calls adapter-specific _bridge(data)

3. Adapter._bridge() implements bridge protocol
   ├── Encodes messagePayload for bridge protocol
   ├── Configures recipient (bridgeEscrow or adapter, depending on protocol)
   └── Initiates bridge via protocol (e.g., CCTP burn, Across deposit)
```

**Key Points**:
- Assets flow: Portfolio Safe → BridgeEscrow → Adapter → Bridge Protocol
- Invoice is created and stored on source chain only
- `messagePayload` contains all necessary data: invoiceId, amount, checksum, portfolioSafe, etc.

### Phase 2: Destination Chain - Bridge Completion

```
1. Bridge protocol delivers tokens and message
   ├── Tokens arrive at bridgeEscrow (CCTP, Superchain) OR
   └── Tokens arrive at adapter (Across, Stargate, Gnosis, CCIP)

2. Operator calls adapter.completeBridge(messagePayload, protocolData)
   ├── Validates operator has OPERATOR_ROLE
   ├── Validates messagePayload is not empty
   ├── Decodes messagePayload to InvoiceData struct
   ├── Validates checksum via BridgeEscrow.validateInvoiceIdChecksum()
   ├── Calls adapter-specific _completeBridge(messagePayload, protocolData)
   │   ├── Handles protocol-specific completion logic
   │   └── Transfers tokens from adapter to BridgeEscrow (if needed)
   └── Calls BridgeEscrow.releaseByInvoiceId(messagePayload)

3. BridgeEscrow.releaseByInvoiceId() validates and releases
   ├── Validates caller is authorized adapter or operator
   ├── Decodes messagePayload to extract invoice data
   ├── Validates timestamp is in the past
   ├── Validates checksum matches (security check)
   ├── Checks invoiceHash not already completed (prevents double-spending)
   ├── Validates destination chain matches
   ├── Validates portfolio safe is authorized
   ├── Validates asset is registered
   ├── Marks invoice as completed
   ├── Verifies BridgeEscrow has sufficient balance
   └── Transfers assets to portfolio safe
```

**Key Points**:
- Tokens must be in BridgeEscrow before `releaseByInvoiceId()` is called
- For protocols where tokens arrive at adapter, `_completeBridge()` transfers them to BridgeEscrow
- Checksum validation ensures invoice authenticity without requiring invoice storage on destination
- Double-spending is prevented by `completedInvoices` mapping

---

## Token Flow Patterns

### Pattern 1: Direct BridgeEscrow Delivery (CCTP, Superchain)

```
Source Chain:
  Portfolio Safe → BridgeEscrow → Adapter → Bridge Protocol

Destination Chain:
  Bridge Protocol → BridgeEscrow → Portfolio Safe
  (via adapter.completeBridge() → releaseByInvoiceId())
```

**Characteristics**:
- Bridge protocol delivers tokens directly to BridgeEscrow
- No token transfer needed in `_completeBridge()`
- Simpler flow, fewer steps

### Pattern 2: Adapter Receives, Then Transfers (Across, Stargate, Gnosis, CCIP)

```
Source Chain:
  Portfolio Safe → BridgeEscrow → Adapter → Bridge Protocol

Destination Chain:
  Bridge Protocol → Adapter → BridgeEscrow → Portfolio Safe
  (adapter receives via callback, transfers in _completeBridge())
```

**Characteristics**:
- Bridge protocol requires callback on adapter (e.g., `handleAcrossMessage`, `lzReceive`)
- Tokens arrive at adapter first
- `_completeBridge()` transfers tokens from adapter to BridgeEscrow
- Then `releaseByInvoiceId()` releases to portfolio safe

**Why This Pattern?**:
- Some bridge protocols require the recipient to implement specific callback interfaces
- Adapter implements these callbacks to receive messages
- Tokens are then transferred to BridgeEscrow for standardized release logic

---

## Invoice System

### Invoice Structure

```solidity
struct Invoice {
    bytes32 invoiceId;           // Unique identifier (32 bytes)
    uint64 sourceChainId;        // Chain where assets originate
    uint64 destinationChainId;   // Chain where assets are destined
    address portfolioSafe;       // Portfolio safe address
    address asset;               // Token address
    uint256 amount;              // Amount being bridged
    uint256 timestamp;           // Block timestamp when created
    InvoiceStatus status;        // BRIDGING, COMPLETED, or CANCELLED
}
```

### Invoice ID Encoding

The `invoiceId` is a 32-byte value encoding:
- `sourceChainId` (3 bytes, bits 232-255)
- `destinationChainId` (3 bytes, bits 208-231)
- `portfolioSafe` (20 bytes, bits 48-207)
- `assetSymbol` (6 bytes, bits 0-47)

### Checksum System

**Purpose**: Validate invoice authenticity on destination chain without storing full invoice

**Components**:
- `invoiceId`: The encoded invoice identifier
- `amount`: The amount being bridged
- `timestampByte`: Timestamp truncated to uint8
- `checksum24`: 24-byte checksum calculated as `keccak256(invoiceId || amount || timestampByte)[0:24]`

**Validation Flow**:
1. Destination chain receives `messagePayload` containing invoiceId, amount, and checksum
2. `validateInvoiceIdChecksum()` recalculates checksum from invoiceId + amount + timestampByte
3. Compares calculated checksum with provided checksum
4. Reverts if mismatch (prevents tampering)

**Security Properties**:
- Prevents amount manipulation (amount is part of checksum)
- Prevents invoice ID spoofing (invoiceId is part of checksum)
- Prevents replay attacks (timestampByte ensures freshness)
- No need to store invoices on destination chain

---

## Message Payload Format

The `messagePayload` is a standardized 96-byte (3 slot) encoding:

```
Slot 1 (32 bytes): invoiceId
Slot 2 (32 bytes): amount (uint256)
Slot 3 (32 bytes): meta
    - Byte 0: timestampByte (uint8)
    - Bytes 1-24: checksum24 (bytes24)
    - Bytes 25-31: unused
```

**Encoding/Decoding**: Handled by `InvoiceDataLib` library
- `encode(InvoiceData)`: Converts struct to messagePayload
- `decode(bytes)`: Converts messagePayload to struct

---

## Security Considerations

### Access Control

1. **Portfolio Safe Authorization**: Only authorized safes can deposit and bridge
2. **Adapter Authorization**: Only authorized adapters can:
   - Receive bridge initiation calls
   - Call `releaseByInvoiceId()` on destination chain
3. **Operator Roles**: Separate roles for:
   - Bridge completion (adapter-level)
   - Invoice cancellation (escrow-level)

### Validation Layers

1. **Checksum Validation**: Mandatory validation on destination chain
2. **Timestamp Validation**: Ensures invoice is not from the future
3. **Double-Spend Prevention**: `completedInvoices` mapping prevents replay
4. **Chain ID Validation**: Ensures release happens on correct destination chain
5. **Asset Registration**: Only registered assets can be bridged

### Token Safety

1. **Balance Verification**: BridgeEscrow verifies it has sufficient balance before release
2. **Standardized Release**: All releases go through `releaseByInvoiceId()` with validation
3. **No Direct Transfers**: Portfolio safes cannot directly receive from adapters

---

## Design Patterns

### 1. Separation of Concerns

- **BridgeEscrow**: Invoice management, asset custody, validation
- **BridgeAdapter**: Bridge protocol abstraction, protocol-specific logic
- **Concrete Adapters**: Implementation details for specific protocols

### 2. Standardized Interface

- All adapters implement the same `IBridgeAdapter` interface
- Common validation logic in `BridgeAdapter` base class
- Protocol-specific logic isolated in `_bridge()` and `_completeBridge()`

### 3. Stateless Destination Chain

- Invoices not stored on destination chain (only on source)
- Validation via checksum, not invoice lookup
- Reduces storage costs and complexity

### 4. Token Flow Standardization

- All tokens must pass through BridgeEscrow before release
- Ensures consistent validation and accounting
- Enables unified release logic regardless of bridge protocol

---

## Current Bridge Adapter Implementations

### CCTP (Circle Cross-Chain Transfer Protocol)
- **Pattern**: Direct BridgeEscrow delivery
- **Recipient**: BridgeEscrow (mints USDC directly to escrow)
- **Special**: USDC-only, requires attestation

### Across Protocol
- **Pattern**: Adapter receives, then transfers
- **Recipient**: Adapter (implements `handleAcrossMessage` callback)
- **Special**: Uses SpokePool, requires relayer fee

### Stargate Finance
- **Pattern**: Adapter receives, then transfers
- **Recipient**: Adapter (implements `lzReceive` callback)
- **Special**: Uses LayerZero, supports multiple pools

### Gnosis Omnibridge
- **Pattern**: Adapter receives, then transfers
- **Recipient**: Adapter (implements `onTokenTransfer` callback)
- **Special**: Ethereum ↔ Gnosis Chain only, uses AMB

### CCIP (Chainlink Cross-Chain Interoperability Protocol)
- **Pattern**: Adapter receives, then transfers
- **Recipient**: Adapter (implements `ccipReceive` callback)
- **Special**: Uses Chainlink router, supports programmatic fees

### Superchain (Optimism)
- **Pattern**: Direct BridgeEscrow delivery
- **Recipient**: BridgeEscrow (canonical bridge delivers directly)
- **Special**: L1 ↔ L2 only, uses OptimismPortal

---

## Error Handling

### Revert Conditions

**BridgeEscrow**:
- `InvoiceAlreadyExists`: Invoice hash already exists
- `InsufficientBalance`: BridgeEscrow doesn't have enough tokens to release
- `InvalidInvoice`: Checksum validation failed
- `NotAuthorized`: Caller not authorized
- `InvalidArguments`: Invalid parameters

**BridgeAdapter**:
- `NotAuthorized`: Caller not BridgeEscrow (bridge) or not operator (completeBridge)
- `InvalidCompletionData`: Empty or invalid messagePayload
- `InvalidInvoice`: Checksum validation failed

### Recovery Mechanisms

1. **Invoice Cancellation**: Operators can cancel invoices if bridge fails
2. **Asset Recovery**: Cancelled invoices allow assets to be returned to portfolio safe
3. **Manual Completion**: Operators can manually complete bridges if needed

---

## Future Considerations

### Potential Enhancements

1. **Batch Operations**: Support for batch bridge completions
2. **Gas Optimization**: Further optimization of storage and computation
3. **Additional Bridge Protocols**: Easy to add new adapters following the pattern
4. **Monitoring**: Enhanced event emissions for off-chain monitoring
5. **Upgradeability**: UUPS proxy pattern allows for future upgrades

### Extension Points

1. **New Bridge Protocols**: Implement `BridgeAdapter` and add `_bridge()` and `_completeBridge()`
2. **Custom Validation**: Extend validation logic in `releaseByInvoiceId()`
3. **Additional Features**: Add new functions to BridgeEscrow while maintaining compatibility

---

## Summary

The bridge architecture provides a secure, standardized, and extensible system for cross-chain asset transfers:

- **BridgeEscrow** serves as the central ledger and escrow, managing invoices and asset custody
- **BridgeAdapter** provides a standardized interface for bridge protocol integrations
- **Checksum validation** ensures security without requiring invoice storage on destination chain
- **Token flow standardization** ensures all assets pass through BridgeEscrow for consistent validation
- **Separation of concerns** allows for clean, maintainable code

The design balances security, flexibility, and gas efficiency while supporting multiple bridge protocols through a unified interface.
