# Zodiac Roles v2 permission validation (FundConfig derivation)

Behavioural check that the permissions `FundConfig` derives from declared positions are enforced by Zodiac Roles v2 on a mainnet fork, no more and no less. Companion to `zodiac-roles-v2.md` and `derivation-example.json`.

## Command and result

```
FOUNDRY_PROFILE=slow forge test --match-path test/poc/fundconfig/FundConfigPermissionValidation.fork.t.sol -vv
```

```
[PASS] test_constrainedWordsEnforced()
[PASS] test_derivationExample()
[PASS] test_derivedLeavesAccepted()
[PASS] test_optionsEnforced()
[PASS] test_removalRevokesOnlyRemovedLeaves()
[PASS] test_removeFundedPositionReverts()
[PASS] test_undeclaredCallsRejected()
Suite result: ok. 7 passed; 0 failed; 0 skipped
```

Counts (from `out/permission-validation/*.json`, assembled into `permission-validation.json`):

| Suite | Checks | Failures | Actual statuses |
|---|---|---|---|
| positive | 31 | 0 | Accepted 31 |
| words | 66 | 0 | ParameterNotAllowed 33, OrViolation 30, CustomConditionViolation 3 |
| options | 60 | 0 | Accepted 29, DelegateCallNotAllowed 29, SendNotAllowed 2 |
| undeclared | 62 | 0 | FunctionNotAllowed 31, TargetAddressNotAllowed 31 |
| removal | 20 | 0 | Accepted 13, TargetAddressNotAllowed 4, ParameterNotAllowed 2, OrViolation 1 |
| **Total** | **239** | **0** | |

**Mismatches: none.** Every observed Roles outcome equals the outcome predicted from the derived leaf set.

**Derivation bugs found: none.** No reproducing test is needed, because nothing failed.

## Test file

`test/poc/fundconfig/FundConfigPermissionValidation.fork.t.sol` (new). It inherits the `FundConfigDerivation.fork.t.sol` fixture and does not modify `poc/` or any existing test.

## Method

1. **Fork and target.** Mainnet fork at `FORK_BLOCK=26_500_000`, against the live Roles mastercopy (`ROLES_MASTERCOPY`). The fund is built by the same fixture as the derivation test: 8 declared positions, merged `rolesKeys`.
2. **Calls are real.** For each derived leaf, the calldata is built from the real function signature. Values come from the leaf's condition tree in head order. A parameter-shape mismatch would be recorded as `ShapeMismatch`; none occurred.
3. **Classification by revert selector.** Roles rejection reverts with `ConditionViolation(uint8,bytes32)`. The raw status code is the comparison key. A call that Roles accepts is `Accepted`, whatever the inner protocol does (`shouldRevert=false`). The inner protocol outcome is not part of the verdict.
4. **Oracle over the derived set.** `_expectedRejection` predicts the status from the leaf set alone:
   - Target absent: `TargetAddressNotAllowed`.
   - Function absent: `FunctionNotAllowed`.
   - Key has an unconditional leaf: wildcard, expect `Accepted`.
   - Key has more than one leaf (merged): expect `OrViolation`.
   - Single conditional leaf: expect `ParameterNotAllowed`, or `CustomConditionViolation` for Custom words.
   - Operation not allowed: `DelegateCallNotAllowed` / `SendNotAllowed`.
5. **Mutations, per constrained word.**
   - EqualTo: `xor 1` on the value, and a `0xdead` sentinel.
   - EqualToAvatar: `0xdead` sentinel.
   - Custom: `type(uint64).max` as a nonexistent tokenId.
   - Undeclared selector on a declared target.
   - Declared selector on an undeclared target.
6. **Removal.** `FundConfig.removePosition` on an unfunded position, then the USDC `approve(DEAD)` probe before and after. Removed leaves must become rejected, and remaining leaves must stay accepted. Removing a funded position must revert with `PositionNotEmpty(moduleId, instance)`.
7. **Isolation.** Each attempt runs inside `vm.snapshotState()` / `vm.revertToState()`, so attempts do not affect each other.
8. **LP tokenId.** Taken from the NPM `Transfer(0, safe, tokenId)` log during funding. The Uniswap V3 NPM is not `ERC721Enumerable`.

## Results by suite

- **positive:** every derived leaf, called with its in-policy calldata, is `Accepted`. This covers the unconditional wildcard keys (Curve gauge `deposit`, EtherFi `requestWithdraw` / `claimWithdraw`).
- **words:** each constrained word has its negative mutation rejected with the oracle's status. Merged keys give `OrViolation`, single-leaf keys give `ParameterNotAllowed`, and the three Uniswap V3 Custom checks with a nonexistent tokenId give `CustomConditionViolation`.
- **options:** the operation is enforced. Send with a value on a send-only leaf (Curve CRV `mint`) is `Accepted`; delegatecall on a send-only leaf is `DelegateCallNotAllowed`; a value on a delegatecall-only leaf (EtherFi `requestWithdraw` / `claimWithdraw`) is `SendNotAllowed`.
- **undeclared:** undeclared selectors on declared targets give `FunctionNotAllowed`, and declared selectors on undeclared targets give `TargetAddressNotAllowed`. Both directions are covered for all 31 leaves.
- **removal:** after `removePosition` on the Curve 3pool, the USDC `approve(DEAD)` probe moves from `OrViolation` to `ParameterNotAllowed`, and the 3pool `add_liquidity` / `remove_liquidity` leaves are `TargetAddressNotAllowed`. Leaves for other positions stay `Accepted`. Removing the funded Morpho vault reverts with `PositionNotEmpty`.

## Findings

- No derivation bug was found. Every derived leaf is enforced, and no undeclared leaf is accepted in the tested space.
- The 3 Custom checks show the nonexistent-tokenId case returns `CustomConditionViolation` (status 16 in the pinned enum), not a revert. [INFERENCE] This fits the `UniswapV3LpModule` try/catch on `ownerOf`, but the live checker's code was not inspected.
- The derivation uses `Op.OR` for merged keys. The `OrViolation` results confirm this: a call that matches none of the merged leaves is rejected, not accepted by the first leaf.

## Caveats

- **Status names are provisional.** The enum names come from the pinned commit `f55d00de` (`/tmp/zr-src/`). The live mastercopy `0x9646fDAD06d3e24444381f44362a3B0eB343D337` may differ. The raw codes are the comparison key, and the names are labels only.
- **The oracle checks enforcement against the derived leaves, not intent.** The validation shows Roles enforces exactly what `FundConfig` derived. It does not show the derived set is the intended policy. That needs a review of `_declarations()` against the position specs.
- **Side effect.** Inherited `test_derivationExample` rewrites `out/derivation-example.json` each time the suite runs. This is accepted, not a defect.
- **Harness fixes during bring-up** (not derivation issues, all in the new test file):
  - Signature parser read one byte past the end (`_typeWords`).
  - Unconditional leaves indexed an empty `nodes` array.
  - `moduleId()` view calls were consuming `vm.prank` / `vm.expectRevert`.
  - The `PositionNotEmpty` revert needed its full encoded data, not only the selector.
- **Unused-warning.** `_mintedLpToken` could be `view`. Harmless; not changed.

## Files

- `test/poc/fundconfig/FundConfigPermissionValidation.fork.t.sol` (new)
- `docs/research/fund-infra/permission-validation.md` (this file)
- `docs/research/fund-infra/permission-validation.json` (per-suite rows, assembled with `jq -s` from `out/permission-validation/*.json`)
- Suite outputs: `out/permission-validation/{positive,words,options,undeclared,removal}.json`
