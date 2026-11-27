# Zodiac Roles v2 as the permission layer for a per-fund FundConfig POC

Scope: research only. Repo untouched. Pinned v2 source: `gnosisguild/zodiac-modifier-roles@f55d00de507428cd3841975e7d85310c900c7b09`, `packages/evm/contracts/`. Paths below are relative to that directory. Line numbers are from the pinned commit.

## Verdict

- **Feasible with the v2 mastercopy already live on mainnet.** Per-fund permission config can be fund-agnostic for everything except allowance keys and membership. Identical condition trees dedupe across funds via `WriteOnce` (Q2, Q6).
- **Derivation is clean.** `FundConfig → (allowTarget/allowFunction/scopeFunction calls) + NAVCalculator registrations` works. Position→permission templates are pure functions of `(protocol, instance)`.
- **Use `EqualToAvatar` (op 15) for every "the fund itself" argument** (onBehalfOf, receiver). It is resolved from the Roles clone's `avatar` at read time, so stored buffers are shared. This is the mechanism that keeps buffers fund-agnostic.
- **Do not use the DeFi Kit `apply` path as-is in CI or offline.** `planApplyRole` and `planApply` call remote endpoints (Zodiac license API, subgraph). Derive calldata with a small local encoder (Q5).
- **Do not rely on the SDK's `avatarIsOwnerOfErc721` custom condition address on v2.** The deployed contract at `0x91B1…C819d1` exposes a selector that does not match the v2 `ICustomCondition` (Q4).
- **Licensing gate.** `zodiac-roles-sdk@3.x` refuses to plan roles that use allowances unless the Roles owner has a Zodiac OS plan (`main/licensing.js`). This is relevant to any design that uses `WithinAllowance`/`CallWithinAllowance`.

## Q1. Owner API, condition model, storage, batching

**Owner-only builder functions** (`PermissionBuilder.sol`, all `onlyOwner`): `allowTarget(bytes32,address,ExecutionOptions)` (l.57), `scopeTarget` (l.86), `allowFunction(bytes32,address,bytes4,ExecutionOptions)` (l.102), `scopeFunction(bytes32,address,bytes4,ConditionFlat[],ExecutionOptions)` (l.133), `setAllowance(bytes32,uint128,uint128,uint128,uint64,uint64)` (l.158), `revokeTarget`, `revokeFunction`. `assignRoles` is `onlyOwner` (`Roles.sol:69`). `setTransactionUnwrapper(address,bytes4,ITransactionUnwrapper)` is `onlyOwner` (`Periphery.sol:21`).

**Owner.** Clone owner is the Safe in production: `owner()=avatar()=target()=0xdE53bCdA6527D2aa15Ec733352C8d393C2E0eC99` (`cast call` at block 26503897). Every permission write is therefore a Safe transaction. Batching is via Safe MultiSend. The mastercopy has no `multicall(bytes[])` (selector `0xac9650d8` absent in bytecode), so there is no Roles-level batching.

**Types** (`CoreTypes.sol`):
- `ParameterType {None, Static, Dynamic, Tuple, Array, Calldata, AbiEncoded}` (l.11).
- `Operator` (l.21): `Pass=0`, `And/Or/Nor=1-3`, `Matches=5`, `ArraySome/Every/Subset=6-8`, `EqualToAvatar=15` (l.56), `EqualTo=16`, `GreaterThan=17`, `LessThan=18`, `SignedInt*=19-20`, `Bitmask=21`, `Custom=22` (l.68), `WithinAllowance=28` (l.74), `EtherWithinAllowance=29`, `CallWithinAllowance=30`.
- `ExecutionOptions {None, Send, DelegateCall, Both}` (l.80).
- `ConditionFlat {uint8 parent; ParameterType paramType; Operator operator; bytes compValue;}`. The tree is flattened (parent index), not nested.

**Validation.** `Integrity.enforce` (pure, `Integrity.sol`) rejects malformed conditions before storage. `EqualToAvatar` requires `Static` paramType and empty compValue (l.85). `Custom` requires a 32-byte compValue (l.126).

**Storage.**
- `Core.sol:13` `roles` mapping; `Core.sol:14` `allowances` is `mapping(bytes32 => Allowance) public`, per Roles instance.
- `CoreTypes.sol:123` `scopeConfig: mapping(bytes32 => bytes32)` per role. Key is `bytes32(bytes20(target)) | (bytes32(selector) >> 160)`.
- The value is a header: count (2 bytes, offset 240), options (1 byte, offset 224), isWildcarded bit 216, pointer (20 bytes) (`packers/BufferPacker.sol`, bit layout l.15-16, l.52-57). Each condition is 2 bytes. Operators at or above `EqualTo` (16) carry a 32-byte compValue appended to the buffer. `EqualToAvatar` and below carry none.
- The condition buffer is written by `WriteOnce.store` (`WriteOnce.sol:24`). It deploys the bytes as code through the singleton factory `0xce0042B868300000d44A59004Da54A005ffdcf9f` (SALT=0, `WriteOnce.sol:15-16`), and the pointer is the CREATE2 address. Identical content gives the same pointer (dedupe).
- `PermissionLoader._store` (l.19) writes the buffer. `_load` (l.35) rewrites `EqualToAvatar` into `EqualTo(keccak256(abi.encode(avatar)))` at read time (l.59-60).

**Per-call writes.** Each `scopeFunction` runs `Integrity.enforce` then `_store` (`PermissionBuilder.sol:133`). Writes are per (role, target, selector). There is no bulk-scope call in v2.

**Membership.** `assignRoles(address,bytes32[],bool[])` (`Roles.sol:69`). `setDefaultRole` is present in bytecode (`0x946d364e`).

## Q2. Fund-agnostic conditions and remaining fund-specific bytes

**Mechanism.** The fund-specific value (the Safe) enters the buffer only through `EqualToAvatar`, which stores no compValue (`BufferPacker`, op ≤15 carries none). `_load` injects `keccak256(abi.encode(avatar))` at read time (`PermissionLoader.sol:59-60`), where `avatar` is the storage of the Roles clone. Two funds with the same template therefore produce byte-identical buffers and share one `WriteOnce` pointer.

**Evidence (gas runs, Q6):** fund2 proxy writing the same unique buffer already stored by prod: 107,442 gas. Fresh write: 169,148 gas (≈44.6k WriteOnce deploy). Cross-fund dedupe is confirmed on-chain, not only in source.

**Fund-specific bytes that remain:**
1. `allowances` keys: `WithinAllowance`/`CallWithinAllowance` compValue holds a `bytes32` allowance key. Balance, refill, period are per-Roles-instance state set by `setAllowance` (`PermissionBuilder.sol:158`). A key choice per fund is required if you want per-fund budgets. This is also what triggers the SDK license gate (Q5).
2. `members` (`assignRoles`), `roles` keys (`roleKey` bytes32), `defaultRole`.
3. Clone storage: `owner`, `avatar`, `target` (set by `setUp`).
4. Any literal address compValue: `EqualTo` on protocol-side fields such as asset, market id, or vault. These are fund-agnostic as well (same across funds), so they still dedupe. Only fund-specific addresses (e.g. a per-fund receiver that is not the avatar) break dedupe.

## Q3. Deployment

- **Mastercopy (v2, live):** `0x9646fDAD06d3e24444381f44362a3B0eB343D337` (24,401 bytes). Prod Roles `0xCEE06943E829367ff1Bd6B4670cb4a1148636d26` is an EIP-1167 clone of it (`cast code`, block 26503897).
- **Factory:** Zodiac ModuleProxyFactory `0x000000000000ADdB49795b0f9bA5BC298cDda236` (2,046 bytes on mainnet). Exposes `deployModule(address masterCopy, bytes initializer, uint256 saltNonce)` (selector `0xf1ab873c`). `createProxy(address,bytes)` (`0x61b69abd`) is absent.
- **`setUp(bytes)`** (`Roles.sol:51`, `initializer`): `abi.decode(initParams, (address owner, address avatar, address target))` (l.52), then `_transferOwnership`, sets avatar and target, calls `setupModules()`. Selector `0xa4f9edbf`.
- **Constructor** (`Roles.sol`): `Roles(owner, avatar, target)` encodes and calls `setUp` for the mastercopy. Deploy scripts at f55d00de (`packages/evm/src/deploy.ts`, `deploy-mastercopy.ts`) deploy Packer and Integrity libraries separately, and the mastercopy via `deployMastercopyWithInitData` with SaltZero.
- **Recipe for per-fund Roles:** `ModuleProxyFactory.deployModule(MASTERCOPY, abi.encode(owner=safe, avatar=safe, target=safe), saltNonce)`, then the Safe runs `allowTarget`/`scopeFunction`/`assignRoles`/`setAllowance` through MultiSend. Measured `deployModule` (Roles clone + `setUp`): 190,174 gas (Q6).
- **Prerequisite on the chain:** the singleton factory `0xce0042B868300000d44A59004Da54A005ffdcf9f` must have code (308 bytes on mainnet, verified). No new mastercopy or library deploy is needed for the POC: the v2 mastercopy above is live.

## Q4. `Custom` operator (`ICustomCondition`)

- **Dispatch:** `PermissionChecker.sol:274-275` → `_custom` (l.612-634). Calls `ICustomCondition(address(bytes20(compValue))).check(to, value, data, location, size, bytes12(extra))` (l.625). Returns `Status.CustomConditionViolation` if `success == false`.
- **v2 interface** (`adapters/Types.sol`, l.29): `check(address to, uint256 value, bytes data, uint256 location, uint256 size, bytes12 extra) returns (bool success, bytes32 reason)`. Selector `0x57cf558b`. It is a `view` call with no caller argument. The adapter learns the avatar only through `msg.sender`, i.e. the Roles contract, via `IModifier(msg.sender).avatar()`.
- **v2 reference adapter** `adapters/AvatarIsOwnerOfERC721.sol`: `avatar = IModifier(msg.sender).avatar()`; `tokenId = data[location:location+size]`; `success = IERC721(to).ownerOf(tokenId) == avatar`. Usable as a pattern for POC custom checks.
- **Encoding of compValue:** `address(20) || extra(12)` (`zodiac-roles-sdk@3.0.1` `main/target/authoring/c/custom.js`, helper `encodeCustomCompValue`, pads extra to 12 bytes). The v2 `_custom` reads `address(bytes20(compValue))` and `bytes12(uint96(uint256(compValue)))` (`PermissionChecker.sol:619-623`).
- **Mainnet deployment mismatch.** `zodiac-roles-sdk@3.0.1` `avatarIsOwnerOfErc721` uses `AVATAR_IS_OWNER_OF_ERC_721_ADDRESS = 0x91B1bd7BCC5E623d5CE76b0152253499a9C819d1`. On the fork, that contract has 811 bytes of code and a single external selector `0xb0acb980`. It matches neither the v2 `check` (`0x57cf558b`) nor the v3 `check` (`0x4668d9c7`, signature `check(address,uint256,bytes,uint8,uint256,uint256,bytes,bytes32[])` from v3 `packages/evm/contracts/periphery/interfaces/ICustomCondition.sol` at `main`). `0xb0acb980` is `check(address,uint256,bytes,uint8,uint256,uint256,bytes12)` (brute-force match). A v2 Roles calling it reverts (`cast call` with v2 selector returned `execution reverted, data: 0x` on the fork). **Conclusion:** do not reuse `0x91B1…` for v2. Deploy a small `ICustomCondition` matching `adapters/Types.sol` (~15 lines), or verify the `0x91B1` ABI with a source/ABI lookup before use. `[UNVERIFIED]`: who deployed 0x91B1 and which Roles version it targets.
- **Runtime cost** of Custom: not measured.

## Q5. DeFi Kit (`karpatkey/defi-kit`, npm `defi-kit@2.27.4`) and offline calldata

**Dependency:** `defi-kit` depends on `zodiac-roles-sdk@^3.0.1` (`/tmp/zr/dk/sdk/package.json`, read from repo). The SDK's Roles ABI (`zodiac-roles-deployments@3.0.0`, enums) matches v2 for all operator values used here (EqualToAvatar=15, Custom=22, WithinAllowance=28). The `avatarIsOwnerOfErc721` preset is the exception (Q4).

**Aave V3** (`src/protocols/aave/v3/actions.ts`):
- `depositToken(chain, token, market)` (l.138): `allowErc20Approve([token],[poolV3])`, then `allow.mainnet.aaveV3.poolCoreV3.supply(token, undefined, c.avatar)` with `targetAddress: poolV3`. Plus `withdraw(token, undefined, c.avatar)` and `setUserUseReserveAsCollateral`, `incentivesV3.claimRewards(... c.avatar)`.
- `borrowToken` (l.255): `borrow(token, undefined, undefined, undefined, c.avatar)`, `repay(... c.avatar)`.
- `depositEther` (l.199): `wrappedTokenGatewayCoreV3.depositETH(poolV3, c.avatar, {send:true})`.
- Arbitrum variant uses 2-byte token IDs via `_getAssetId` (l.104) and `poolV3["withdraw(bytes32)"]` (packed-bytes32 Aave API). These are index-based, so they depend on the DeFi Kit token list.
- Pattern: `undefined` = Pass (unconstrained); `c.avatar` = `EqualToAvatar`. This is exactly the fund-agnostic template used in the gas test (Q6).

**Morpho vault** (`src/protocols/morpho/vaults/actions.ts`): `deposit(vault)` = `allowErc20Approve([asset],[vault.id])` plus `allow.mainnet.gearbox.vault.deposit(undefined, c.avatar)` with `targetAddress: vault.id`. **Morpho vaults use the Gearbox ERC-4626 preset**, not a Morpho-specific one. This is an observation from source; it works because the ABI is ERC-4626.
- Vault list: `_ethInfo.ts` (auto-generated, ~10.8k lines, fields `id`, `version`, `name`, `symbol`, `asset{address,symbol}`). `findVault` (`vaults/index.ts`) matches by id, name, or symbol.

**Lido** (`src/protocols/lido/index.ts`): `eth.deposit()` = approve for stETH/wstETH/unstETH (`allowErc20Approve`) + `allow.mainnet.lido.stEth.submit(undefined, {send:true})`, `wstEth.wrap()/unwrap()`, `unstEth.requestWithdrawals(undefined, c.avatar)`, `requestWithdrawalsWstETH(undefined, c.avatar)`, `claimWithdrawal()`, `claimWithdrawals()`. Addresses from `eth-sdk/config`.

**Apply path** (`src/apply.ts`): `createApply(chainId)` → `apply(roleKey, permissions, {address, mode: replace|extend|remove})`. Calls `processPermissions`, `targetIntegrity`, `fetchRole`, `planApplyRole`. `POSTER_ADDRESS = 0x000000000000cd17345801aa8147b8D3950260FF` (EIP-3722) for annotations.

**Offline feasibility, from `zodiac-roles-sdk@3.0.1` build (`/tmp/zr/npm/.../build/esm/sdk/src/`):**
- Pure (no network): `kit` (`allow`, `EVERYTHING`), `c`, `forAll`, `processPermissions`, `targetIntegrity`, `coercePermission`, `permissionId`, `encodeKey`/`decodeKey`, `rolesAbi`. `typechain.js` exports `Roles__factory` (`./typechain` export).
- Network: `planApplyRole` and `planApply` (`main/target/plan.js:29-30`, `:75-80`, `:86-87`): `fetchRolesModConfig`, `fetchLicense` → `https://app.pilot.gnosisguild.org/system/get-plan/<prefix:owner>`, and `fetchRole`/`fetchRolesMod` from subgraph when `current` is not provided. `postRole` posts to `https://roles.gnosisguild.org/api/permissions` (`main/postRole.js`). `annotations.js:158` fetches a URL.
- `encodeCalls` (`main/target/calls/encodeCalls.js`) is pure but **not exported** from the package index. `flattenCondition` is also internal. The POC should copy the ~80 lines of encoding (it is a switch over `allowTarget`/`scopeTarget`/`allowFunction`/`scopeFunction`/`setAllowance`/`assignRoles`), or import `Roles__factory` from `zodiac-roles-sdk/typechain`.

**Licensing gate:** `enforceLicenseTerms` (`main/licensing.js`) throws `LicenseError` if the Roles owner has no plan (`license === "none"`) and a role uses `WithinAllowance`, `CallWithinAllowance`, or `EtherWithinAllowance` anywhere in its condition tree. Any design using allowances requires a Zodiac OS plan for the owner, or no allowances. This applies to `planApply*` only, not to on-chain execution.

## Q6. Gas (measured on anvil fork)

**Method.** `anvil` 1.7.1 forked mainnet at block 26503897, impersonated the avatar Safe (`cast send --unlocked`), `gasUsed` from receipts (includes 21,000 base). Scratch scripts in `/tmp/zr/gas*.sh`. Fork is an approximation of mainnet gas.

| Operation | Gas | Notes |
|---|---|---|
| `allowTarget(role, AaveV3 Pool 0x87870B…, Send)` | 51,532 | prod and fund2 proxy |
| `allowFunction(role, supply 0x617ba037)` | 51,786 | prod and fund2 proxy |
| `scopeFunction`, 5-cond template, buffer already stored, key previously set | 107,646 | prod; slot nonzero→nonzero |
| Same buffer, fresh role key (zero slot) | 124,542 | prod; dedupe hit, fresh slot |
| Unique buffer, first ever (WriteOnce deploy) | 169,148 | prod; implied WriteOnce deploy ≈44.6k |
| Fund2 proxy, same buffer already stored | 107,442 | cross-fund dedupe |
| Fund2 proxy, new buffer | 152,024 | dedupe + ≈44.6k |
| Overwrite same role, new data | 152,024 | |
| `deployModule` (Roles clone + `setUp`) | 190,174 | fund2 |

**Template.** `supply(address,uint256,address,uint16)`: `Matches` root; children `EqualTo asset`, `Pass amount`, `EqualToAvatar onBehalfOf`, `Pass referralCode`.

**Reading the numbers.** Per-call permission write is ~52k (allowTarget/allowFunction) plus ~55-120k for a scoped function, depending on slot state and buffer novelty. With 2-3 scoped functions per protocol and ~10 protocols per fund, expect ~1-3M gas per fund setup, excluding `deployModule`. This is an estimate `[INFERENCE]` from the figures above.

**Not measured:** `Custom` runtime cost, `WithinAllowance` cost, `execTransactionWithRole` cost at scale, `allowTarget` for targets with many functions.

## Implications for the POC design

1. **Single source of truth.** `FundConfig` lists `(protocolId, instance, asset/market, receiver=avatar)`. Two generators read it: (a) NAVCalculator adapter + meta-instance registration; (b) Roles calls (`allowTarget`, `allowFunction`, `scopeFunction` with fund-agnostic templates, `setAllowance` only where budgets exist). Both are pure functions of the config.
2. **Shared, immutable permission blueprints**: one template per protocol function, keyed by selector, with `EqualToAvatar` for the Safe argument. Use `WriteOnce` dedupe to keep per-fund cost low.
3. **Custom conditions**: deploy our own `ICustomCondition` for v2 (match `adapters/Types.sol`). Do not reuse `0x91B1…`.
4. **Calldata generation**: local encoder (ethers `Roles__factory` + reimplemented `flattenCondition`/`encodeCalls`). Avoid `planApplyRole` in the POC path to remove network and licensing dependencies. Keep allowances off unless a license is in place.
5. **Consistency guarantee.** The "cannot under-report / permission matches accounting" property is enforced only if both generators share the same `FundConfig`. The repo's CLAUDE.md residual risk (roles change adds an untracked path) is addressed for generated configs only. Manual `allowTarget` writes outside the generator would still break it; this needs a periodic on-chain diff (`scopeConfig` / `targets`) against the config.
6. **Factory**: `deployModule` + Safe MultiSend of generated calls. No new mastercopy is needed (v2 mastercopy is live).

## Open items / [UNVERIFIED]

- `0x91B1bd7BCC5E623d5CE76b0152253499a9C819d1` deployer and intended Roles version: not verified.
- v3 `ICustomCondition` selector (`0x4668d9c7`) is computed from the `main` source file; the v3 Roles mastercopy was not checked on-chain.
- Gas figures are from a fork, not a mainnet transaction; they are approximate.
- Whether `zodiac-roles-sdk@3.0.1` `Roles__factory` ABI is identical to v2 mastercopy for every function used: confirmed for `scopeFunction`, `allowTarget`, `setAllowance`, `assignRoles` by selector on the mastercopy; not confirmed for every ABI entry.
- `packages/sdk` at f55d00de is stale (v1 calls `scopeAllowFunction`, `scopeParameterAsOneOf` absent from the v2 mastercopy bytecode). Do not reuse.

## Sources

- v2 source @ f55d00de: https://github.com/gnosisguild/zodiac-modifier-roles/tree/f55d00de507428cd3841975e7d85310c900c7b09/packages/evm/contracts
- v3 source @ main (ICustomCondition, AvatarIsOwnerOfERC721): https://github.com/gnosisguild/zodiac-modifier-roles/tree/main/packages/evm/contracts/periphery
- DeFi Kit: https://github.com/karpatkey/defi-kit (`packages/sdk/src/apply.ts`, `protocols/aave/v3/actions.ts`, `protocols/morpho/vaults/actions.ts`, `protocols/lido/index.ts`)
- npm: `zodiac-roles-sdk@3.0.1`, `zodiac-roles-deployments@3.0.0`, `defi-kit@2.27.4`
- Zodiac ModuleProxyFactory: `0x000000000000ADdB49795b0f9bA5BC298cDda236` (mainnet, verified by `cast code`)
- Repo harness: `test/utils/AssistantSafeRolesForkBase.sol` (IRolesMod signatures; avatar `0xdE53…0eC99`, manager Safe `0x9953…A63c`, Roles `0xCEE0…d26`)
- Repo CLAUDE.md: residual-risk statement on roles permission changes.