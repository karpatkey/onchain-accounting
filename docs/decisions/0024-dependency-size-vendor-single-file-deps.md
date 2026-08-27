# 0024 — Drop oversized submodules; vendor single-file dependencies

**Status:** accepted

## Context

`.git` reached 2.8 GB. Tracked history is not the cause — `.git/objects` is 27 MB. The weight is submodule clones under `.git/modules/lib` (1.4 GB) plus an orphaned worktree holding a second full copy of them (1.4 GB).

Measured usage, counting distinct files imported from `src/`, `test/`, `script/`:

| submodule | `.git/modules` | working tree | files imported |
| --- | --- | --- | --- |
| `lib/optimism` | 1.2 G | 78 M | **1** — `libraries/Types.sol` |
| `lib/openzeppelin-contracts-upgradeable` | 97 M | 28 M | many |
| `lib/chainlink-brownie-contracts` | 50 M | 15 M | 5 |
| `lib/aave-v3-core` | 20 M | 9.6 M | **0** |
| `lib/comet` | 11 M | 25 M | **0** (apparent 1 — `Create2DeployerInterface.sol`, but see below: the single importer was dead code) |
| `lib/morpho-blue` | 8.9 M | 4.3 M | 3 |
| `lib/gmx-contracts` | 6.0 M | 11 M | **0** |
| `lib/openzeppelin-foundry-upgrades` | 2.0 M | 1.9 M | used |
| `lib/forge-std` | 1.3 M | 1.2 M | used |

`lib/optimism` is the entire Optimism monorepo — 17,304 commits, a 1.0 GB pack — carried for one 70-line struct-only library. It also declares nine nested submodules of its own (`openzeppelin-contracts`, `openzeppelin-contracts-upgradeable`, `solmate`, `solady`, `safe-contracts`, `forge-std`, `clones-with-immutable-args`, `kontrol-cheatcodes`, `lib-keccak`), none of which any file here imports; `actions/checkout` with `submodules: recursive` clones all nine in every job.

`aave-v3-core` and `gmx-contracts` are imported zero times. Their only remaining traces were `.gitmodules`, `remappings.txt`, `foundry.lock`, and `README.md` — remappings pointing at code nothing compiles.

### What the CI cost actually is

An earlier reading of this — "CI re-clones 1.2 GB of history every run" — is wrong, and the correction matters because it changes which fixes are worth making.

`actions/checkout@v4` resolves submodules through `submoduleUpdate(settings.fetchDepth, …)`:

```ts
async submoduleUpdate(fetchDepth: number, recursive: boolean): Promise<void> {
  const args = ['-c', 'protocol.version=2']
  args.push('submodule', 'update', '--init', '--force')
  if (fetchDepth > 0) {
    args.push(`--depth=${fetchDepth}`)
  }
  if (recursive) {
    args.push('--recursive')
  }
  await this.execGit(args)
}
```

(`actions/checkout`, `src/git-command-manager.ts`.) `fetch-depth` defaults to 1 and no workflow here overrides it, so CI has always fetched submodules at `--depth=1`. History was never the CI cost. CI pays for **working trees**: ~167 MB across the nine submodules, plus nine more trees nested under `lib/optimism`.

Two distinct problems therefore need two distinct answers:

- **Local `.git` size (2.8 GB).** Caused by full-history clones on developer machines, where nothing passes `--depth=1`.
- **CI wall-clock.** Caused by working-tree bytes and by recursing into unused nested submodules.

Dropping a submodule is the only action that fixes both.

### Options considered

1. **Delete the unused submodules; vendor the single files; keep submodules for genuine multi-file dependencies.**
2. **`shallow = true` in `.gitmodules`.** Honoured at clone time by `git submodule update --init` (git's `--recommend-shallow` is the default). Cuts local `.git` substantially. Does nothing for CI, which is already at `--depth=1`, and nothing about carrying a monorepo for one file. Complementary, not a substitute.
3. **Sparse-checkout the one needed subdirectory of `lib/optimism`.** `git submodule update` does not honour sparse patterns, and `actions/checkout` passes `--force`, so any local sparse state is wiped on the next CI run. A local trick, not a committable configuration.
4. **Migrate to Soldeer.** Rejected. The Foundry Book presents submodules as the default and Soldeer as "an alternative", and discourages Soldeer's git source ("Git isn't designed to be a dependency manager"). Five of our nine dependencies — `chainlink-brownie-contracts`, `comet`, `aave-v3-core`, `gmx-contracts`, and Optimism's `contracts-bedrock` — are absent from the registry, so they would fall back to full git clones anyway. Registry packages are published by a maintainer account rather than the upstream protocol teams, which is a weaker provenance claim than a gitlink SHA.
5. **Do nothing.** The build works; the cost is 2.8 GB per clone and dead remappings.
6. **Cache submodules in CI.** Considered and deferred, not rejected on principle. A survey of ten mature Foundry/Solidity repositories (`ethereum-optimism/optimism`, `Uniswap/v4-core`, `Uniswap/v3-core`, `morpho-org/morpho-blue`, `aave-dao/aave-v3-origin`, `Vectorized/solady`, `transmissions11/solmate`, `sablier-labs/lockup`, `OpenZeppelin/openzeppelin-contracts`, `foundry-rs/forge-std`) found **none** caching `lib/` or `.git/modules/`; they cache compiler and build output instead, which is the thing this repo already does by compiling once and sharing `out/`. Three mechanics matter if it is revisited: (a) the cache key must be `hashFiles('foundry.lock')`, **not** `hashFiles('.gitmodules')` — `.gitmodules` records only path/url/shallow and contains no revisions, so keying on it would serve a stale dependency tree across a dependency bump; (b) `actions/checkout` performs `git submodule update --init --force` *during* checkout, before any later cache step can restore, so the checkout would need `submodules: false` with a conditional `git submodule update --init --recursive` on cache miss; (c) `useblacksmith/stickydisk` does support content-derived keys, so the existing infrastructure could express (a). Deferred because this repo has already shipped a correctness incident from a loosely-keyed cache — the repo-wide `stickydisk` served stale artifacts and produced a wrong `PriceFeedLib` CREATE2 address that a guard then validated, which is why `foundry-toolchain` runs with `cache: false` on the build job — and because after this ADR the entire remaining submodule payload is 50 MB fetched at `--depth=1`. Adding cache machinery to seven jobs for that, in the one area of the build that has already produced a silent-staleness bug, is a bad trade until measurement says otherwise.

## Decision

Take **option 1**, with option 2 applied to what remains.

- Vendor the **one** genuinely-imported single-file dependency (`Types.sol` → `src/bridge/adapters/lib/OptimismTypes.sol`) and delete `lib/optimism`, `lib/comet`, `lib/aave-v3-core`, `lib/gmx-contracts` via `forge remove`.
- **`lib/comet` needed no vendoring at all.** An earlier version of this decision vendored `Create2DeployerInterface.sol` as well, on the basis that it had one importer. Review established that the importer was dead code: the sole use was `try ICreate2Deployer(CANONICAL_CREATE2_DEPLOYER).computeAddress(…)` in `script/test/Test02_DeployProxies.t.sol`, and `CANONICAL_CREATE2_DEPLOYER` (`0x4e59b448…4956C`) is Arachnid's deterministic-deployment-proxy — 69 bytes of runtime that treat calldata as `salt ++ initCode` and CREATE2 it, with **no selector dispatch**, so it does not implement that interface; and CREATE2 is a state write, so the call reverts under `STATICCALL` in any case. Both arms had always landed in `catch` and logged a `[WARN]` phrased as an environment problem, so the only cross-check that the deploy scripts' CREATE2 derivation agreed with a second source had never run. The probe was replaced with an unconditional `vm.computeCreate2Address` assertion — Foundry's Rust implementation, which shares no code with the Solidity helper — and the interface, now importerless, was dropped rather than vendored. So `lib/comet`'s import count was really **0**, like `aave-v3-core` and `gmx-contracts`. Worth generalising: *"is it imported"* is not the same question as *"does that import do anything"*, and a dependency audit that stops at the first is one grep short.
- Add `shallow = true` to **all five** surviving submodules so fresh developer clones stop fetching their full history. (An earlier draft of this record said "the two heaviest"; the implementation applies it to all five, which is what `.gitmodules` and the README state.)
- Keep `submodules: recursive` in CI. It is load-bearing: `openzeppelin-contracts-upgradeable` (4 nested), `morpho-blue` (2), and `openzeppelin-foundry-upgrades` (1) resolve through their own nested submodules, and `remappings.txt` reaches into `lib/openzeppelin-contracts-upgradeable/lib/…`. Do not add `fetch-depth: 0` — `submoduleUpdate` forwards that same value to `--depth`, so it would deepen every submodule and make CI slower.

Vendored files go beside the code that consumes them, not into a new top-level `vendor/` tree, because that is already this repo's convention: `src/bridge/adapters/interfaces/` holds hand-written minimal copies of the Stargate, Gnosis, Across, and Circle CCTP interfaces. `IStargateInterfaces.sol` says so in its own header — "Minimal local copies of the Stargate V2 (OFT-based, LayerZero V2) interfaces … the structs and signatures here mirror upstream exactly". Optimism was the sole bridge integration taking a submodule instead, and for strictly less code than the others.

Rationale:

- **Consistent with the repo.** Five hand-written bridge interface files already exist. Extending that pattern to Optimism removes a special case rather than adding one.
- **Consistent with the ecosystem.** `aave-dao/aave-v3-origin` vendors OpenZeppelin, Gnosis, Chainlink and WETH under `src/contracts/dependencies/`; `Vectorized/solady` vendors three forge-std files instead of taking the submodule; `morpho-org/morpho-blue` hand-writes its own `IERC20`/`IOracle`. Vendoring a handful of third-party files is normal practice at this scale, not a shortcut.
- **Bytecode-neutral in this specific case.** `Types` is a struct-only library; it declares no function, so it contributes no code to any consumer. `bytecode_hash = "none"` already strips the metadata trailer, so relocating the source cannot move the deterministic CREATE2 library addresses pinned in `foundry.toml`. `LibraryPinConsistency` re-derives those pins from bytecode and would fail if this were wrong. **This neutrality does not generalise** — vendoring a file containing even one `internal` function changes what gets inlined into consumers.
- **Pinning is not weakened.** The file was already frozen at a submodule gitlink; nothing tracked upstream automatically. A vendored file with its upstream URL and rev recorded in the header carries the same information and less machinery.

## Consequences

**Positive:**

- `.git` drops from 2.8 GB to roughly 150 MB after pruning the stale worktree and repacking.
- CI stops cloning ten working trees (`lib/optimism` plus its nine nested submodules) it never compiles.
- `remappings.txt` and `foundry.lock` no longer advertise dependencies nothing imports.

**Negative / things to watch:**

- The vendored file no longer tracks upstream. For a frozen struct definition this is close to zero risk, but the provenance header must be kept accurate if it is ever refreshed.
- MIT requires the copyright and permission notice to travel with copied source. **An earlier draft of this record got this wrong** and is corrected here rather than silently: it claimed "neither upstream file carries a copyright line beyond its SPDX identifier", and used that to justify shipping only the identifier. The premise is false for Optimism — a real MIT notice exists and an SPDX tag is an identifier, not the notice. **Which** notice took a second correction: Optimism ships two, a monorepo root `LICENSE` (`Copyright 2020-2024 Optimism`) and `packages/contracts-bedrock/LICENSE` (`Copyright (c) 2022 Optimism`). The vendored file lives under `packages/contracts-bedrock/`, so the subtree notice governs it; an earlier revision of `THIRD-PARTY-NOTICES.md` reproduced the root one. Both were fetched at the pinned rev and confirmed to differ. Optimism's notice is therefore reproduced in `THIRD-PARTY-NOTICES.md`, which the root `LICENSE` points at. (The comet file raised the harder version of this question — that **project** is Business Source License 1.1 and only the file carried an MIT tag, a file-level grant with no upstream MIT notice in existence to reproduce — but the question is moot: that file was found to have no live consumer and was deleted, see the Decision section. Keep the distinction in mind for the next vendored file: a project-wide grant and a file-level tag are not interchangeable.) (Not legal advice.)
- `ignored_warnings_from = ["lib"]` is prefix-matched and so does not cover `src/bridge/adapters/lib/`. No scoping config was added regardless, because it would be inert: the vendored file compiles with zero warnings (verified — `forge build` reports none against that path), `deny = "warnings"` is currently commented out in `foundry.toml`, and a struct-only library produces no coverable statements. If a future vendored file does emit warnings, note that `ignored_warnings_from`, `[lint] ignore`, and `no_match_coverage` scope compiler warnings, lint diagnostics, and coverage independently — setting one does not imply the others.
- `forge remove` in 1.7.1 does not strip the `[submodule "lib/<name>"]` stanza from `.git/config`, and does not touch `remappings.txt`. Both are handled explicitly **in this commit**. What this commit cannot reach is an **existing clone**: removing a submodule from `.gitmodules` and the index does not delete the working tree that is already on someone's disk. Those directories survive, `forge remappings` auto-detects a prefix for every directory under `lib/`, and the result is a developer whose local remapping set differs from CI's while both builds succeed. That is the failure mode to watch — it is silent in both directions. **Migration recipe, once per existing clone** (fresh clones need none of it):

  ```bash
  git submodule deinit -f lib/optimism lib/comet lib/aave-v3-core lib/gmx-contracts 2>/dev/null || true
  rm -rf lib/optimism lib/comet lib/aave-v3-core lib/gmx-contracts
  rm -rf .git/modules/lib/optimism .git/modules/lib/comet \
         .git/modules/lib/aave-v3-core .git/modules/lib/gmx-contracts
  git config --remove-section submodule.lib/optimism 2>/dev/null || true   # repeat per submodule
  git submodule update --init --recursive --force
  forge remappings | grep -E 'optimism|comet|aave-v3-core|gmx'             # must print nothing
  git gc --prune=now                                                       # reclaims the pack
  ```

- **`shallow = true` interacts with the documented dependency-bump flow.** `script/ci/check-foundry-lock.sh` documents that flow as `git -C lib/<dep> checkout <rev> && git add lib/<dep>`. On a **fresh** clone the submodules are now depth-1, so that checkout fails (`reference is not a tree`) for any rev that is not the current tip. The bump flow becomes: `git -C lib/<dep> fetch --unshallow` (or `fetch origin <rev> --depth=1`) **first**, then checkout. Existing clones are unaffected — they already have full history. This is a real ergonomic cost of the shallow flag, accepted because bumps are rare and CI is unaffected (it clones at `--depth=1` regardless).

- **The gitlink was doing enforcement work that vendoring removes.** While `Types` resolved through a submodule, editing it in-tree was impossible: it lived behind a gitlink, and `check-foundry-lock.sh` compared that gitlink to `foundry.lock`. A vendored file has no such protection, and the tests cannot supply it — the bridge mocks import the *same* vendored file, so a struct edit drifts test and production in lockstep and stays green. `script/ci/check_vendored.py` replaces that enforcement: it hashes each vendored file's comment-stripped body against a committed manifest (offline, always hard) and re-fetches the pinned upstream rev to confirm the manifest itself is honest (never soft-skips on a mismatch, and never on a 404/410, which mean the pinned rev or path does not resolve and so leave provenance *unverifiable* rather than verified; every other status soft-skips, so upstream availability is not a build dependency). The offline half is deliberately the non-skippable one — this repo has already shipped an incident where a guard passed because its input was stale.

## Convention going forward

When an upstream dependency is needed for a small, stable surface — an interface, a struct, a constant:

- Write or copy a minimal local file next to its consumer, following `src/bridge/adapters/interfaces/`.
- Preserve the upstream `SPDX-License-Identifier` verbatim; do not relicense it as BUSL-1.1.
- Record upstream repo, exact pinned rev, and upstream path in a `@dev` header so the copy can be diffed against its origin.
- Register the file's licence in the root `LICENSE` third-party note if it differs from BUSL-1.1, and reproduce the upstream copyright + permission notice in `THIRD-PARTY-NOTICES.md`. Record whether the grant is project-wide or file-level — they are not interchangeable.
- Register the file in `script/ci/check_vendored.py` (add the row with a `"PLACEHOLDER"` hash, then run `--update` once — it fetches the pinned rev and refuses to record a hash that does not match upstream, so it needs network). A vendored file with no drift check is a fork waiting to happen.
- **Check `forge fmt --check` against it before committing.** CI formats the whole tree, and the drift guard demands the body stay byte-identical to upstream — so a vendored file that `fmt` wants to reflow puts the two guards in direct conflict, and whichever is "fixed" first silently defeats the other. `OptimismTypes.sol` happens to be fmt-clean (verified), which is luck, not design. If a future vendored file is not, exclude it via `fmt.ignore` in `foundry.toml` rather than reformatting it.
- **Know what the drift guard does not cover: comments.** The manifest hash is taken over the comment-stripped body, so the guard enforces *code*-verbatim, not byte-verbatim — reflowing natspec, changing the SPDX tag, or editing a `@custom:storage-location` annotation leaves the hash untouched and the guard still reports "verbatim". That is forced by design (the vendored header this repo adds is itself a comment, so a comment-sensitive hash could never match upstream). If a future vendored file carries annotations that tooling or licensing actually reads, it needs a stronger check than this one.
- Add a submodule only when the dependency is genuinely multi-file and actively tracked. Before adding one, check the ratio of what it costs to what gets imported.

For non-permissively-licensed upstream *math*, ADR 0008 governs instead — it is a stricter case and its GPL analysis still applies.
