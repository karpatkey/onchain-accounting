# BridgeEscrow & BridgeAdapter Development Plan

## Overview

This document outlines the development plan for implementing a bridge escrow system that tracks assets in transit across chains, ensuring accurate NAV accounting during cross-chain operations.

## Architecture Overview

```
┌─────────────────┐
│ Portfolio Safe  │
│  (Source Chain)  │
└────────┬────────┘
         │ depositAndBridge()
         ▼
┌─────────────────┐
│ BridgeEscrow    │ ◄─── Tracks in-transit assets
│  (Per Chain)    │      Maintains invoice ledger
└────────┬────────┘
         │ (immediately)
         ▼
┌─────────────────┐
│ BridgeAdapter   │ ◄─── Bridge-specific logic
│  (CCTP/Gnosis)  │      (Abstract base)
└────────┬────────┘
         │
         ▼
    [Bridge Protocol]
         │
         ▼
┌─────────────────┐
│ BridgeEscrow    │ ◄─── Receives on destination
│ (Dest. Chain)   │
└────────┬────────┘
         │ release()
         ▼
┌─────────────────┐
│ Portfolio Safe  │
│ (Dest. Chain)   │
└─────────────────┘
```

---

## 1. Invoice System Design

### 1.1 Invoice Structure

Every bridge operation generates a unique invoice identifier that can be tracked off-chain.

```solidity
struct Invoice {
    bytes32 invoiceId;           // Unique identifier: keccak256(sourceChainId, destChainId, portfolioSafe, globalNonce)
    uint64 sourceChainId;        // Chain ID where assets originate
    uint64 destinationChainId;   // Chain ID where assets are destined
    address portfolioSafe;       // Portfolio Safe address (same on both chains)
    uint256 globalNonce;         // Incrementing counter per portfolioSafe
    address asset;               // Token address (address(0) for native)
    uint256 amount;              // Amount being bridged
    uint256 timestamp;           // Block timestamp when invoice created
    InvoiceStatus status;        // Current status of the invoice
}

enum InvoiceStatus {
    BRIDGING,     // Bridge adapter has initiated the bridge
    COMPLETED,    // Assets successfully received on destination
    CANCELLED     // Invoice cancelled (e.g., bridge failure recovery)
}
```

### 1.2 Invoice ID Generation

```solidity
function _generateInvoiceId(
    uint64 sourceChainId,
    uint64 destinationChainId,
    address portfolioSafe,
    uint256 nonce
) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(
        sourceChainId,
        destinationChainId,
        portfolioSafe,
        nonce
    ));
}
```

### 1.3 Invoice Storage

- **Mapping**: `mapping(bytes32 invoiceId => Invoice) public invoices`
- **Nonce Tracking**: `mapping(address portfolioSafe => uint256) public nonces`
- **Active Invoices**: `mapping(address portfolioSafe => bytes32[]) public activeInvoices`
- **Asset Balances**: `mapping(address asset => uint256) public inTransitBalances`

---

## 2. BridgeEscrow Contract Design

### 2.1 Contract Structure

```solidity
contract BridgeEscrow is
    Initializable,
    AccessControlUpgradeable,
    IBridgeEscrow
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
}
```

### 2.2 State Variables

```solidity
// Access Control
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

// Invoice Management
mapping(bytes32 => Invoice) public invoices;
mapping(address => uint256) public nonces; // per portfolioSafe
mapping(address => EnumerableSet.Bytes32Set) private _activeInvoices; // per portfolioSafe

// Asset Tracking
mapping(address => uint256) public inTransitBalances; // asset => total in-transit amount

// Authorized Entities
EnumerableSet.AddressSet private _authorizedPortfolioSafes;
EnumerableSet.AddressSet private _authorizedAdapters;

// Chain Configuration
uint64 public chainId;

// Events
event InvoiceCreated(
    bytes32 indexed invoiceId,
    address indexed portfolioSafe,
    address indexed asset,
    uint256 amount,
    uint64 sourceChainId,
    uint64 destinationChainId,
    uint256 nonce
);

event InvoiceStatusUpdated(
    bytes32 indexed invoiceId,
    InvoiceStatus oldStatus,
    InvoiceStatus newStatus
);

event AssetsDeposited(
    bytes32 indexed invoiceId,
    address indexed asset,
    uint256 amount
);

event AssetsReleased(
    bytes32 indexed invoiceId,
    address indexed asset,
    uint256 amount,
    address indexed recipient
);

event PortfolioSafeAuthorized(address indexed safe);
event PortfolioSafeRevoked(address indexed safe);
event AdapterAuthorized(address indexed adapter);
event AdapterRevoked(address indexed adapter);
```

### 2.3 Core Functions

#### 2.3.1 Initialization

```solidity
function initialize(
    address admin_,
    uint64 chainId_,
    address[] memory initialPortfolioSafes,
    address[] memory initialAdapters
) external initializer {
    __AccessControl_init();
    
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    chainId = chainId_;
    
    // Authorize initial portfolio safes
    for (uint256 i = 0; i < initialPortfolioSafes.length; i++) {
        _authorizePortfolioSafe(initialPortfolioSafes[i]);
    }
    
    // Authorize initial adapters
    for (uint256 i = 0; i < initialAdapters.length; i++) {
        _authorizeAdapter(initialAdapters[i]);
    }
}
```

#### 2.3.2 Deposit and Bridge (Atomic Operation)

The deposit and bridge operations are combined into a single atomic function to eliminate the need for separate transactions and ensure deposits are immediately bridged.

```solidity
function depositAndBridge(
    uint64 destinationChainId,
    address asset,
    uint256 amount,
    address adapter,
    bytes calldata bridgeData
) external payable nonReentrant returns (bytes32 invoiceId) {
    // Only authorized portfolio safes can deposit
    if (!_authorizedPortfolioSafes.contains(msg.sender)) {
        revert NotAuthorized();
    }
    
    // Verify adapter is authorized
    if (!_authorizedAdapters.contains(adapter)) {
        revert NotAuthorized();
    }
    
    if (amount == 0) revert InvalidArguments();
    if (destinationChainId == chainId) revert InvalidArguments(); // Can't bridge to same chain
    
    // Increment nonce for this portfolio safe
    uint256 nonce = ++nonces[msg.sender];
    
    // Generate invoice ID
    invoiceId = _generateInvoiceId(chainId, destinationChainId, msg.sender, nonce);
    
    // Create invoice with BRIDGING status (since we bridge immediately)
    Invoice memory invoice = Invoice({
        invoiceId: invoiceId,
        sourceChainId: chainId,
        destinationChainId: destinationChainId,
        portfolioSafe: msg.sender,
        globalNonce: nonce,
        asset: asset,
        amount: amount,
        timestamp: block.timestamp,
        status: InvoiceStatus.BRIDGING
    });
    
    invoices[invoiceId] = invoice;
    _activeInvoices[msg.sender].add(invoiceId);
    
    // Transfer assets from portfolio safe
    if (asset == address(0)) {
        // Native token
        if (msg.value != amount) revert InvalidArguments();
        // Contract already holds native tokens via receive()
    } else {
        // ERC20 token
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }
    
    // Update in-transit balances
    inTransitBalances[asset] += amount;
    inTransitBalancesBySafe[msg.sender][asset] += amount;
    
    emit InvoiceCreated(
        invoiceId,
        msg.sender,
        asset,
        amount,
        chainId,
        destinationChainId,
        nonce
    );
    
    emit AssetsDeposited(invoiceId, asset, amount);
    
    // Immediately transfer assets to adapter
    if (asset == address(0)) {
        // Native token
        (bool success,) = adapter.call{value: amount}("");
        if (!success) revert TransferFailed();
    } else {
        // ERC20 token
        IERC20(asset).safeTransfer(adapter, amount);
    }
    
    // Call adapter's bridge function
    IBridgeAdapter(adapter).bridge(invoiceId, asset, amount, bridgeData);
}
```

#### 2.3.3 Release (Outflow to Portfolio Safe)

```solidity
function release(
    bytes32 invoiceId,
    bytes32 sourceInvoiceId, // Invoice ID from source chain (for verification)
    uint64 sourceChainId,
    address portfolioSafe,
    address asset,
    uint256 amount
) external nonReentrant {
    // Only authorized adapters can release (after bridge completion)
    if (!_authorizedAdapters.contains(msg.sender)) {
        revert NotAuthorized();
    }
    
    // Verify portfolio safe is authorized
    if (!_authorizedPortfolioSafes.contains(portfolioSafe)) {
        revert NotAuthorized();
    }
    
    // Verify invoice doesn't already exist (prevent double-release)
    if (invoices[invoiceId].invoiceId != bytes32(0)) {
        revert InvoiceAlreadyExists();
    }
    
    // Create completion invoice
    Invoice memory invoice = Invoice({
        invoiceId: invoiceId,
        sourceChainId: sourceChainId,
        destinationChainId: chainId,
        portfolioSafe: portfolioSafe,
        globalNonce: 0, // Not used for destination invoices
        asset: asset,
        amount: amount,
        timestamp: block.timestamp,
        status: InvoiceStatus.COMPLETED
    });
    
    invoices[invoiceId] = invoice;
    
    // Decrease in-transit balance
    if (inTransitBalances[asset] < amount) revert InsufficientBalance();
    inTransitBalances[asset] -= amount;
    
    // Transfer assets to portfolio safe
    if (asset == address(0)) {
        (bool success,) = portfolioSafe.call{value: amount}("");
        if (!success) revert TransferFailed();
    } else {
        IERC20(asset).safeTransfer(portfolioSafe, amount);
    }
    
    emit InvoiceStatusUpdated(invoiceId, InvoiceStatus.BRIDGING, InvoiceStatus.COMPLETED);
    emit AssetsReleased(invoiceId, asset, amount, portfolioSafe);
}
```

#### 2.3.4 Cancel Invoice (Recovery Mechanism)

```solidity
function cancelInvoice(bytes32 invoiceId) external onlyRole(OPERATOR_ROLE) {
    Invoice storage invoice = invoices[invoiceId];
    
    if (invoice.invoiceId == bytes32(0)) revert InvoiceNotFound();
    if (invoice.status == InvoiceStatus.COMPLETED) revert InvalidInvoiceStatus();
    if (invoice.status == InvoiceStatus.CANCELLED) revert InvalidInvoiceStatus();
    
    InvoiceStatus oldStatus = invoice.status;
    invoice.status = InvoiceStatus.CANCELLED;
    
    // Decrease in-transit balances (assets are with adapter, but we stop tracking them)
    address asset = invoice.asset;
    uint256 amount = invoice.amount;
    inTransitBalances[asset] -= amount;
    inTransitBalancesBySafe[invoice.portfolioSafe][asset] -= amount;
    
    // Note: Assets are already with the adapter when status is BRIDGING,
    // so we cannot return them here. The adapter must handle asset recovery
    // if the bridge fails and cancellation is needed.
    
    // Remove from active invoices
    _activeInvoices[invoice.portfolioSafe].remove(invoiceId);
    
    emit InvoiceStatusUpdated(invoiceId, oldStatus, InvoiceStatus.CANCELLED);
}
```

#### 2.3.5 View Functions

```solidity
function getInvoice(bytes32 invoiceId) external view returns (Invoice memory) {
    return invoices[invoiceId];
}

function getActiveInvoices(address portfolioSafe) 
    external 
    view 
    returns (bytes32[] memory) 
{
    return _activeInvoices[portfolioSafe].values();
}

function getInTransitBalance(address asset) external view returns (uint256) {
    return inTransitBalances[asset];
}

function isAuthorizedPortfolioSafe(address safe) external view returns (bool) {
    return _authorizedPortfolioSafes.contains(safe);
}

function isAuthorizedAdapter(address adapter) external view returns (bool) {
    return _authorizedAdapters.contains(adapter);
}
```

#### 2.3.6 Admin Functions

```solidity
function authorizePortfolioSafe(address safe) 
    external 
    onlyRole(DEFAULT_ADMIN_ROLE) 
{
    _authorizePortfolioSafe(safe);
    emit PortfolioSafeAuthorized(safe);
}

function revokePortfolioSafe(address safe) 
    external 
    onlyRole(DEFAULT_ADMIN_ROLE) 
{
    _authorizedPortfolioSafes.remove(safe);
    emit PortfolioSafeRevoked(safe);
}

function authorizeAdapter(address adapter) 
    external 
    onlyRole(DEFAULT_ADMIN_ROLE) 
{
    _authorizeAdapter(adapter);
    emit AdapterAuthorized(adapter);
}

function revokeAdapter(address adapter) 
    external 
    onlyRole(DEFAULT_ADMIN_ROLE) 
{
    _authorizedAdapters.remove(adapter);
    emit AdapterRevoked(adapter);
}

function _authorizePortfolioSafe(address safe) internal {
    if (safe == address(0)) revert InvalidArguments();
    _authorizedPortfolioSafes.add(safe);
}

function _authorizeAdapter(address adapter) internal {
    if (adapter == address(0)) revert InvalidArguments();
    // Verify adapter implements IBridgeAdapter interface
    if (!IBridgeAdapter(adapter).supportsInterface(type(IBridgeAdapter).interfaceId)) {
        revert InvalidArguments();
    }
    _authorizedAdapters.add(adapter);
}
```

### 2.4 Error Definitions

```solidity
error InvoiceNotFound();
error InvoiceAlreadyExists();
error InvalidInvoiceStatus();
error TransferFailed();
error InsufficientBalance();
```

---

## 3. BridgeAdapter Base Contract Design

### 3.1 Interface Definition

```solidity
interface IBridgeAdapter {
    /// @notice Initiates a bridge operation
    /// @param invoiceId The invoice ID from BridgeEscrow
    /// @param asset The token address (address(0) for native)
    /// @param amount The amount to bridge
    /// @param bridgeData Bridge-specific data (encoded parameters)
    function bridge(
        bytes32 invoiceId,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) external;
    
    /// @notice Completes a bridge operation on destination chain
    /// @param invoiceId The invoice ID for the destination
    /// @param sourceInvoiceId The invoice ID from source chain
    /// @param sourceChainId The source chain ID
    /// @param portfolioSafe The portfolio safe address
    /// @param asset The token address
    /// @param amount The amount received
    /// @param bridgeData Bridge-specific completion data
    function completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) external;
    
    /// @notice Returns the bridge provider name (e.g., "CCTP", "Gnosis")
    function bridgeProvider() external view returns (string memory);
    
    /// @notice Returns the bridge adapter version
    function version() external view returns (string memory);
}
```

### 3.2 Base Contract Structure

```solidity
abstract contract BridgeAdapter is IBridgeAdapter, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    address public bridgeEscrow;
    string public bridgeProviderName;
    string public adapterVersion;
    
    event BridgeInitiated(
        bytes32 indexed invoiceId,
        address indexed asset,
        uint256 amount
    );
    
    event BridgeCompleted(
        bytes32 indexed invoiceId,
        bytes32 indexed sourceInvoiceId,
        uint64 sourceChainId
    );
    
    function initialize(
        address admin_,
        address bridgeEscrow_,
        string memory providerName_,
        string memory version_
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        bridgeEscrow = bridgeEscrow_;
        bridgeProviderName = providerName_;
        adapterVersion = version_;
    }
    
    /// @notice Must be implemented by concrete adapters
    function bridge(
        bytes32 invoiceId,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) external override {
        // Verify caller is BridgeEscrow
        if (msg.sender != bridgeEscrow) revert NotAuthorized();
        
        _bridge(invoiceId, asset, amount, bridgeData);
        
        emit BridgeInitiated(invoiceId, asset, amount);
    }
    
    /// @notice Must be implemented by concrete adapters
    function completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) external override {
        // Verify caller is authorized (could be operator or bridge protocol callback)
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        _completeBridge(
            invoiceId,
            sourceInvoiceId,
            sourceChainId,
            portfolioSafe,
            asset,
            amount,
            bridgeData
        );
        
        // Call BridgeEscrow.release()
        IBridgeEscrow(bridgeEscrow).release(
            invoiceId,
            sourceInvoiceId,
            sourceChainId,
            portfolioSafe,
            asset,
            amount
        );
        
        emit BridgeCompleted(invoiceId, sourceInvoiceId, sourceChainId);
    }
    
    /// @notice Abstract function - implement bridge-specific logic
    function _bridge(
        bytes32 invoiceId,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) internal virtual;
    
    /// @notice Abstract function - implement bridge-specific completion logic
    function _completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) internal virtual;
    
    function bridgeProvider() external view override returns (string memory) {
        return bridgeProviderName;
    }
    
    function version() external view override returns (string memory) {
        return adapterVersion;
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return interfaceId == type(IBridgeAdapter).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
```

### 3.3 Example: CCTP Adapter

```solidity
contract CCTPAdapter is BridgeAdapter {
    // CCTP-specific contracts
    address public tokenMessenger;
    address public messageTransmitter;
    
    // Track pending bridges
    mapping(bytes32 => bytes32) public invoiceToMessageHash;
    
    function initialize(
        address admin_,
        address bridgeEscrow_,
        address tokenMessenger_,
        address messageTransmitter_
    ) external initializer {
        __BridgeAdapter_init(admin_, bridgeEscrow_, "CCTP", "1.0.0");
        tokenMessenger = tokenMessenger_;
        messageTransmitter = messageTransmitter_;
    }
    
    function _bridge(
        bytes32 invoiceId,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) internal override {
        // Decode bridge data: (destinationDomain, recipient)
        (uint32 destinationDomain, bytes32 recipient) = abi.decode(
            bridgeData,
            (uint32, bytes32)
        );
        
        // Approve token messenger
        IERC20(asset).safeApprove(tokenMessenger, amount);
        
        // Deposit for burn
        ITokenMessenger(tokenMessenger).depositForBurn(
            amount,
            destinationDomain,
            recipient,
            asset
        );
        
        // Store message hash for tracking
        // Note: Actual message hash would be retrieved from event or return value
        // This is simplified for illustration
    }
    
    function _completeBridge(
        bytes32 invoiceId,
        bytes32 sourceInvoiceId,
        uint64 sourceChainId,
        address portfolioSafe,
        address asset,
        uint256 amount,
        bytes calldata bridgeData
    ) internal override {
        // Verify message attestation
        // Decode message and attestation from bridgeData
        (bytes memory message, bytes memory attestation) = abi.decode(
            bridgeData,
            (bytes, bytes)
        );
        
        // Verify attestation
        require(
            IMessageTransmitter(messageTransmitter).receiveMessage(
                message,
                attestation
            ),
            "Invalid attestation"
        );
        
        // Bridge completion verified, release will be called by parent
    }
}
```

---

## 4. Accounting Logic Integration

### 4.1 NAV Aggregation Formula

The total NAV calculation now includes in-transit assets:

```
NAV_total = NAV_calculator + Σ(BridgeEscrow.inTransitBalances[asset] × price[asset])
```

### 4.2 Integration with NAVCalculator

#### Option A: Extend NAVCalculator with Bridge Balance Oracle

Create a new balance oracle type that reads from BridgeEscrow:

```solidity
contract BridgeEscrowBalanceOracle is IBalanceOracleCustom {
    address public bridgeEscrow;
    
    function balanceOf(address account, address underlyingAsset) 
        external 
        view 
        override 
        returns (int256) 
    {
        // Only return balance if account matches expected portfolio safe
        // This requires BridgeEscrow to track which portfolio safe owns which assets
        return IBridgeEscrow(bridgeEscrow).getInTransitBalanceFor(
            account,
            underlyingAsset
        ).toInt256();
    }
}
```

#### Option B: Off-Chain Aggregation

- Query `NAVCalculator.read(portfolioSafe)` for on-chain assets
- Query `BridgeEscrow.getInTransitBalance(asset)` for each asset
- Sum both values off-chain

### 4.3 BridgeEscrow Balance Tracking Enhancement

To support Option A, add per-portfolio-safe tracking:

```solidity
// Additional state in BridgeEscrow
mapping(address portfolioSafe => mapping(address asset => uint256)) 
    public inTransitBalancesBySafe;

function getInTransitBalanceFor(
    address portfolioSafe,
    address asset
) external view returns (uint256) {
    return inTransitBalancesBySafe[portfolioSafe][asset];
}

// Update in depositAndBridge():
inTransitBalancesBySafe[msg.sender][asset] += amount;

// Update in release():
inTransitBalancesBySafe[portfolioSafe][asset] -= amount;

// Update in cancelInvoice():
inTransitBalancesBySafe[invoice.portfolioSafe][asset] -= amount;
```

---

## 5. Security Considerations

### 5.1 Access Control

- **DEFAULT_ADMIN_ROLE**: Full control (authorize/revoke safes and adapters)
- **OPERATOR_ROLE**: Can cancel invoices (recovery mechanism)
- **Authorized Adapters**: Can bridge and release (verified by address in authorized set)
- **Portfolio Safes**: Can only deposit (no direct access role, verified by address)

### 5.2 Reentrancy Protection

- State updates before external calls (checks-effects-interactions pattern)
- Careful ordering of operations to prevent reentrancy vulnerabilities

### 5.3 Input Validation

- Zero address checks
- Zero amount checks
- Same-chain bridge prevention
- Invoice status validation
- Nonce uniqueness enforcement

### 5.4 Asset Safety

- Assets held in escrow until bridge completion
- No arbitrary transfers - only to authorized safes/adapters
- Emergency cancellation mechanism for stuck bridges

### 5.5 Invoice Integrity

- Invoice IDs are deterministic and cannot be forged
- Nonce prevents replay attacks
- Status transitions are strictly controlled
- Source invoice verification on destination

---

## 6. Implementation Phases

### Phase 1: Core Infrastructure
1. ✅ Define Invoice structure and storage
2. ✅ Implement BridgeEscrow base contract
3. ✅ Implement access control and authorization
4. ✅ Add depositAndBridge (atomic deposit+bridge), release functions
5. ✅ Add view functions for accounting

### Phase 2: BridgeAdapter System
1. ✅ Define IBridgeAdapter interface
2. ✅ Implement BridgeAdapter base contract
3. ✅ Create example CCTP adapter
4. ✅ Create example Gnosis adapter (if needed)

### Phase 3: Accounting Integration
1. ✅ Add per-portfolio-safe balance tracking
2. ✅ Create BridgeEscrowBalanceOracle
3. ✅ Integrate with NAVCalculator
4. ✅ Test NAV aggregation accuracy

### Phase 4: Testing & Security
1. ✅ Unit tests for all functions
2. ✅ Integration tests with mock adapters
3. ✅ Fuzz testing for edge cases
4. ✅ Security audit preparation

### Phase 5: Deployment
1. ✅ Deploy BridgeEscrow on each chain
2. ✅ Deploy adapters for each bridge protocol
3. ✅ Authorize portfolio safes
4. ✅ Monitor and verify accounting accuracy

---

## 7. File Structure

```
src/
├── bridge/
│   ├── IBridgeEscrow.sol          # Interface
│   ├── BridgeEscrow.sol            # Main contract
│   ├── IBridgeAdapter.sol          # Adapter interface
│   ├── BridgeAdapter.sol           # Base adapter
│   └── adapters/
│       ├── CCTPAdapter.sol         # CCTP implementation
│       └── GnosisAdapter.sol       # Gnosis implementation
├── balances/
│   └── protocols/
│       └── BridgeEscrowBalanceOracle.sol  # Balance oracle for NAV
└── errors.sol                       # Add bridge-specific errors
```

---

## 8. Key Design Decisions

1. **One BridgeEscrow per chain**: Simplifies deployment and reduces cross-chain complexity
2. **Invoice-based tracking**: Provides off-chain traceability and audit trail
3. **Modular adapters**: Allows adding new bridges without modifying core escrow
4. **Strict access control**: Only authorized safes and adapters can interact
5. **In-transit balance tracking**: Enables accurate NAV calculation
6. **Status-based state machine**: Prevents invalid state transitions
7. **Nonce per portfolio safe**: Ensures unique invoice IDs per safe

---

## 9. Open Questions & Future Enhancements

1. **Multi-asset invoices**: Should one invoice support multiple assets?
2. **Partial bridge completion**: Handle partial amounts if bridge supports it?
3. **Bridge fee tracking**: Should fees be tracked separately in invoices?
4. **Time-based expiration**: Should pending invoices expire after a timeout?
5. **Cross-chain invoice verification**: On-chain verification of source invoices?
6. **Bridge adapter upgradeability**: Should adapters be upgradeable? (Note: BridgeEscrow is not upgradeable)

---

## 10. Testing Strategy

### Unit Tests
- Invoice creation and ID generation
- DepositAndBridge atomic operation
- Release flows
- Access control enforcement
- Error conditions
- Balance tracking accuracy

### Integration Tests
- Full bridge flow (source → destination) with atomic depositAndBridge
- Multiple concurrent bridges
- Adapter integration
- NAV calculation with in-transit assets

### Fuzz Tests
- Random invoice parameters
- Edge case amounts
- Concurrent operations
- State transition sequences

---

## Appendix: Error Definitions

```solidity
// Add to src/errors.sol
error InvoiceNotFound();
error InvoiceAlreadyExists();
error InvalidInvoiceStatus();
error TransferFailed();
error InsufficientBalance();
error InvalidChainId();
error InvalidNonce();
```

