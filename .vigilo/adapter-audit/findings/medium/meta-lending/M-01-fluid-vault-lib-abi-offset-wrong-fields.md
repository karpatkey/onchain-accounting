# M-01: FluidVaultLib `_readUserPositionPrefix` reads wrong struct fields due to incorrect ABI byte offsets

## Summary

`FluidVaultLib._readUserPositionPrefix` hard-codes byte offsets assuming that the struct's field data begins at `dataPtr + 0`, but Solidity ABI-encodes a single `memory struct` return value with a 32-byte offset pointer at `dataPtr + 0`, so the struct data actually begins at `dataPtr + 32`. Every field read is therefore off by one slot (32 bytes): `isLiquidated` reads `owner`, `supply` reads `beforeDustBorrow`, and `borrow` reads `supply`. As a result, liquidated positions are NOT skipped (they are always treated as active), and the reported collateral and debt amounts are taken from wrong fields.

## Vulnerability Detail

### Root Cause

Solidity ABI-encodes a function that returns `(SomeStruct memory)` as:

```
word 0 (dataPtr + 0): offset pointer = 0x20 (32)
word 1 (dataPtr + 32): struct field 0 (nftId)
word 2 (dataPtr + 64): struct field 1 (owner)
word 3 (dataPtr + 96): struct field 2 (isLiquidated)
...
word 10 (dataPtr + 320): struct field 9 (supply)
word 11 (dataPtr + 352): struct field 10 (borrow)
```

The `UserPosition` struct (11 fields, 12 words including dustBorrow):
```
field 0 (offset   0): uint256  nftId
field 1 (offset  32): address  owner
field 2 (offset  64): bool     isLiquidated
field 3 (offset  96): bool     isSupplyPosition
field 4 (offset 128): int256   tick
field 5 (offset 160): uint256  tickId
field 6 (offset 192): uint256  beforeSupply
field 7 (offset 224): uint256  beforeBorrow
field 8 (offset 256): uint256  beforeDustBorrow
field 9 (offset 288): uint256  supply
field 10 (offset 320): uint256 borrow
field 11 (offset 352): uint256 dustBorrow
```

With the struct starting at `dataPtr + 32`, the absolute offsets from `dataPtr` are:
- `isLiquidated` → `dataPtr + 32 + 64 = dataPtr + 96`
- `supply`       → `dataPtr + 32 + 288 = dataPtr + 320`
- `borrow`       → `dataPtr + 32 + 320 = dataPtr + 352`

### Code Location

- File: `src/balances/MetaBalanceAdapters/FluidVaultLib.sol`
- Function: `_readUserPositionPrefix`
- Lines: 97–110

```solidity
// @audit The NatSpec comment says isLiquidated@64, supply@288, borrow@320, but these are
//        offsets from the STRUCT start (dataPtr+32), not from dataPtr. The correct absolute
//        offsets from dataPtr are: isLiquidated@96, supply@320, borrow@352.
function _readUserPositionPrefix(bytes memory ret)
    private
    pure
    returns (uint256 supply, uint256 borrow, bool isLiquidated)
{
    uint256 isLiquidatedWord;
    assembly {
        let dataPtr := add(ret, 32) // skip the bytes-length prefix
        isLiquidatedWord := mload(add(dataPtr, 64))    // @audit reads owner (field 1), not isLiquidated (field 2)
        supply := mload(add(dataPtr, 288))              // @audit reads beforeDustBorrow (field 8), not supply (field 9)
        borrow := mload(add(dataPtr, 320))              // @audit reads supply (field 9), not borrow (field 10)
    }
    isLiquidated = isLiquidatedWord != 0;
}
```

### Concrete miscalculation

For a position with `owner = 0xABCD...`, `isLiquidated = true`, `supply = 5e18`, `borrow = 1000e6`, the assembly reads:

| Read intent  | Code offset  | Actual field read         | Value returned  |
|-------------|-------------|--------------------------|----------------|
| isLiquidated | dataPtr+64  | owner (address 0xABCD…)  | non-zero → `isLiquidated = true` (accidentally correct for non-zero owner) |
| isLiquidated | dataPtr+64  | owner (address(0) in mocks) | 0 → `isLiquidated = false` (WRONG — liquidated position treated as active) |
| supply       | dataPtr+288  | beforeDustBorrow          | 0 (pre-op dust)  |
| borrow       | dataPtr+320  | supply                    | 5e18 (actual supply reported as borrow) |

The unit test `test_liquidatedPosition_skipped` uses a mock resolver that always sets `owner = address(0)`. As a result:
- `isLiquidatedWord = owner = 0` → `isLiquidated = false` → liquidated position is NOT skipped
- `supply = beforeDustBorrow = 0` → collateral leg is zero (dropped)
- `borrow = supply = 5e18` → debt leg is 5e18 of the collateral token (the SUPPLY amount reported as borrow of the DEBT token)

The test expects 0 positions but receives 1 mislabeled debt position. The test should fail, which confirms the off-by-32 bug is present. The fork test `test_metaBalance_doesNotRevert` does not assert on amounts, so it does not catch this.

## Impact

- **Likelihood**: High — every real Fluid T1 vault NFT has a non-zero owner; the wrong field reads affect every real account
- **Impact**: Medium — positions are mis-reported: liquidated positions are treated as active (if owner happens to be non-zero, they ARE skipped — this is correct by accident); supply amounts may appear as debt, borrow amounts may be dropped; NAV is incorrect for any account holding Fluid T1 vault positions
- **Severity**: MEDIUM

For a non-liquidated position with non-zero owner: `isLiquidatedWord = owner ≠ 0` → treated as liquidated → position SILENTLY DROPPED. All real Fluid T1 vault positions are silently excluded from NAV since every NFT has a non-zero owner. This is effectively a silent under-report of all Fluid T1 vault collateral and debt.

## Attack Scenario

This is not directly exploitable by an external attacker. The consequence is NAV mis-reporting:

1. Account holds collateral and debt in a Fluid T1 vault (wstETH/USDC).
2. `FluidVaultsMetaBalanceAdapter.getAdapterPositions` is called.
3. `FluidVaultLib.aggregate` staticcalls the resolver for each NFT.
4. `_readUserPositionPrefix` reads `owner` (non-zero for every real NFT) as `isLiquidated`.
5. `isLiquidated = true` → position is skipped → aggregate returns `(0, 0)`.
6. Collateral and debt are both reported as zero for the account.
7. NAV is overstated (debt not captured) and the collateral leg is also missing.

### Expected vs Actual

- Expected: NFT with `supply=5e18 wstETH, borrow=1000e6 USDC` emits a Collateral leg (5e18) and a Borrowed leg (1000e6)
- Actual: `_readUserPositionPrefix` reads `supply=beforeDustBorrow=0, borrow=actualSupply=5e18`; then `isLiquidatedWord=owner≠0` → whole position dropped → zero positions returned

## Recommended Mitigation

Correct the byte offsets to account for the 32-byte ABI offset pointer that precedes the struct data:

```solidity
function _readUserPositionPrefix(bytes memory ret)
    private
    pure
    returns (uint256 supply, uint256 borrow, bool isLiquidated)
{
    uint256 isLiquidatedWord;
    assembly {
        // ret layout: [32-byte bytes-length][32-byte ABI offset ptr (=0x20)][struct fields...]
        // Struct fields start at ret+32+32 = ret+64
        let dataPtr := add(ret, 64) // skip bytes-length prefix AND ABI offset pointer
        isLiquidatedWord := mload(add(dataPtr, 64))    // isLiquidated at struct offset 64
        supply := mload(add(dataPtr, 288))              // supply at struct offset 288
        borrow := mload(add(dataPtr, 320))              // borrow at struct offset 320
    }
    isLiquidated = isLiquidatedWord != 0;
}
```

If the on-chain Fluid VaultResolver returns two values `(UserPosition, VaultEntireData)` (as suggested by the NatSpec), the offset pointer points to struct offset 64 (two 32-byte head words), and the correction is:

```solidity
let dataPtr := add(ret, 32) // skip bytes-length prefix
// offset1 = mload(dataPtr) = 0x40 → struct starts at dataPtr+64
let structPtr := add(dataPtr, 64) // skip both offset words
isLiquidatedWord := mload(add(structPtr, 64))
supply := mload(add(structPtr, 288))
borrow := mload(add(structPtr, 320))
```

The safest fix is to replace the manual assembly decode with a standard `abi.decode(ret, (IFluidVaultResolver.UserPosition))` which handles any ABI layout automatically and is easier to audit.
