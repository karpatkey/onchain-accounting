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
| `lib/comet` | 11 M | 25 M | **1** — `Create2DeployerInterface.sol` |
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

- Vendor the two single-file dependencies and delete `lib/optimism`, `lib/comet`, `lib/aave-v3-core`, `lib/gmx-contracts` via `forge remove`.
- Add `shallow = true` to the two heaviest surviving submodules (`openzeppelin-contracts-upgradeable`, `chainlink-brownie-contracts`) so fresh developer clones stop fetching their full history.
- Keep `submodules: recursive` in CI. It is load-bearing: `openzeppelin-contracts-upgradeable` (4 nested), `morpho-blue` (2), and `openzeppelin-foundry-upgrades` (1) resolve through their own nested submodules, and `remappings.txt` reaches into `lib/openzeppelin-contracts-upgradeable/lib/…`. Do not add `fetch-depth: 0` — `submoduleUpdate` forwards that same value to `--depth`, so it would deepen every submodule and make CI slower.

Vendored files go beside the code that consumes them, not into a new top-level `vendor/` tree, because that is already this repo's convention: `src/bridge/adapters/interfaces/` holds hand-written minimal copies of the Stargate, Gnosis, Across, and Circle CCTP interfaces. `IStargateInterfaces.sol` says so in its own header — "Minimal local copies of the Stargate V2 (OFT-based, LayerZero V2) interfaces … the structs and signatures here mirror upstream exactly". Optimism was the sole bridge integration taking a submodule instead, and for strictly less code than the others.

Rationale:

- **Consistent with the repo.** Five hand-written bridge interface files already exist. Extending that pattern to Optimism removes a special case rather than adding one.
- **Consistent with the ecosystem.** `aave-dao/aave-v3-origin` vendors OpenZeppelin, Gnosis, Chainlink and WETH under `src/contracts/dependencies/`; `Vectorized/solady` vendors three forge-std files instead of taking the submodule; `morpho-org/morpho-blue` hand-writes its own `IERC20`/`IOracle`. Vendoring a handful of third-party files is normal practice at this scale, not a shortcut.
- **Bytecode-neutral in this specific case.** `Types` is a struct-only library and `ICreate2Deployer` is an interface; neither declares a function, so neither contributes code to any consumer. `bytecode_hash = "none"` already strips the metadata trailer, so relocating the source cannot move the deterministic CREATE2 library addresses pinned in `foundry.toml`. `LibraryPinConsistency` re-derives those pins from bytecode and would fail if this were wrong. **This neutrality does not generalise** — vendoring a file containing even one `internal` function changes what gets inlined into consumers.
- **Pinning is not weakened.** Both files were already frozen at a submodule gitlink; nothing tracked upstream automatically. A vendored file with its upstream URL and rev recorded in the header carries the same information and less machinery.

## Consequences

**Positive:**

- `.git` drops from 2.8 GB to roughly 150 MB after pruning the stale worktree and repacking.
- CI stops cloning ten working trees (`lib/optimism` plus its nine nested submodules) it never compiles.
- `remappings.txt` and `foundry.lock` no longer advertise dependencies nothing imports.

**Negative / things to watch:**

- The two vendored files no longer track upstream. For a frozen struct definition and a two-function interface this is close to zero risk, but the provenance header must be kept accurate if either is ever refreshed.
- MIT requires the copyright and permission notice to travel with copied source. Neither upstream file carries a copyright line beyond its SPDX identifier, so the identifier is preserved verbatim and attribution is recorded in the header. The root `LICENSE` third-party note is updated to cover them. (Not legal advice.)
- `ignored_warnings_from = ["lib"]` is prefix-matched and so does not cover `src/bridge/adapters/lib/`. No scoping config was added regardless, because it would be inert: both vendored files compile with zero warnings (verified — `forge build` reports none against either path), `deny = "warnings"` is currently commented out in `foundry.toml`, and neither a struct-only library nor an interface produces coverable statements. If a future vendored file does emit warnings, note that `ignored_warnings_from`, `[lint] ignore`, and `no_match_coverage` scope compiler warnings, lint diagnostics, and coverage independently — setting one does not imply the others.
- `forge remove` in 1.7.1 does not strip the `[submodule "lib/<name>"]` stanza from `.git/config`, and does not touch `remappings.txt`. Both are handled explicitly.

## Convention going forward

When an upstream dependency is needed for a small, stable surface — an interface, a struct, a constant:

- Write or copy a minimal local file next to its consumer, following `src/bridge/adapters/interfaces/`.
- Preserve the upstream `SPDX-License-Identifier` verbatim; do not relicense it as BUSL-1.1.
- Record upstream repo, exact pinned rev, and upstream path in a `@dev` header so the copy can be diffed against its origin.
- Register the file's licence in the root `LICENSE` third-party note if it differs from BUSL-1.1.
- Add a submodule only when the dependency is genuinely multi-file and actively tracked. Before adding one, check the ratio of what it costs to what gets imported.

For non-permissively-licensed upstream *math*, ADR 0008 governs instead — it is a stricter case and its GPL analysis still applies.
