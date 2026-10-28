#!/usr/bin/env bash
# Rehearse the ADR 0029 rollout (PRs #354 + #358) against a LOCAL anvil fork of one chain.
#
# The sequence, as `script/deploy/ADR0029_ROLLOUT.md` prescribes it, on a fork of the real chain:
#
#   pre-snapshot -> EOA deploys: 01_2 (libraries + NAV implementation, CREATE2) -> retire the redeployed custom-feed
#   keys -> 03 (new custom feeds) -> census (every live Custom feed must show PRE-ROLLOUT: proves the check bites)
#   -> build ONE Council batch: removals (adr0029_batch.py) + MigrateToMonitorFeeds + upgradeToAndCall
#   -> execute it through the REAL Security Council Safe as one MultiSend (council_fork_exec.py: impersonated owners
#   approveHash, then one execTransaction) -> census (0 ERRORs) -> post-snapshot + diff -> assertions.
#
# Run it at a FRESH block and at a STALE block (a block where some primary is past its heartbeat), on 1, 8453 and
# 42161 at least (the sequencer chains carry Rule 1's hazard), plus one impl-only chain.
#
# Safety: identical to rehearse_inplace_fork.sh — refuses a non-loopback RPC, refuses unless script/config and
# broadcast/ are git-clean, and restores both byte-exactly on exit, plus the gitignored safe-transactions/. It never
# touches a live chain.
#
# usage:
#   script/deploy/preflight/rehearse_adr0029_fork.sh [chainId] [forkBlock]
#   EXPECT_ASSETS / EXPECT_ADAPTERS override the per-chain removal expectations (comma-separated addresses).
#   PREPEND_PARTS: space-separated stamped parts (e.g. from `adr0029_batch.py import`) placed FIRST in the batch,
#     for another team's Council calls bundled into the same Safe transaction (chain 1: the BTC Carry scheduleBatch).
#   POST_CHECK: a command run after the post-snapshot with ADR0029_FORK_RPC, REHEARSAL_WORK, REHEARSAL_CHAIN,
#     REHEARSAL_URL_VAR and REHEARSAL_COUNCIL set; its exit code is an assertion (e.g. warp past a timelock delay and
#     execute what a bundled part scheduled, or rehearse a rollback to the previous implementation).
set -uo pipefail

CHAIN_ID="${1:-1}"
FORK_BLOCK="${2:-}"
PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="${REHEARSAL_DIR:-/tmp/nav-adr0029-rehearsal-${CHAIN_ID}}"
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
# `.../worktrees/onchain-accounting/.env`, found nothing, and this script aborted for want of
# credentials it could not find. The sibling probes are KEPT as additional candidates — they cost
# nothing and still cover a clone git cannot be asked about (no git binary, $ROOT not in a repo).
# Note they do NOT survive a renamed canonical clone: they hardcode the directory name, so a rename
# is exactly what breaks them and exactly what the git-derived candidate handles. The OIV env stays
# sibling-derived because it is a genuinely separate repo that git cannot discover from here.
#
# Emitted in PROBE order, which IS precedence order: `load_env_files` below applies first-wins, so
# the earliest candidate defining a key decides it. See the rule stated in full at that function.
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

# THE PRECEDENCE RULE, stated once and implemented identically here and in `chainlib.load_env`:
#
#   Read every candidate that exists, in candidate order. The FIRST writer of a key wins, and a
#   value already present in the environment beats every file. Files therefore UNION — which is
#   load-bearing, since the OIV env carries endpoints for 19 chains the OA env has none for — while
#   the earliest source of any single key decides it. Precedence: environment > local .env >
#   canonical clone > OIV.
#
# This replaces `set -a; source`, under which the LAST file assigned unconditionally and so OIV
# outranked this repo's own .env, while chainlib's `os.environ.setdefault` gave the opposite answer.
# The two disagreed on 5 of the 6 keys the files share — MAINNET_URL among them, which is what anvil
# forks from — so the "so the tooling all sees one endpoint inventory" claim above was simply false.
# It is true now. The rule is EXPLICIT in both implementations rather than emergent from `source`
# order versus `setdefault`, because that emergence is exactly how the two drifted apart unnoticed.
#
# NOTE this repoints the rehearsal: keys the two files disagree on now resolve to the ONCHAIN-
# ACCOUNTING value, where this script previously used the onchain-investment-vehicles one. See the PR.
#
# Parsing is deliberate too. `source` executed the file, so a .env could run arbitrary shell and
# could silently override a variable the operator had exported on the command line. Both files are
# plain KEY=VALUE (verified: no `export`, no expansions, no substitutions, no continuations), so
# they are parsed, not executed.
load_env_files() {
  local f line k v n
  # Snapshot the exported environment; `compgen -e` lists exported names only.
  declare -A _env_exported=()
  while IFS= read -r n; do _env_exported["$n"]=1; done < <(compgen -e)
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"                 # ltrim
      [[ -z "$line" || "$line" == '#'* || "$line" != *=* ]] && continue
      k="${line%%=*}"; v="${line#*=}"
      k="${k%"${k##*[![:space:]]}"}"                          # rtrim key
      [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      # One matching pair of surrounding quotes, the same rule chainlib applies.
      # ONE pair, not two. As two sequential statements the single-quote strip ran on the output
      # of the double-quote strip, so `"'x'"` became `x` here and stayed `'x'` in chainlib.
      if (( ${#v} >= 2 )) && [[ "${v:0:1}" == "${v: -1}" ]]; then
        case "${v:0:1}" in '"'|"'") v="${v:1:${#v}-2}" ;; esac
      fi
      # Mirror `os.environ.setdefault` exactly: the test is membership of the EXPORTED
      # environment, not `[[ -v ]]`, which also sees ordinary shell variables. This script sets
      # plenty of those (CHAIN_ID, ROOT, WORK, PORT, RPC…), and any .env key colliding with one was
      # silently dropped here while chainlib happily loaded it. Set-but-empty still counts as set,
      # so an explicitly exported empty value wins, as setdefault does.
      [[ -n "${_env_exported[$k]:-}" ]] && continue
      export "$k=$v"
      _env_exported["$k"]=1
    done < "$f"
  done
}

# The dedupe below keeps the error listing honest about what was really read, and with first-wins
# it is no longer merely cosmetic: a file read twice would still only ever set a key once.
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
  load_env_files "${ENV_FOUND[@]}"
fi

# NO unconditional ALCHEMY_API_KEY gate here. It used to refuse outright when the key was unset,
# which contradicted this fix's own premise: `$<CHAIN>_URL` is the OPERATOR OVERRIDE and outranks
# the chain config, so `MAINNET_URL=https://my-own-node rehearse_fork.sh 1` is a perfectly good
# rehearsal that needs no Alchemy account at all. `chainlib.fork_rpc_spec` only emits an `alchemy:`
# spec when the key is present, and returns None with a precise note otherwise — so the requirement
# is already enforced exactly where it applies, per chain, instead of globally. The candidate
# listing that gate carried was genuinely useful and has moved into the single refusal below.
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
# It FAILS CLOSED, and the property is precisely "never another CHAIN's endpoint" — not "never any
# fallback". `fork_rpc_spec` can still return a `literal:` spec from PUBLIC_FALLBACK_RPC, which is a
# public endpoint for the SAME chain; five chains (143, 196, 204, 43111, 16661) have no
# CHAIN_URL_ENV entry and a credential-gated config rpc, so that fallback is the ONLY way to rehearse
# them at all. It is never silent: the note is echoed below, so a fallback run announces itself as
# `public fallback (unresolved ($ALCHEMY, ALCHEMY_API_KEY))`.
#
# ⚠️ OPEN QUESTION for review, raised by the review loop and deliberately NOT decided here: a public
# fallback lets the rehearsal go green in a credential state where the DEPLOY would fail, which is
# adjacent to the failure class this PR exists to end. Removing it would make those five chains
# un-rehearsable. Left as-is, visibly, rather than changed unilaterally.
#
# A chain with no endpoint at all aborts, matching the house rule the deploy path already follows
# (RegisterAssets reverts `AssetKindRegistryNotDeployed` rather than quietly using a lesser path). A
# rehearsal that forks the wrong chain is worse than one that refuses to start: it produces a green
# report.
#
# chainlib returns a SPEC naming the source, never the URL: the URL embeds $ALCHEMY_API_KEY, and
# emitting a secret on stdout is a real exposure channel however carefully this one caller handles
# it — CodeQL flags exactly that (py/clear-text-logging-sensitive-data, high) and is right to. This
# shell already holds the key in its own environment, so naming the source leaks nothing while every
# DECISION — which override wins, which network, when to give up — stays in chainlib.
# `_materialise_spec` there mirrors the case below, and the guard test asserts the two produce
# identical URLs so they cannot drift apart.
#
# ONE invocation, both streams captured separately: calling it twice, once for the note and once for
# the value, would be two sources of truth for a single decision.
FORK_RPC_RC=0
FORK_RPC_SPEC="$(python3 script/deploy/preflight/chainlib.py fork-rpc "$CHAIN_ID" 2>"$WORK/rpc.err")" \
  || FORK_RPC_RC=$?
FORK_RPC_NOTE="$(cat "$WORK/rpc.err" 2>/dev/null)"
FORK_URL=""
if (( FORK_RPC_RC == 0 )) && [[ -n "$FORK_RPC_SPEC" ]]; then
  case "$FORK_RPC_SPEC" in
    # Two steps deliberately: `${!VAR#env:}` does NOT mean "strip the prefix, then expand
    # indirectly" — bash applies the modifier to the indirect result, so it silently yields nothing.
    env:*)     FORK_ENV_VAR="${FORK_RPC_SPEC#env:}"; FORK_URL="${!FORK_ENV_VAR:-}" ;;
    alchemy:*) FORK_URL="https://${FORK_RPC_SPEC#alchemy:}.g.alchemy.com/v2/${ALCHEMY_API_KEY:-}" ;;
    literal:*) FORK_URL="${FORK_RPC_SPEC#literal:}" ;;
    *)         FORK_RPC_NOTE="unrecognised spec '${FORK_RPC_SPEC}' (${FORK_RPC_NOTE})" ;;
  esac
fi
if [[ -z "$FORK_URL" ]]; then
  {
    echo "REFUSING: no RPC endpoint resolves for chain ${CHAIN_ID} (${FORK_RPC_NOTE})."
    echo "This script will NOT fall back to another chain's endpoint — doing so is how a rehearsal"
    echo "reports success for a chain it never contacted."
    echo "Set that chain's URL env var (see CHAIN_URL_ENV in script/deploy/preflight/chainlib.py),"
    echo "or set ALCHEMY_API_KEY, or fix the rpc in script/config/chains/${CHAIN_ID}.json."
    echo ".env candidates, in probe order (first wins):"
    while IFS= read -r ENVF; do
      if [[ -f "$ENVF" ]]; then echo "  read    $ENVF"; else echo "  absent  $ENVF"; fi
    done < <(env_candidates "$ROOT")
  } >&2
  exit 2
fi
# The announcement is the load-bearing property of keeping the public fallback at all: a fallback
# run is CORRECT-BY-ANNOUNCEMENT, not silent, which is the line this whole script is about. A single
# line in a long transcript is easy to skim past, so a fallback says so in a banner and repeats it in
# the step table, where anyone reading the result will meet it.
echo "fork endpoint for chain ${CHAIN_ID}: ${FORK_RPC_NOTE}"
if [[ "$FORK_RPC_NOTE" == public\ fallback* ]]; then
  echo "############################################################################"
  echo "## PUBLIC FALLBACK IN USE for chain ${CHAIN_ID} — ${FORK_RPC_NOTE}"
  echo "## The configured endpoint did NOT resolve. This rehearsal is running against"
  echo "## a public RPC for the RIGHT chain, but the DEPLOY would fail in this same"
  echo "## credential state. A green result here does NOT prove the deploy can run."
  echo "############################################################################"
  echo -e "fork-endpoint\t0\t0\tPUBLIC-FALLBACK" >> "$WORK/steps.tsv"
fi

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
  # safe-transactions/ and broadcast/**/dry-run are GITIGNORED, so the git-clean rail and the checkout/clean
  # restore below cannot see them. The fork writes real-looking batches there (e.g. 1-swap-meta-adapters.json
  # stamped with the stand-in ops address), which could overwrite — or be mistaken for — a real prepared batch.
  if [[ -n "${SAFE_TX_BACKUP:-}" && -d "$SAFE_TX_BACKUP" ]]; then
    rm -rf safe-transactions && cp -a "$SAFE_TX_BACKUP" safe-transactions \
      && echo "restored: safe-transactions/ to its pre-run state (fork batches kept in $WORK/safe-transactions)"
  fi
  if [[ -n "${IGNORED_BEFORE:-}" && -f "$IGNORED_BEFORE" ]]; then
    comm -13 <(sort "$IGNORED_BEFORE") <(git ls-files -oi --exclude-standard -- broadcast | sort) \
      | while IFS= read -r f; do rm -f -- "$f"; done
  fi
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
# Unlike rehearse_fork.sh (which traps INT/TERM with the same non-exiting handler), a signal must END the
# run after restoring: a handler that returns lets bash carry on into later steps against a dead anvil.
trap cleanup EXIT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT

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

# =================================================================================================
# ADR 0029 ROLLOUT SEQUENCE. Everything ABOVE this banner is copied verbatim from rehearse_inplace_fork.sh
# (itself copied from rehearse_fork.sh) — the rails, .env and endpoint resolution, anvil start-up and the
# byte-exact restore. Keep them in sync; they differ only below.
# =================================================================================================
REC="script/config/deployments/${CHAIN_ID}.json"
COUNCIL="$(jq -r '.addresses.securityCouncil' "script/config/chains/${CHAIN_ID}.json")"
NAV="$LIVE_PROXY"
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
B=safe-transactions
mkdir -p "$B"
# Same reason as rehearse_inplace_fork.sh: a fork's oracles are frozen, so advance the clock 1 s per block.
cast rpc anvil_setBlockTimestampInterval 1 --rpc-url "$RPC" >/dev/null \
  || { echo "REFUSING: could not pin the fork clock (anvil_setBlockTimestampInterval)"; exit 2; }

# snapshot_production.py / the census / the batch builder read the fork through an env var, never a URL argument.
URL_VAR="$(python3 -c "import sys;sys.path.insert(0,'script/deploy/preflight');import chainlib as c;print(c.CHAIN_URL_ENV.get(${CHAIN_ID},''))")"
if [[ -z "$URL_VAR" ]]; then
  CFG_RPC="$(jq -r '.rpc // ""' "script/config/chains/${CHAIN_ID}.json")"
  [[ "$CFG_RPC" == \$* && "$CFG_RPC" != '$ALCHEMY' ]] && URL_VAR="${CFG_RPC#\$}"
fi
[[ -z "$URL_VAR" ]] && { echo "REFUSING: cannot point snapshot_production at the fork for chain $CHAIN_ID"; exit 2; }
export ADR0029_FORK_RPC="$RPC"

snap() {
  local try n=0
  for try in 1 2 3; do
    env ALCHEMY_API_KEY= "$URL_VAR=$RPC" python3 script/deploy/preflight/snapshot_production.py \
      --out "$1" "$CHAIN_ID" > "$1.log" 2>&1 || return 1
    n="$(jq '.errors | length' "$1/${CHAIN_ID}.json")"
    (( n == 0 )) && break
    echo "    snapshot attempt $try recorded $n read error(s) — retrying on the warm cache"
  done
  (( n == 0 )) || { echo "    FAIL snapshot still has $n read error(s) after 3 attempts (see $1/${CHAIN_ID}.json)"; return 1; }
  local src; src="$(jq -r '.rpcSource // ""' "$1/${CHAIN_ID}.json")"
  [[ "$src" == *"$URL_VAR"* ]] || { echo "    FAIL snapshot read '$src', NOT the fork (${URL_VAR})"; return 1; }
  echo "    snapshot source: $src, block $(jq -r .block "$1/${CHAIN_ID}.json")"
}

# A forge broadcast step from the deployer EOA (CREATE2 deploys need no role).
run_step() {
  local label="$1"; shift
  local log="$WORK/${label}.log" t0 t1 rc
  echo "--- $label"
  t0=$(date +%s)
  # FOUNDRY_PROFILE=slow: EVM memory/gas caps only (no compiler setting, so no bytecode or CREATE2 change); 03 and
  # MigrateToMonitorFeeds hit MemoryOOG under the default 1 GiB caps on mainnet's config, as #338's deploys did.
  env PERSIST_DEPLOYMENTS=1 FOUNDRY_PROFILE=slow forge script "$@" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --slow > "$log" 2>&1
  rc=$?
  t1=$(date +%s)
  if [[ $rc -eq 0 ]] && ! grep -qa "^Error" "$log"; then
    echo -e "${label}\t$((t1-t0))\t-\tOK" >> "$WORK/steps.tsv"; echo "    OK  $((t1-t0))s"; return 0
  fi
  echo -e "${label}\t$((t1-t0))\t-\tFAIL" >> "$WORK/steps.tsv"
  echo "    FAIL ($((t1-t0))s) — see $log:"; grep -aE "^Error|Error:|revert" "$log" | tail -3 | cut -c1-300 | sed 's/^/      /'
  return 1
}
assert() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILED=1; fi; }
impl_of() { cast parse-bytes32-address "$(cast storage "$NAV" $IMPL_SLOT --rpc-url "$RPC")"; }
census() { python3 script/deploy/preflight/adr0029_census.py --chain "$CHAIN_ID" --rpc-env ADR0029_FORK_RPC --base HEAD "$@"; }

FAILED=0
SAFE_TX_BACKUP="${WORK:?}/safe-transactions.orig"
rm -rf "${SAFE_TX_BACKUP:?}"; cp -a "$B" "$SAFE_TX_BACKUP"
IGNORED_BEFORE="$WORK/broadcast-ignored-before.txt"
git ls-files -oi --exclude-standard -- broadcast > "$IGNORED_BEFORE"

# Per-chain removal expectations (issue #357). The batch builder refuses unless what it derives equals these.
case "$CHAIN_ID" in
  1)     DEF_ASSETS=0xbf5495Efe5DB9ce00f80364C8B423567e58d2110,0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83
         DEF_ADAPTERS=0x9145A559108426e1eA429A2A6441e2A875f069ec ;;
  42161) DEF_ASSETS=0x2416092f143378750bb29b79eD961ab195CcEea5
         DEF_ADAPTERS=0x9145A559108426e1eA429A2A6441e2A875f069ec ;;
  *)     DEF_ASSETS=""; DEF_ADAPTERS="" ;;
esac
# Assets this round REGISTERS (config entries not yet live): asserted registered after the batch.
case "$CHAIN_ID" in
  1) DEF_NEW_ASSETS=0x4045FcF533C84578e754be939821d26A087FC7C9 ;;  # Merkl "USD Coin (wrapped)" (2026-10-28)
  *) DEF_NEW_ASSETS="" ;;
esac
EXPECT_NEW_ASSETS="${EXPECT_NEW_ASSETS-$DEF_NEW_ASSETS}"
EXPECT_ASSETS="${EXPECT_ASSETS-$DEF_ASSETS}"
EXPECT_ADAPTERS="${EXPECT_ADAPTERS-$DEF_ADAPTERS}"

# --- 0. pre-snapshot ---------------------------------------------------------------------------------
rm -rf "${WORK:?}/pre" "${WORK:?}/post"
echo "--- pre-snapshot (fork, before any step)"
snap "$WORK/pre" || { echo "pre-snapshot failed; see $WORK/pre.log"; tail -5 "$WORK/pre.log"; exit 1; }
PRE_IMPL="$(impl_of)"
echo "pre-upgrade impl: $PRE_IMPL"

# --- 1. EOA deploys ----------------------------------------------------------------------------------
run_step 01_2_DeployNAVImplementation script/deploy/01_2_DeployNAVImplementation.s.sol || FAILED=1
NEW_IMPL="$(jq -r '.NAVCalculatorImplementation // ""' "$REC")"
# Redeployed keys = every ENABLED custom feed that already has a recorded address (new keys deploy fresh).
KEYS="$(python3 - "$CHAIN_ID" <<'PY'
import json, os, sys
c = sys.argv[1]
p = f"script/config/contracts-deployment-config/custom-price-feeds/{c}.json"
cfg = json.load(open(p)) if os.path.exists(p) else {}
rec = json.load(open(f"script/config/deployments/{c}.json")).get("customPriceFeeds") or {}
print(",".join(k for k, v in cfg.items() if not k.startswith("$") and isinstance(v, dict)
               and v.get("enabled") is True and str(rec.get(k, "")).startswith("0x")))
PY
)"
if [[ -n "$KEYS" ]]; then
  echo "--- retire the redeployed custom-feed keys ($(tr ',' '\n' <<<"$KEYS" | wc -l))"
  python3 script/deploy/preflight/retire_custom_feeds.py --chain "$CHAIN_ID" --keys "$KEYS" \
    --reason "ADR 0029 rehearsal" --apply > "$WORK/retire.log" 2>&1 || { echo "    FAIL retire (see $WORK/retire.log)"; FAILED=1; }
  run_step 03_DeployPriceFeeds script/deploy/03_DeployPriceFeeds.s.sol || FAILED=1
else
  echo "--- no recorded custom feeds on this chain: 03 skipped (impl-only chain)"
fi

# --- 2. census BEFORE the batch: every live Custom feed must be flagged PRE-ROLLOUT ----------------------
census > "$WORK/census-pre.log" 2>&1
N_CUSTOM="$(grep -oE 'custom [0-9]+' "$WORK/census-pre.log" | head -1 | grep -oE '[0-9]+')"
N_PRE="$(grep -c 'PRE-ROLLOUT' "$WORK/census-pre.log")"
N_ERR_PRE="$(grep -c 'ERROR:' "$WORK/census-pre.log")"
echo "census before the batch: ${N_CUSTOM:-?} live Custom feeds, ${N_PRE} PRE-ROLLOUT, ${N_ERR_PRE} ERROR line(s)"

# --- 3. build the ONE Council batch -------------------------------------------------------------------
rm -f "${B:?}/${CHAIN_ID:?}-adr0029-removals.json" "${B:?}/${CHAIN_ID:?}-migrate-monitor-feeds.json" \
      "${B:?}/${CHAIN_ID:?}-adr0029-rollout.json"
echo "--- removals (adr0029_batch.py; expect assets [$EXPECT_ASSETS] adapters [$EXPECT_ADAPTERS])"
python3 script/deploy/preflight/adr0029_batch.py removals --chain "$CHAIN_ID" --rpc-env ADR0029_FORK_RPC \
  --expect-assets "$EXPECT_ASSETS" --expect-adapters "$EXPECT_ADAPTERS" \
  --out "$B/${CHAIN_ID}-adr0029-removals.json" > "$WORK/removals.log" 2>&1 || FAILED=1
sed 's/^/    /' "$WORK/removals.log"
echo "--- RegisterAssets (plan only; simulated as the Council): assets in config but not yet registered"
# Placed after the removals and before Migrate (which skips unregistered assets, so the new asset's monitor is planned
# here only). It writes a part only when it has work; "Nothing to register" with no part is the normal case.
cast rpc anvil_setBalance "$COUNCIL" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
rm -f "${B:?}/${CHAIN_ID:?}-register-assets.json"
FOUNDRY_PROFILE=slow forge script script/manage/RegisterAssets.s.sol --rpc-url "$RPC" --sender "$COUNCIL" \
  > "$WORK/register.log" 2>&1 || { echo "    FAIL register plan (see $WORK/register.log)"; grep -aE "^Error|Error:|revert" "$WORK/register.log" | tail -3 | cut -c1-300 | sed 's/^/      /'; FAILED=1; }
grep -E "Planned actions|wiring|Nothing to register" "$WORK/register.log" | head -8 | sed 's/^/    /'
echo "--- MigrateToMonitorFeeds (plan only; simulated as the Council, which holds MANAGER)"
# forge refuses to simulate a sender that cannot pay gas; the Council Safe holds no native token on some L2s.
cast rpc anvil_setBalance "$COUNCIL" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
FOUNDRY_PROFILE=slow forge script script/manage/MigrateToMonitorFeeds.s.sol --rpc-url "$RPC" --sender "$COUNCIL" \
  > "$WORK/migrate.log" 2>&1 || { echo "    FAIL migrate plan (see $WORK/migrate.log)"; grep -aE "^Error|Error:|revert" "$WORK/migrate.log" | tail -3 | cut -c1-300 | sed 's/^/      /'; FAILED=1; }
grep -E "Planned adds/sets|Planned removes|Nothing to migrate|skip" "$WORK/migrate.log" | head -8 | sed 's/^/    /'
echo "--- assemble (${PREPEND_PARTS:+prepended [$PREPEND_PARTS] + }removals + migrate + upgradeToAndCall $NEW_IMPL + governance)"
# Migrate writes no file when it has nothing to plan (a chain with no assets). Leave its part out ONLY when its
# log says so explicitly; any other missing file is a failure that `assemble` reports.
PARTS=()
for P in ${PREPEND_PARTS:-}; do PARTS+=("$P"); done
PARTS+=("$B/${CHAIN_ID}-adr0029-removals.json")
if grep -q "Nothing to register" "$WORK/register.log" && [[ ! -f "$B/${CHAIN_ID}-register-assets.json" ]]; then
  echo "    (RegisterAssets planned nothing on this chain — its part is omitted)"
else
  PARTS+=("$B/${CHAIN_ID}-register-assets.json")
fi
# "Nothing to migrate" is also printed when the new feeds are missing from the record (every asset logs
# "[skip asset] target primary not deployed"); that must stay a loud failure, so a "[skip" line disqualifies it.
if grep -q "Nothing to migrate" "$WORK/migrate.log" && ! grep -q "\[skip" "$WORK/migrate.log" \
   && [[ ! -f "$B/${CHAIN_ID}-migrate-monitor-feeds.json" ]]; then
  echo "    (MigrateToMonitorFeeds planned nothing on this chain — its part is omitted)"
else
  PARTS+=("$B/${CHAIN_ID}-migrate-monitor-feeds.json")
fi
# The timelock handover (2026-10-27 request): updateDelay(3 days) + the Council renouncing its direct NAV roles, placed
# AFTER the upgrade. On by default; GOVERNANCE=0 rehearses the batch without it.
FINAL_PARTS=()
if [[ "${GOVERNANCE:-1}" != 0 ]]; then
  echo "--- governance (timelock handover, appended after the upgrade)"
  python3 script/deploy/preflight/adr0029_batch.py governance --chain "$CHAIN_ID" --rpc-env ADR0029_FORK_RPC \
    --out "$B/${CHAIN_ID}-adr0029-governance.json" > "$WORK/governance.log" 2>&1 || FAILED=1
  sed 's/^/    /' "$WORK/governance.log"
  FINAL_PARTS+=("$B/${CHAIN_ID}-adr0029-governance.json")
fi
python3 script/deploy/preflight/adr0029_batch.py assemble --chain "$CHAIN_ID" \
  --parts "${PARTS[@]}" ${FINAL_PARTS[@]:+--final-parts "${FINAL_PARTS[@]}"} \
  --upgrade-impl "$NEW_IMPL" --out "$B/${CHAIN_ID}-adr0029-rollout.json" > "$WORK/assemble.log" 2>&1 || FAILED=1
sed 's/^/    /' "$WORK/assemble.log"
cp -f "$B/${CHAIN_ID}-adr0029-rollout.json" "$WORK/" 2>/dev/null

# --- 4. execute it through the REAL Security Council Safe, as one MultiSend -----------------------------
echo "--- execute through the Council Safe $COUNCIL (council_fork_exec.py)"
python3 script/deploy/preflight/council_fork_exec.py --rpc-url "$RPC" --safe "$COUNCIL" \
  --batch "$B/${CHAIN_ID}-adr0029-rollout.json" > "$WORK/exec.log" 2>&1; EXEC_RC=$?
head -1 "$WORK/exec.log" | sed 's/^/    /'

# The implementation right after the batch, captured now: a POST_CHECK may change it (e.g. a rollback rehearsal), and the
# assertions below run after the post-check.
IMPL_AFTER_BATCH="$(impl_of)"
# Governance state right after the batch, for the same reason.
TIMELOCK="$(jq -r '.TimelockController // ""' "script/config/deployments/${CHAIN_ID}.json")"
role_held() { cast call "$1" "hasRole(bytes32,address)(bool)" "$2" "$3" --rpc-url "$RPC" 2>/dev/null; }
MANAGER_ROLE_HASH="$(cast keccak MANAGER)"; ADMIN_ROLE_HASH=0x0000000000000000000000000000000000000000000000000000000000000000
GOV_AFTER="delay=$(cast call "$TIMELOCK" 'getMinDelay()(uint256)' --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')"
GOV_AFTER+=" council_admin=$(role_held "$NAV" $ADMIN_ROLE_HASH "$COUNCIL") council_mgr=$(role_held "$NAV" "$MANAGER_ROLE_HASH" "$COUNCIL")"
GOV_AFTER+=" tl_admin=$(role_held "$NAV" $ADMIN_ROLE_HASH "$TIMELOCK") tl_mgr=$(role_held "$NAV" "$MANAGER_ROLE_HASH" "$TIMELOCK")"
echo "    governance after the batch: $GOV_AFTER"

# Keep every part (the forge-written migrate JSON, the removals, the assembled batch): the cleanup restores
# safe-transactions/ from its backup and would otherwise destroy them.
rm -rf "${WORK:?}/safe-transactions" && cp -r "$B" "$WORK/safe-transactions"

# --- 5. after the batch ---------------------------------------------------------------------------------
census > "$WORK/census-post.log" 2>&1; CENSUS_POST=$?
echo "--- post-snapshot"
snap "$WORK/post" || { echo "post-snapshot failed; see $WORK/post.log"; FAILED=1; }
python3 script/deploy/preflight/diff_snapshots.py "$WORK/pre" "$WORK/post" --json "$WORK/diff.json" > "$WORK/diff.log" 2>&1
POST_CHECK_RC=0
if [[ -n "${POST_CHECK:-}" ]]; then
  # After the post-snapshot and diff (a post-check may warp time, which would age every feed) and before the
  # assertions, which therefore read the implementation captured right after the batch, not the live one.
  echo "--- post-check: $POST_CHECK"
  ADR0029_FORK_RPC="$RPC" REHEARSAL_WORK="$WORK" REHEARSAL_CHAIN="$CHAIN_ID" REHEARSAL_URL_VAR="$URL_VAR" \
    REHEARSAL_COUNCIL="$COUNCIL" bash -c "$POST_CHECK" > "$WORK/post-check.log" 2>&1; POST_CHECK_RC=$?
  sed 's/^/    /' "$WORK/post-check.log" | tail -12
fi

echo; echo "=== ASSERTIONS (chain $CHAIN_ID, fork block $(jq -r .block "$WORK/pre/${CHAIN_ID}.json" 2>/dev/null)) ==="
assert "census BEFORE ran (its chain header is present — a crashed census cannot pass vacuously)" \
  'grep -q "^=== chain ${CHAIN_ID}:" "$WORK/census-pre.log"'
assert "census BEFORE flags every live Custom feed as PRE-ROLLOUT (the check bites)" \
  '[[ -n "$N_CUSTOM" && "$N_CUSTOM" == "$N_PRE" && "$N_ERR_PRE" == "$N_PRE" && ( -z "$KEYS" || "$N_CUSTOM" -gt 0 ) ]]'
assert "the batch executed atomically through the Council Safe" '[[ $EXEC_RC -eq 0 ]]'
assert "the NAV runs the new implementation ($NEW_IMPL)" \
  '[[ "$(tr A-F a-f <<<"$IMPL_AFTER_BATCH")" == "$(tr A-F a-f <<<"$NEW_IMPL")" && "$NEW_IMPL" != "$PRE_IMPL" ]]'
assert "census AFTER: 0 ERRORs (Rule 1 + Rule 2)" '[[ $CENSUS_POST -eq 0 ]]'
if [[ "${GOVERNANCE:-1}" != 0 ]]; then
  assert "handover: delay 259200, the Council holds no NAV role, the timelock holds both ($GOV_AFTER)" \
    '[[ "$GOV_AFTER" == "delay=259200 council_admin=false council_mgr=false tl_admin=true tl_mgr=true" ]]'
fi
if [[ -n "${POST_CHECK:-}" ]]; then
  assert "post-check passed ($WORK/post-check.log)" '[[ $POST_CHECK_RC -eq 0 ]]'
fi
for A in ${EXPECT_ASSETS//,/ }; do
  assert "asset $A unregistered" '[[ "$(cast call "$NAV" "isAssetRegistered(address)(bool)" "$A" --rpc-url "$RPC")" == false ]]'
done
for A in ${EXPECT_NEW_ASSETS//,/ }; do
  assert "new asset $A registered" '[[ "$(cast call "$NAV" "isAssetRegistered(address)(bool)" "$A" --rpc-url "$RPC")" == true ]]'
done
for A in ${EXPECT_ADAPTERS//,/ }; do
  assert "adapter $A deregistered" '[[ "$(cast call "$NAV" "isAdapterRegistered(address)(bool)" "$A" --rpc-url "$RPC")" == false ]]'
done

echo; echo "=== census after (tail) ==="; tail -4 "$WORK/census-post.log" | sed 's/^/  /'
echo; echo "=== diff_snapshots pre -> post (tail; expect the removed assets' legs, the feed moves and, with the handover, the Council's two role DIFFs True -> False) ==="
tail -30 "$WORK/diff.log" | sed 's/^/  /'
echo; echo "=== steps ==="; column -t "$WORK/steps.tsv" | sed 's/^/  /'
echo; echo "batch: $WORK/${CHAIN_ID}-adr0029-rollout.json   exec: $WORK/exec.log"
if (( FAILED )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
