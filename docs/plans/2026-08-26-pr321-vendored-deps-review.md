# PR #321 review plan — dropping oversized submodules, vendoring single-file deps

Date: 2026-08-26 · PR: [#321](https://github.com/karpatkey/onchain-accounting/pull/321) ·
Reviewed at HEAD `d535eadf3029902ed8f8470773afbdc00fc663d4`

## The question this answered

The diff removes four submodules and vendors the files that were their only imports. Gates that
review a diff can check the diff; the question worth spending a review plan on was the one they
structurally cannot answer: **once a file stops being a submodule, what was the submodule doing that
nothing now does?**

## The answer, and it drove most of the work

The gitlink was doing **enforcement**, not just distribution. While `Types.sol` resolved through
`lib/optimism`, editing it in-tree was impossible — it sat behind a gitlink that
`script/ci/check-foundry-lock.sh` compared against `foundry.lock`. Vendoring removes that, and the
test suite cannot stand in for it: the bridge mocks import the *same* vendored file, so a struct edit
drifts test and production in lockstep and stays green. The adapter ABI-encodes those structs to
deployed Optimism contracts, so drift there is a stuck-withdrawal bug, not a compile error.

`script/ci/check-vendored.sh` was written to replace that enforcement, with a deliberate asymmetry:
the offline manifest-hash check always hard-fails, and the upstream re-fetch soft-skips only on a
transport failure. That asymmetry is the point — this repo has already shipped an incident where a
guard passed because its input was stale, so the non-skippable half must be the one that needs no
network.

## What the review found that the plan did not predict

The largest finding came from following a provenance claim rather than a hypothesis. The header
justified vendoring `Create2DeployerInterface.sol` by saying its signatures must match the deployed
canonical CREATE2 deployer. Reading that deployer's actual runtime code:

```
cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C
0x7fffff…ffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3
```

69 bytes: read calldata as `salt ++ initCode`, CREATE2 it, return 20 bytes. **No selector dispatch.**
It does not implement that interface, and CREATE2 is a state write so the call reverts under
STATICCALL regardless. Both `try` arms had always landed in `catch`, logging a `[WARN]` worded as an
environment problem. So `lib/comet`'s import count was really **0**, and the vendored interface was
dropped rather than kept. The dead probe was replaced with an unconditional `vm.computeCreate2Address`
assertion (Foundry's Rust implementation — genuinely independent of the Solidity helper), which was
revert-probed by breaking the helper's `0xff` prefix and confirming it fails.

Generalisable: *"is it imported"* and *"does that import do anything"* are different questions, and a
dependency audit that stops at the first is one grep short.

## Residual risk, accepted

- `provenWithdrawals` is **broken against the real portal** and is filed separately — pre-existing,
  not from this PR, and it must not be fixed inside a dependency-cleanup change.
- The upstream half of the drift guard depends on GitHub raw being reachable. By design it degrades
  to the offline check rather than failing the build.
- Nested submodules are still full-cloned; `shallow` cannot reach them because those `.gitmodules`
  belong to upstream.

## Termination

Every gate finding is fixed, refuted, or filed. The scoped fix-delta pass is the closing step.
