# Verification: M-01 FluidVaultLib ABI Offset Bug

## Verdict: REFUTED

The claim that `FluidVaultLib._readUserPositionPrefix` reads fields at incorrect byte offsets is **FALSE**. The code correctly reads the intended fields.

## Evidence

### 1. ABI Encoding Analysis

**Key Rule**: When a Solidity function returns a **single struct** `returns (UserPosition memory)`, the ABI encoding is:
```
[32-byte length prefix][struct field 0][struct field 1]...[struct field N]
```

**Critically**: There is NO offset word before the struct fields. Offset words appear only in tuples with multiple return values or when struct members are dynamically typed (arrays, strings). The UserPosition struct contains only static types (uint256, address, bool, int256).

**Return signature** (src/balances/MetaBalanceAdapters/FluidVaultLib.sol, line 35):
```solidity
function positionByNftId(uint256 nftId) external view returns (UserPosition memory userPosition);
```

This is a **single return value** (not a tuple), so no offset word is prepended.

### 2. Memory Layout (Correct)

With `ret` as the returndata bytes:
- `ret[0:32]` = 384 (length prefix, 12 fields × 32 bytes)
- `ret[32:64]` = field 0 (nftId, uint256)
- `ret[64:96]` = field 1 (owner, address)
- `ret[96:128]` = **field 2 (isLiquidated, bool)** ← target read 1
- `ret[128:160]` = field 3 (isSupplyPosition, bool)
- `ret[160:192]` = field 4 (tick, int256)
- `ret[192:224]` = field 5 (tickId, uint256)
- `ret[224:256]` = field 6 (beforeSupply, uint256)
- `ret[256:288]` = field 7 (beforeBorrow, uint256)
- `ret[288:320]` = field 8 (beforeDustBorrow, uint256)
- `ret[320:352]` = **field 9 (supply, uint256)** ← target read 2
- `ret[352:384]` = **field 10 (borrow, uint256)** ← target read 3

### 3. Assembly Code Analysis (lines 103-107)

```solidity
assembly {
    let dataPtr := add(ret, 32) // skip the bytes-length prefix → points to ret[32]
    isLiquidatedWord := mload(add(dataPtr, 64))    // ret[32+64] = ret[96] = field 2 ✓
    supply := mload(add(dataPtr, 288))              // ret[32+288] = ret[320] = field 9 ✓
    borrow := mload(add(dataPtr, 320))              // ret[32+320] = ret[352] = field 10 ✓
}
```

**All three reads are correct.**

### 4. Unit Test Verification

`test/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.t.sol::FluidVaultsMetaBalanceAdapterTest::test_fanOut_collateralAndBorrow`

Test setup:
```solidity
resolver.pushNft(alice, 1, address(vaultA), 5e18, 1000e6, false);   // supply=5e18, borrow=1000e6, isLiquidated=false
resolver.pushNft(alice, 2, address(vaultB), 2e18, 1e18, false);     // supply=2e18, borrow=1e18, isLiquidated=false
```

Test assertions:
```solidity
assertEq(p.length, 4);              // 2 NFTs × 2 legs (collateral + debt)
assertEq(p[0].amount, 5e18);        // vaultA collateral
assertEq(p[1].amount, 1000e6);      // vaultA debt
assertEq(p[2].amount, 2e18);        // vaultB collateral
assertEq(p[3].amount, 1e18);        // vaultB debt
```

**Test result: PASS** ✓

If the claim were true (offsets reading wrong fields):
- With CASE B (offset word present): isLiquidated would still be false (owner=0x0), but supply would read field 8 (beforeDustBorrow=0) and borrow would read field 9 (supply=5e18)
- Expected amounts: [0, 5e18, 0, 1e18] ✗
- Actual test result: [5e18, 1000e6, 2e18, 1e18] ✓

The fact that the test passes with exact amount assertions proves the code reads the correct fields.

### 5. Mock Verification

`test/balances/MetaBalanceAdapters/FluidVaultMocks.sol` (line 50):
```solidity
function positionByNftId(uint256 nftId) external view returns (IFluidVaultResolver.UserPosition memory pos) {
    // ... sets fields ...
    return pos;  // Single struct return
}
```

The mock returns a single struct, which Solidity encodes as `[length][fields]` with no offset word. This matches CASE A.

### 6. Stale Comment Resolution

The NatSpec comment (line 95-96) mentions "(UserPosition, VaultEntireData)" suggesting a tuple return. This is misleading or stale documentation. The actual interface and mock both confirm a single return value. If the real on-chain Fluid resolver actually returns two values, the interface definition and mock would need to be updated to match.

## Conclusion

The code is **CORRECT**. The byte offsets in the assembly correctly target:
- **64 bytes** from struct start: isLiquidated (field 2) ✓
- **288 bytes** from struct start: supply (field 9) ✓  
- **320 bytes** from struct start: borrow (field 10) ✓

No fix is needed. The comment about "(UserPosition, VaultEntireData)" should be updated to clarify the actual single-struct return format.

## Recommendation

Remove or update the misleading comment at line 95-96:
```solidity
/// @notice Reads the static `UserPosition` prefix from a `(UserPosition memory)` ABI-encoded return.
```
