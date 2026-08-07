#!/usr/bin/env bash
# Rehearse the full from-scratch NAV deploy against a LOCAL anvil fork.
#
# Runs the real script sequence with the real config, in the RUNBOOK's order:
#   01_2 -> 02_2 -> 08 -> 03 -> RegisterAssets -> 04 -> 06
#
# ⚠️ `08` MUST come before `RegisterAssets`, and this script did NOT run it at all until the rehearsal
# caught that. An asset's PRIMARY registration is routed through `AssetKindRegistry.registerAsset` so
# the asset is registered, classified and LABELLED atomically. Without the registry deployed,
# `RegisterAssets` aborts `AssetKindRegistryNotDeployed`, deliberately, rather than falling back to
# `NAVCalculator.registerAsset` (which would succeed while leaving the run's assets unclassified and
# unlabelled — recoverable via `setAssetKinds`/`setAssetLabels`, but silently wrong until noticed).
#
# The header used to claim "THE RUNBOOK ORDER" while encoding the pre-#259 one. That CLAIM was the
# defect, not just the list beneath it: a preflight gate running a different sequence from the runbook
# is not a gate. When `08` moved to runbook step 1.4, the runbook, `README` and `verify_step.py` were
# updated and this executable was not.
#
# `RegisterAssets` MUST come after `03`: it resolves each Custom feed from
# `deployments/<id>.json .customPriceFeeds.<name>` (RegisterAssets.s.sol:19), so run earlier it logs
# `[skip] primary feed unresolved (deploy it first)` and skipped 20 of mainnet's 43 assets when this
# rehearsal first ran in the original plan's order. `01` is deliberately NOT run: it deploys a
# BridgeEscrow implementation nobody wants. (It no longer lacks the library pin assertions — those were
# added to it in the PR that supersedes #188 — so that is no longer a reason to skip it.)
#
# Asserts the things that are easy to get silently wrong:
#   * `initialize()` minted a FRESH ERC20Default (a new proxy is the entire reason for this deploy)
#   * the NAV proxy address is NOT the live one (if it is, DeploySalts.NAV_PROXY must be bumped)
#   * the meta-instance reconcile landed exactly the configured set
#   * every assistant's immutable ADAPTER points at the newly deployed assisted adapter
#
# SAFETY, two independent rails:
#   1. It REFUSES any RPC that is not loopback. This is the only script in the preflight tooling that
#      broadcasts at all.
#   2. The deploy scripts WRITE to `script/config/deployments/<id>.json` (and forge writes
#      `broadcast/<script>/<chainId>/`), so the config tree is treated as DISPOSABLE: the run refuses
#      to start unless `script/config` and `broadcast` are git-clean, and on exit it restores both
#      with `git checkout --` (byte-exact, whatever the run did) plus removal of any untracked files
#      it created, then ASSERTS both paths are clean again. `deployments/<id>.json` is the only record
#      of what production runs, so it must come back exactly as it was.
#
# usage:
#   script/deploy/preflight/rehearse_fork.sh [chainId] [forkBlock]
set -uo pipefail

CHAIN_ID="${1:-1}"
FORK_BLOCK="${2:-}"
PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="${REHEARSAL_DIR:-/tmp/nav-rehearsal-${CHAIN_ID}}"
cd "$ROOT"

# --- safety rail -------------------------------------------------------------
case "$RPC" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "REFUSING: rehearsal RPC '$RPC' is not loopback."; exit 2 ;;
esac

# --- disposable-config rail --------------------------------------------------
# The run mutates tracked config, so it must start from a clean slate: otherwise the `git checkout --`
# restore below would silently destroy someone's real uncommitted edits.
DIRTY="$(git status --porcelain -- script/config broadcast)"
if [[ -n "$DIRTY" ]]; then
  echo "REFUSING: script/config and broadcast/ must be git-clean before a rehearsal — the run"
  echo "mutates them and restores with 'git checkout --', which would discard these changes:"
  echo "$DIRTY"
  exit 2
fi

# --- port rail ---------------------------------------------------------------
# The readiness probe below is `cast block-number` against $RPC, which cannot tell OUR anvil from
# someone else's. If the port is already taken, `anvil --port` fails to bind and dies, the probe
# succeeds anyway against the incumbent, and the whole rehearsal then deploys into — and reports
# assertions about — a node it does not own. Observed: a 5-chain local dev stack holding 8546-8550,
# including a mainnet fork on the default port. So refuse a busy port outright.
if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${PORT}\b|0\.0\.0\.0:${PORT}\b|:::${PORT}\b"; then
  echo "REFUSING: port ${PORT} is already listening — something else owns it:"
  ss -ltnp 2>/dev/null | grep -E ":${PORT}\b" | sed 's/^/  /'
  echo "Pick a free port with ANVIL_PORT=<port> $0 $*"
  exit 2
fi

mkdir -p "$WORK"
: > "$WORK/steps.tsv"
echo -e "step\tseconds\tgas\tstatus" >> "$WORK/steps.tsv"
# Reference copy of the pre-run config, purely so the result can be diffed after the restore.
rm -rf "$WORK/config-before"
cp -r script/config "$WORK/config-before"

# RegisterAssets ends by writing a Safe-TX batch here and aborts if the directory is missing —
# AFTER broadcasting its on-chain registrations. The dir is gitignored, so a fresh checkout lacks it.
mkdir -p safe-transactions

# --- .env resolution ---------------------------------------------------------
# A git worktree has no .env of its own, so fall back to the canonical clone's — but ask GIT where
# that clone is rather than deriving it from $ROOT. `git rev-parse --git-common-dir` returns the
# MAIN clone's .git from inside ANY worktree (unlike --git-dir, which is the per-worktree one), so
# it resolves for a worktree NESTED at <repo>/.claude/worktrees/<name> exactly as well as for a
# sibling one. The previous `$(dirname "$ROOT")/onchain-accounting/.env` only ever hit when the
# worktree happened to sit beside the main clone; from a nested worktree it probed
# `.../worktrees/onchain-accounting/.env`, found nothing, and this script aborted on the
# ALCHEMY_API_KEY check below. The sibling probes are KEPT as additional candidates — they cost
# nothing and still cover a clone git cannot be asked about (no git binary, $ROOT not in a repo).
# Note they do NOT survive a renamed canonical clone: they hardcode the directory name, so a rename
# is exactly what breaks them and exactly what the git-derived candidate handles. The OIV env stays
# sibling-derived because it is a genuinely separate repo that git cannot discover from here.
#
# Emitted in PROBE order. Note this is NOT precedence order: the loop below sources forward and
# `set -a; source` assigns unconditionally, so the LAST existing candidate wins — unchanged from
# before this fix, and deliberately opposite to chainlib.load_env's `setdefault`. See the loop.
# Kept as a function so the guard test can extract it verbatim and drive each layout —
# see script/test/env-resolution-guards.test.sh.
env_candidates() {
  local root="$1" common canon
  # True only when $1 is the TOP directory of a non-bare working tree. git answers `rev-parse`
  # from any directory INSIDE a repo, and that willingness is a trap here: without this check two
  # layouts resolve to an unrelated .env and source it, which is strictly worse than the bug being
  # fixed, because pre-fix they found nothing and aborted loudly.
  #   * a tree with no .git of its own sitting inside an ancestor repo (a vendored or tarball copy,
  #     a Docker COPY): git walks UP and answers the ANCESTOR's .git, so the ancestor's .env wins;
  #   * a bare-repo-backed worktree (`git clone --bare` + `git worktree add`): --git-common-dir is
  #     the bare repo, whose parent is not a working tree at all — frequently $HOME, whose .env then
  #     gets sourced. Observed leaking a PRIVATE_KEY that way.
  # Every discovery call runs with the git environment CLEARED. GIT_DIR / GIT_WORK_TREE make
  # `rev-parse` answer about whatever they point at instead of about $d, which makes every check
  # below vacuous — and git EXPORTS GIT_DIR to hooks, so this is reachable, not theoretical.
  _g() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$1" rev-parse "${@:2}" 2>/dev/null; }
  # Absolute, symlink-resolved path, or failure. Never echoes empty on success.
  _real() { cd -P -- "$1" 2>/dev/null && pwd -P; }
  _is_worktree_top() {
    local d="$1" top dreal treal
    [[ "$(_g "$d" --is-bare-repository)" == "false" ]] || return 1
    top="$(_g "$d" --show-toplevel)" && [[ -n "$top" ]] || return 1
    # Resolve both before comparing — $root is legitimately a symlink in some checkouts — but with
    # `cd -P`, NOT `readlink -f`. readlink is absent on BSD/macOS, and on failure it prints NOTHING
    # and still exits 0 here, so an unresolvable path would compare "" == "" and the guard would
    # PASS precisely when it could not verify anything. `cd` fails loudly, so this fails closed.
    dreal="$(_real "$d")" && [[ -n "$dreal" ]] || return 1
    treal="$(_real "$top")" && [[ -n "$treal" ]] || return 1
    [[ "$dreal" == "$treal" ]]
  }
  # True only when $2 is the working tree that OWNS the git dir $1. Being *a* worktree top is not
  # enough: a bare repo's parent directory is frequently itself a checked-out repo — a
  # dotfiles-managed $HOME is the ordinary case — and that parent would otherwise be adopted as
  # "the canonical clone" and have its .env sourced, which is the very leak this guard exists for.
  _owns_gitdir() {
    local gitdir="$1" cand="$2" cand_common a b
    _is_worktree_top "$cand" || return 1
    cand_common="$(_g "$cand" --git-common-dir)" && [[ -n "$cand_common" ]] || return 1
    [[ "$cand_common" != /* ]] && cand_common="$cand/$cand_common"
    a="$(_real "$gitdir")" && b="$(_real "$cand_common")" || return 1
    [[ "$a" == "$b" ]]
  }
  printf '%s\n' "$root/.env"
  # Guarded: `git` may be absent, or $root may not be in a repo at all. Neither is fatal here.
  if _is_worktree_top "$root" \
     && common="$(_g "$root" --git-common-dir)" && [[ -n "$common" ]]; then
    # A normal checkout answers with a RELATIVE ".git"; a worktree answers absolute. Anchor the
    # relative form to $root (which is what `git -C` made it relative to) before taking the parent.
    [[ "$common" != /* ]] && common="$root/$common"
    # $canon must itself be a real working tree of a repo — see _is_worktree_top above for the two
    # layouts where "$common/.." is some unrelated directory.
    if canon="$(cd -- "$common/.." 2>/dev/null && pwd)" && _owns_gitdir "$common" "$canon"; then
      printf '%s\n' "$canon/.env"
      # OIV is a separate repo git cannot discover, so it stays sibling-derived — but a sibling of
      # the CANONICAL CLONE, not of $root. Deriving it from $root has the same defect the OA probe
      # had: from a nested worktree it points at `<repo>/.claude/worktrees/onchain-investment-…`,
      # so the OIV-only endpoints silently went missing there too.
      printf '%s\n' "$(dirname "$canon")/onchain-accounting/.env"
      printf '%s\n' "$(dirname "$canon")/onchain-investment-vehicles/.env"
    fi
  fi
  # The original $root-derived probes, kept as belt-and-braces: they still cover a canonical clone
  # reached outside git (no git binary, $root not in a repo). In a normal checkout or a sibling
  # worktree they duplicate the pair above and are deduped away.
  printf '%s\n' "$(dirname "$root")/onchain-accounting/.env"
  printf '%s\n' "$(dirname "$root")/onchain-investment-vehicles/.env"
}

# Source every candidate that exists, in order — the union matters, since the OIV env carries
# endpoints for 19 chains the OA env has none for.
#
# The ORDER AND PRECEDENCE HERE ARE DELIBERATELY UNCHANGED from before this fix. `set -a; source`
# assigns unconditionally, so the last file sourced wins, which means OIV outranks the OA env on
# the 6 keys they share. That is NOT what chainlib.load_env does — it uses `os.environ.setdefault`,
# so the FIRST file wins there — and the two disagree on 5 real keys, MAINNET_URL among them, which
# is the endpoint anvil forks from below. Reconciling them changes which RPC the rehearsal and the
# five chainlib-backed preflight tools actually use, so it is deliberately NOT bundled into a fix
# whose whole point is that it only moves path derivation. Left as-is on purpose; see the PR.
#
# The dedupe below is semantically neutral (re-sourcing a file is idempotent) and exists so the
# error listing reports what was really read rather than the same file three times.
ENV_FOUND=()
declare -A _env_seen=()
while IFS= read -r ENVF; do
  [[ -f "$ENVF" ]] || continue
  ENVREAL="$(readlink -f -- "$ENVF" 2>/dev/null)" || ENVREAL=""
  [[ -n "$ENVREAL" ]] || ENVREAL="$ENVF"
  # In a normal checkout every candidate resolves to the same file; source it once.
  [[ -n "${_env_seen[$ENVREAL]:-}" ]] && continue
  _env_seen["$ENVREAL"]=1
  ENV_FOUND+=("$ENVREAL")
done < <(env_candidates "$ROOT")

if (( ${#ENV_FOUND[@]} > 0 )); then
  for ENVF in "${ENV_FOUND[@]}"; do
    set -a; source "$ENVF"; set +a
  done
fi

if [[ -z "${ALCHEMY_API_KEY:-}" ]]; then
  {
    echo "REFUSING: ALCHEMY_API_KEY is not set. Candidates checked, in probe order:"
    while IFS= read -r ENVF; do
      if [[ -f "$ENVF" ]]; then echo "  read    $ENVF"; else echo "  absent  $ENVF"; fi
    done < <(env_candidates "$ROOT")
    echo "Define it in one of the files above, or export it before running."
  } >&2
  exit 1
fi
# --- the endpoint to fork ------------------------------------------------------
# This line used to read `FORK_URL="${MAINNET_URL:-https://eth-mainnet.g.alchemy.com/v2/$KEY}"`,
# which is ETHEREUM MAINNET regardless of $CHAIN_ID — while the other 17 uses of $CHAIN_ID in this
# script (chain config, deployment record, broadcast dir, every post-condition) faithfully followed
# the argument. So `rehearse_fork.sh 8453` read Base's config, wrote Base's records, asserted
# against Base's expectations — and forked Ethereum. It reported success without once contacting
# the chain it claimed to rehearse, which means NO NON-MAINNET CHAIN HAS EVER ACTUALLY BEEN
# REHEARSED by this script; every such claim is a mainnet run wearing another chain's label.
#
# Resolution is delegated to `chainlib.fork_rpc`, not reimplemented here, so the rehearsal and the
# five chainlib-backed preflight tools cannot drift apart on what a chain's endpoint is. That
# function is the literal generalisation of the old line — `$<CHAIN>_URL` first (the operator
# override that is how a deploy reaches chains the Alchemy app has disabled; a rehearsal is only
# worth running against the endpoint the deploy will use), then the chain config — so CHAIN 1
# RESOLVES EXACTLY AS BEFORE and only the other chains change.
#
# It FAILS CLOSED. A chain with no resolvable endpoint aborts here rather than falling back to
# anything, matching the house rule the deploy path already follows (RegisterAssets reverts
# `AssetKindRegistryNotDeployed` rather than quietly using a lesser path). A rehearsal that forks
# the wrong chain is worse than one that refuses to start, because it produces a green report.
#
# The URL carries the API key, so only the resolution NOTE is echoed — never the URL itself.
FORK_RPC_NOTE="$(python3 script/deploy/preflight/chainlib.py fork-rpc "$CHAIN_ID" 2>&1 >/dev/null)"
if ! FORK_URL="$(python3 script/deploy/preflight/chainlib.py fork-rpc "$CHAIN_ID" 2>/dev/null)" \
   || [[ -z "$FORK_URL" ]]; then
  echo "REFUSING: no RPC endpoint resolves for chain ${CHAIN_ID} (${FORK_RPC_NOTE})." >&2
  echo "This script will NOT fall back to another chain's endpoint — doing so is how a rehearsal" >&2
  echo "reports success for a chain it never contacted. Set \$${CHAIN_ID}'s URL env var (see" >&2
  echo "CHAIN_URL_ENV in script/deploy/preflight/chainlib.py) or fix its rpc in" >&2
  echo "script/config/chains/${CHAIN_ID}.json, then re-run." >&2
  exit 2
fi
echo "fork endpoint for chain ${CHAIN_ID}: ${FORK_RPC_NOTE}"

DEPLOYER="$(jq -r '.addresses.admin' "script/config/chains/${CHAIN_ID}.json")"
LIVE_PROXY="$(jq -r '.NAVCalculatorProxy // ""' "script/config/deployments/${CHAIN_ID}.json")"
LIVE_DEFAULT="$(jq -r '.balanceAdapters.ERC20Default // ""' "script/config/deployments/${CHAIN_ID}.json")"
echo "deployer=$DEPLOYER  live proxy=$LIVE_PROXY  live ERC20Default=$LIVE_DEFAULT"

# --- anvil -------------------------------------------------------------------
# `--gas-limit` and `--disable-block-gas-limit` are mutually exclusive in anvil; the explicit limit is
# what we want, since the NAV impl deploy alone is ~12.5M gas.
# Fork-request resilience is NOT optional here. anvil PANICS rather than retrying when an upstream
# state read fails mid-run — observed twice on 2026-07-30:
#   "pre-execution changes failed: Internal(Other(Database(GetStorage(0x…, error sending request …
#    connection reset))))" inside Backend::do_mine_block, killing anvil during 03's broadcast phase
# and taking the whole rehearsal with it (every later step then fails "Connection refused"). A rehearsal
# is a long sequence of state-heavy calls against a shared, rate-limited endpoint, so one reset is
# likely; the defaults do not survive it. Raise the fork-request timeout and retry budget.
ANVIL_ARGS=(--fork-url "$FORK_URL" --port "$PORT" --auto-impersonate --silent
            --gas-limit 60000000
            --retries "${ANVIL_RETRIES:-12}" --timeout "${ANVIL_TIMEOUT:-45000}"
            --fork-retry-backoff "${ANVIL_BACKOFF:-2}")
# Pinning the fork block also makes retries CHEAP as well as reproducible: foundry caches fork state per
# (chain, block) under ~/.foundry/cache/rpc, so a second attempt re-reads far fewer slots upstream —
# which is the difference between a retry that survives a flaky endpoint and one that trips it again.
[[ -n "$FORK_BLOCK" ]] && ANVIL_ARGS+=(--fork-block-number "$FORK_BLOCK")
anvil "${ANVIL_ARGS[@]}" > "$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!

RESTORED=0
cleanup() {
  kill "$ANVIL_PID" 2>/dev/null
  [[ $RESTORED -eq 1 ]] && return
  RESTORED=1

  # Keep a copy of what the run produced BEFORE throwing it away — it is the evidence for the
  # post-conditions (new proxy / ERC20Default / feed + adapter addresses).
  rm -rf "$WORK/config-after"
  cp -r script/config "$WORK/config-after" 2>/dev/null

  # Restore tracked state byte-exactly, whatever the run did to it. `git checkout --` is the
  # authoritative restore: deployments/<id>.json is the ONLY record of what production runs, and the
  # deploy scripts rewrite it wholesale (impl, proxy, every feed, every adapter incl. ERC20Default).
  git checkout -- script/config broadcast 2>/dev/null

  # Then remove anything UNTRACKED the run created under those paths. The fork runs as the REAL chain
  # id (ConfigReader keys config off it), so forge writes broadcast/<script>/<CHAIN_ID>/ — which looks
  # exactly like a genuine mainnet broadcast and is NOT covered by .gitignore (that only excludes
  # /broadcast/*/31337/). script/verify/sweeps/make_targets.py enumerates deployed price feeds by
  # reading precisely those files, so a leftover would feed fork addresses into a verification sweep.
  git clean -fdq -- script/config broadcast 2>/dev/null

  local dirty
  dirty="$(git status --porcelain -- script/config broadcast)"
  if [[ -n "$dirty" ]]; then
    echo "WARNING: script/config or broadcast/ is STILL dirty after restore — inspect by hand:"
    echo "$dirty"
  else
    echo "restored: script/config and broadcast/ are git-clean (run output kept in $WORK/config-after)"
  fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  # Liveness of OUR pid, checked first: a dead $ANVIL_PID with a healthy $RPC means the port belongs
  # to someone else, which is the one outcome that must never read as success.
  kill -0 "$ANVIL_PID" 2>/dev/null || { echo "our anvil (pid $ANVIL_PID) exited; see $WORK/anvil.log"; tail -5 "$WORK/anvil.log" | sed 's/^/  /'; exit 1; }
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || { echo "anvil never came up; see $WORK/anvil.log"; exit 1; }
kill -0 "$ANVIL_PID" 2>/dev/null || { echo "our anvil died but $RPC still answers — the port is not ours"; exit 1; }
echo "anvil up at $RPC, fork block $(cast block-number --rpc-url "$RPC")"

cast rpc anvil_setBalance "$DEPLOYER" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null

# --- clear the deployment record so 03/04 actually deploy --------------------
cp "script/config/deployments/${CHAIN_ID}.json" "$WORK/deployments-${CHAIN_ID}.orig.json"
python3 script/deploy/preflight/reset_deployment_records.py --apply \
  --tag "rehearsal-$$" "$CHAIN_ID" > "$WORK/reset.log" 2>&1 || {
    echo "reset_deployment_records failed; see $WORK/reset.log"; exit 1; }
rm -rf "script/deploy/preflight/archive/rehearsal-$$"
echo "cleared deployments/${CHAIN_ID}.json (original archived in $WORK)"

# --- per-step foundry profile ------------------------------------------------
# The RUNBOOK requires step 1.6 (RegisterAssets) to run under FOUNDRY_PROFILE=slow on mainnet, and this
# script was ignoring that — every step ran on the default profile. It is not a throughput preference:
# `[profile.slow]` raises gas_limit AND memory_limit from the default 1 GiB to 16 GiB precisely because
# registering the full asset set in one call frame accumulates quadratic EVM memory-expansion cost
# (foundry.toml:108-117). Measured on mainnet 2026-07-30: with all 25 custom feeds resolving, mainnet's
# 43 assets plan 86 actions and the script dies `EvmError: MemoryOOG` after wiring 19 of them, having
# registered 1 asset. So the rehearsal reported a blocker that the documented procedure does not have.
declare -A STEP_PROFILE=( [RegisterAssets]=slow )

# --- run a step --------------------------------------------------------------
run_step() {
  local label="$1"; shift
  local log="$WORK/${label}.log"
  echo "--- $label"
  local t0 t1 rc gas
  t0=$(date +%s)
  # Build the env prefix rather than inlining FOUNDRY_PROFILE=: an EMPTY FOUNDRY_PROFILE is not the same
  # as an unset one, and forge would look for a profile named "".
  local -a envp=(PERSIST_DEPLOYMENTS=1)
  local profile="${STEP_PROFILE[$label]:-}"
  if [[ -n "$profile" ]]; then
    envp+=(FOUNDRY_PROFILE="$profile")
    echo "    (FOUNDRY_PROFILE=$profile — required by the runbook for this step)"
  fi
  env "${envp[@]}" forge script "$@" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --slow \
    > "$log" 2>&1
  rc=$?
  t1=$(date +%s)
  # forge 1.7.1 prints "Estimated total gas used for script: <n>" (NOT the "Total Paid: … (n gas)"
  # form an earlier version used — matching only that yielded gas=0 for every step). Sum all
  # occurrences: a --slow run can emit one per broadcast batch.
  gas=$(grep -aoE "Estimated total gas used for script: [0-9]+" "$log" \
        | grep -oE "[0-9]+$" | paste -sd+ | bc 2>/dev/null)
  [[ -z "$gas" ]] && gas=0
  # Several scripts return cleanly when their precondition is unmet rather than reverting —
  # RegisterAssets prints "NAVCalculator not deployed for this chain" and returns, 06 prints
  # "BridgeEscrow not deployed, skipping", 03/04 print "Already deployed at:". Exit status 0 is
  # therefore NOT evidence that work happened, so treat these phrases as failures in a rehearsal
  # whose whole point is to prove the sequence does something.
  # Measured on the fork: with the proxy unset, 04 logs "ERROR: NAVCalculator not configured or
  # deployed, cannot deploy adapter" once per adapter (26x on mainnet) and STILL exits 0, and 06 logs
  # two "WARNING: ... skipping" and exits 0. 03 is the only one that reverts (NotAContract).
  local noop_re="NAVCalculator not deployed for this chain|Already deployed at:|No assets configured|ERROR: NAVCalculator not configured|WARNING: NAVCalculator not deployed"
  if grep -qaE "$noop_re" "$log"; then
    echo -e "${label}\t$((t1-t0))\t${gas}\tNO-OP" >> "$WORK/steps.tsv"
    echo "    NO-OP ($((t1-t0))s) — script exited 0 but did nothing:"
    grep -aE "$noop_re" "$log" | head -3 | sed 's/^/      /'
    return 1
  fi
  if [[ $rc -eq 0 ]] && ! grep -qa "^Error" "$log"; then
    echo -e "${label}\t$((t1-t0))\t${gas}\tOK" >> "$WORK/steps.tsv"
    echo "    OK  $((t1-t0))s  gas=${gas}"
  else
    echo -e "${label}\t$((t1-t0))\t${gas}\tFAIL" >> "$WORK/steps.tsv"
    echo "    FAIL ($((t1-t0))s) — tail of $log:"
    tail -25 "$log" | sed 's/^/      /'
    return 1
  fi
}

FAILED=0
# THE RUNBOOK ORDER. Two orderings here are load-bearing, not cosmetic — see the header:
#   * `08` before `RegisterAssets` — registration is routed through the registry, and it is the only
#     moment labels can be written. Omitting it aborts `RegisterAssets` (which is the guard working).
#   * `03` before `RegisterAssets` — Custom feeds must resolve, or 20 of 43 assets silently skip.
# `01` is intentionally absent (it deploys an unwanted BridgeEscrow impl; it now HAS the pin assertions).
run_step 01_2_DeployNAVImplementation script/deploy/01_2_DeployNAVImplementation.s.sol || FAILED=1
run_step 02_2_DeployNAVProxy        script/deploy/02_2_DeployNAVProxy.s.sol        || FAILED=1
run_step 08_DeployAssetKindRegistry script/deploy/08_DeployAssetKindRegistry.s.sol || FAILED=1
run_step 03_DeployPriceFeeds        script/deploy/03_DeployPriceFeeds.s.sol        || FAILED=1
run_step RegisterAssets             script/manage/RegisterAssets.s.sol             || FAILED=1
run_step 04_DeployBalanceAdapters   script/deploy/04_DeployBalanceAdapters.s.sol   || FAILED=1
run_step 06_Configure               script/deploy/06_Configure.s.sol               || FAILED=1

# --- assertions --------------------------------------------------------------
echo
echo "=== post-conditions ==="
NEW_PROXY="$(jq -r '.NAVCalculatorProxy // ""' "script/config/deployments/${CHAIN_ID}.json")"
NEW_DEFAULT="$(jq -r '.balanceAdapters.ERC20Default // ""' "script/config/deployments/${CHAIN_ID}.json")"
echo "new proxy         : $NEW_PROXY"
echo "new ERC20Default  : $NEW_DEFAULT"

assert() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILED=1; fi; }

assert "NAV proxy address differs from the live one (else bump DeploySalts.NAV_PROXY)" \
       '[[ -n "$NEW_PROXY" && "${NEW_PROXY,,}" != "${LIVE_PROXY,,}" ]]'
assert "initialize() minted a FRESH ERC20Default" \
       '[[ -n "$NEW_DEFAULT" && "${NEW_DEFAULT,,}" != "${LIVE_DEFAULT,,}" ]]'

if [[ -n "$NEW_PROXY" ]]; then
  ONCHAIN_DEFAULT=$(cast call "$NEW_PROXY" "erc20DefaultBalanceAdapter()(address)" --rpc-url "$RPC")
  assert "on-chain erc20DefaultBalanceAdapter matches the recorded one" \
         '[[ "${ONCHAIN_DEFAULT,,}" == "${NEW_DEFAULT,,}" ]]'
  ADAPTERS=$(cast call "$NEW_PROXY" "getAdapterCount()(uint256)" --rpc-url "$RPC")
  ASSETS=$(cast call "$NEW_PROXY" "getAssetCount()(uint256)" --rpc-url "$RPC")
  echo "adapters registered: $ADAPTERS   assets registered: $ASSETS"

  # meta-instance reconcile: sum getMetaInstances over every registered adapter and compare with config
  TOTAL=0
  for A in $(cast call "$NEW_PROXY" "getAllAdapters()(address[])" --rpc-url "$RPC" | tr -d '[]' | tr ',' ' '); do
    N=$(cast call "$NEW_PROXY" "getMetaInstances(address)(bytes32[])" "$A" --rpc-url "$RPC" \
        | tr -d '[]' | tr ',' '\n' | grep -c '0x' || true)
    TOTAL=$((TOTAL + N))
  done
  WANT=$(jq '[to_entries[] | select(.value.enabled == true)
             | ((.value.instances//[])|length) + ((.value.instancesRaw//[])|length)] | add // 0' \
         "script/config/nav-config/meta-balance-adapters/${CHAIN_ID}.json")
  echo "meta instances on-chain=$TOTAL configured=$WANT"
  assert "meta-instance reconcile landed exactly the configured set" '[[ "$TOTAL" == "$WANT" ]]'

  # Every registered asset must be registered, not silently skipped for want of a Custom feed.
  WANT_ASSETS=$(jq '[keys[] | select(startswith("$") | not)] | length' \
                "script/config/nav-config/assets-and-price-feeds/${CHAIN_ID}.json" 2>/dev/null || echo 0)
  echo "assets on-chain=$ASSETS configured=$WANT_ASSETS"
  assert "every configured asset registered (RegisterAssets ran after 03)" \
         '[[ "$ASSETS" == "$WANT_ASSETS" ]]'

  # Each assistant's immutable ADAPTER must point at the assisted adapter just deployed. On the live
  # stack all four are ORPHANS (they point at unregistered adapters left behind by the PR #141 swap),
  # so this is the assertion that proves the redeploy fixes it.
  for PAIR in "NexusMutualStakingPoolsAssistant:NexusMutualStakingPoolsAssisted" \
              "EtherFiWithdrawalQueueAssistant:EtherFiWithdrawalQueueAssisted" \
              "StakeWiseV3ExitQueueAssistant:StakeWiseV3ExitQueueAssisted"; do
    ASST_KEY=${PAIR%%:*}; ADAP_KEY=${PAIR##*:}
    ASST=$(jq -r ".${ASST_KEY} // \"\"" "script/config/deployments/${CHAIN_ID}.json")
    ADAP=$(jq -r ".balanceAdapters.${ADAP_KEY} // \"\"" "script/config/deployments/${CHAIN_ID}.json")
    [[ -z "$ASST" || -z "$ADAP" ]] && continue
    PTR=$(cast call "$ASST" "ADAPTER()(address)" --rpc-url "$RPC" 2>/dev/null | tr -d '\n')
    assert "${ASST_KEY}.ADAPTER() == ${ADAP_KEY} (got '${PTR}')" \
           '[[ -n "$PTR" && "${PTR,,}" == "${ADAP,,}" ]]'
  done
fi

cp "script/config/deployments/${CHAIN_ID}.json" "$WORK/deployments-${CHAIN_ID}.result.json"

# --- optional post-hook ------------------------------------------------------
# The NAV comparison against `snapshots/pre/` needs a window that exists ONLY here: the fork still
# running AND the deployment record still holding the fork's addresses. `cleanup` below closes both
# (it kills anvil and `git checkout --`s the record), so anything wanting to read the rehearsed stack
# has to run at this point. $REHEARSAL_HOOK is invoked with (chainId, rpc); its exit status is
# reported but deliberately does NOT fail the rehearsal, since the sequence itself already passed.
if [[ -n "${REHEARSAL_HOOK:-}" ]]; then
  echo
  echo "=== post-hook: $REHEARSAL_HOOK ==="
  "$REHEARSAL_HOOK" "$CHAIN_ID" "$RPC" || echo "  post-hook exited $? (does not fail the rehearsal)"
fi

cleanup

echo
echo "=== per-step timing / gas ==="
column -t "$WORK/steps.tsv"
echo
echo "logs + result record in $WORK"
DIRTY_END="$(git status --porcelain -- script/config broadcast)"
if [[ -n "$DIRTY_END" ]]; then
  echo "WARNING: script/config or broadcast/ still dirty — restore by hand:"
  echo "$DIRTY_END"
  FAILED=1
fi
exit $FAILED
