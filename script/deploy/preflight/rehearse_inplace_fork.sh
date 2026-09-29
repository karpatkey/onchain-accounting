#!/usr/bin/env bash
# Rehearse the PR #338 IN-PLACE migration against a LOCAL anvil fork of one chain.
#
# rehearse_fork.sh rehearses a FROM-SCRATCH deploy (fresh proxy). PR #338 instead upgrades the LIVE proxy
# in place and swaps every moved meta adapter, so it needs its own sequence. This is that sequence, in the
# migration plan's order, on a fork of the real chain:
#
#   pre-snapshot (fork) -> snapshot_and_clear_meta --apply -> 01_2 -> 04 -> deploy the REAL 1/1 ops Safe
#   (ops_safe.py deploy) -> grant it MANAGER -> upgradeToAndCall (EOA) -> upgrade-landed check
#   -> SwapMetaAdapter.plan() -> ONE atomic MultiSend execTransaction (ops_safe.py exec) -> wallet-adds batch
#   (emit_wallet_adds_batch.py) as a second MultiSend -> post-snapshot + diff_snapshots (value neutrality)
#   -> 06 idempotence -> RealignHeartbeats -> backfill NothingToDo -> Council grant (cast, not 07)
#   -> 11 + replay its batch as the Council -> timelock schedule/execute round trip -> role assertions.
#
# The ops Safe is a REAL Safe v1.4.1 deployed on the fork by the same tool and salt the live deploy uses, and
# each ops-Safe batch runs exactly as it will live: one `execTransaction` into MultiSendCallOnly, sent by the
# deployer (sole owner). So the batch gas reported is the real single-transaction gas, and a batch that cannot
# land atomically fails here.
#
# Safety: identical to rehearse_fork.sh — refuses a non-loopback RPC, refuses unless script/config and
# broadcast/ are git-clean, and restores both byte-exactly on exit — plus the GITIGNORED safe-transactions/
# (restored from a backup) and any new ignored broadcast/ dry-run files (removed). It never touches a live chain.
#
# usage:
#   script/deploy/preflight/rehearse_inplace_fork.sh [chainId] [forkBlock]
set -uo pipefail

CHAIN_ID="${1:-1}"
FORK_BLOCK="${2:-}"
PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="${REHEARSAL_DIR:-/tmp/nav-inplace-rehearsal-${CHAIN_ID}}"
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
# IN-PLACE MIGRATION SEQUENCE (PR #338). Everything ABOVE this banner is copied verbatim from
# rehearse_fork.sh — the loopback rail, the git-clean rail, the port rail, .env resolution, endpoint
# resolution, anvil start-up and the byte-exact restore. Keep the two in sync; they differ only below.
# =================================================================================================
REC="script/config/deployments/${CHAIN_ID}.json"
META_CFG="script/config/contracts-deployment-config/meta-balance-adapters/${CHAIN_ID}.json"
NAV_META_CFG="script/config/nav-config/meta-balance-adapters/${CHAIN_ID}.json"
COUNCIL="$(jq -r '.addresses.securityCouncil' "script/config/chains/${CHAIN_ID}.json")"
NAV="$LIVE_PROXY"
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
MANAGER_ROLE="$(cast keccak MANAGER)"
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
# The throwaway 1/1 ops Safe, deployed below (after the fork is up) with the live deploy's tool + salt, then
# granted MANAGER ONLY. Executing the swap and the wallet adds THROUGH it proves MANAGER alone suffices (the
# plan's HIGH-2) and that each batch lands as one atomic MultiSend; passing it to `11` as OPS_SAFE proves
# the handoff revokes it (Vigilo CRITICAL-01).
OPS_TOOL=script/deploy/preflight/ops_safe.py
OPS="$(python3 "$OPS_TOOL" address --rpc-url "$RPC" --owner "$DEPLOYER" 2>/dev/null)" \
  || { echo "REFUSING: cannot predict the ops Safe address (canonical Safe v1.4.1 missing on this fork?)"; exit 2; }
EXECUTOR=0x000000000000000000000000000000000000bEEF   # an arbitrary account, for the open-executor check
for A in "$COUNCIL" "$EXECUTOR"; do
  cast rpc anvil_setBalance "$A" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
done
mkdir -p safe-transactions

# A fork's oracles are FROZEN at the fork block, so letting its clock follow the wall clock makes short-heartbeat
# feeds go stale mid-run and price at 0 — a false value diff (observed on Arbitrum: USDC/USDT0 heartbeat 255 s,
# 206 s between snapshots → USDC stale → ACCOUNT_7 "-100%" with identical balances). Advance time 1 s per mined
# block instead. The clock still advances ~1 s per mined tx (≈60 blocks between snapshots on Arbitrum,
# ≈150 on mainnet), so a feed ALREADY near its heartbeat at the fork block can still go stale. That can only
# produce a false FAIL — and a visible one: check `stalePriceAssets` in the post snapshot — never a false PASS.
cast rpc anvil_setBlockTimestampInterval 1 --rpc-url "$RPC" >/dev/null \
  || { echo "REFUSING: could not pin the fork clock (anvil_setBlockTimestampInterval)"; exit 2; }

# snapshot_production.py resolves its endpoint by the chain's URL env var, so pointing that one var at the
# fork makes it snapshot the fork. Found the same way chainlib resolves it: CHAIN_URL_ENV first, then a
# `$VAR` in the chain config's rpc (Arc: `$ARC_RPC_URL`).
URL_VAR="$(python3 -c "import sys;sys.path.insert(0,'script/deploy/preflight');import chainlib as c;print(c.CHAIN_URL_ENV.get(${CHAIN_ID},''))")"
if [[ -z "$URL_VAR" ]]; then
  CFG_RPC="$(jq -r '.rpc // ""' "script/config/chains/${CHAIN_ID}.json")"
  [[ "$CFG_RPC" == \$* && "$CFG_RPC" != '$ALCHEMY' ]] && URL_VAR="${CFG_RPC#\$}"
fi
[[ -z "$URL_VAR" ]] && { echo "REFUSING: cannot point snapshot_production at the fork for chain $CHAIN_ID"; exit 2; }
# chainlib.probe_rpc tries the chain CONFIG endpoint ("$ALCHEMY") BEFORE any *_URL variable, so an override
# alone still snapshots the REAL chain (observed: rpcSource=alchemy, block advancing with mainnet). Unsetting
# ALCHEMY_API_KEY for this one call makes the config endpoint unresolvable, so the fork override is used.
# It must be set-to-EMPTY, not unset: chainlib.load_env re-reads .env and would restore an UNSET key, but it
# never overrides a key that is present (even empty) — the same setdefault rule rehearse_fork.sh mirrors.
# And it is VERIFIED, not assumed: a snapshot whose rpcSource does not name the override fails the step.
# A COLD fork fetches every slot upstream, so the heaviest accounts' getAccountNavVerbose can exceed chainlib's
# 120 s read timeout on the FIRST snapshot (observed on mainnet: 4 accounts "Read timed out" pre, all fine post).
# Retry a snapshot that recorded read errors — the retry hits the now-warm fork cache — and fail only if they persist.
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

# --- run a forge step (same contract as rehearse_fork.sh's run_step) --------------------------------
# One deliberate difference: in an IN-PLACE run `04` legitimately logs "Already deployed at:" for every
# PLAIN adapter (only the moved meta keys were cleared). ALLOW_ALREADY=1 drops that phrase from the no-op
# detector for that step; the post-conditions below then prove every cleared meta key got a NEW address.
declare -A STEP_PROFILE=()
run_step() {
  local label="$1"; shift
  local log="$WORK/${label}.log" t0 t1 rc gas
  echo "--- $label"
  t0=$(date +%s)
  local -a envp=(PERSIST_DEPLOYMENTS=1)
  local profile="${STEP_PROFILE[$label]:-}"
  [[ -n "$profile" ]] && envp+=(FOUNDRY_PROFILE="$profile")
  env "${envp[@]}" forge script "$@" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --slow > "$log" 2>&1
  rc=$?
  t1=$(date +%s)
  gas=$(grep -aoE "Estimated total gas used for script: [0-9]+" "$log" | grep -oE "[0-9]+$" | paste -sd+ | bc 2>/dev/null)
  [[ -z "$gas" ]] && gas=0
  # Full detector written STATICALLY (same phrases as rehearse_fork.sh, so its guard test can read it); the one
  # in-place exception REMOVES the skip phrase for the step that legitimately emits it (04) rather than the
  # other steps adding it — identical runtime behaviour, but visible to script/test/rehearsal-harness-guards.test.sh.
  local noop_re="NAVCalculator not deployed for this chain|[Aa]lready deployed|No assets configured|ERROR: NAVCalculator not configured|WARNING: NAVCalculator not deployed"
  [[ "${ALLOW_ALREADY:-0}" == 1 ]] && noop_re="${noop_re//|\[Aa\]lready deployed/}"
  if grep -qaE "$noop_re" "$log"; then
    echo -e "${label}\t$((t1-t0))\t${gas}\tNO-OP" >> "$WORK/steps.tsv"
    echo "    NO-OP ($((t1-t0))s):"; grep -aE "$noop_re" "$log" | head -3 | sed 's/^/      /'
    return 1
  fi
  if [[ $rc -eq 0 ]] && ! grep -qa "^Error" "$log"; then
    echo -e "${label}\t$((t1-t0))\t${gas}\tOK" >> "$WORK/steps.tsv"; echo "    OK  $((t1-t0))s  gas=${gas}"
  else
    echo -e "${label}\t$((t1-t0))\t${gas}\tFAIL" >> "$WORK/steps.tsv"
    echo "    FAIL ($((t1-t0))s) — tail of $log:"; tail -25 "$log" | sed 's/^/      /'
    return 1
  fi
}
# A forge script run WITHOUT --broadcast (plan() emitters, dry-run completion checks). Returns forge's rc.
sim_step() {
  local label="$1"; shift
  echo "--- $label (simulation, no broadcast)"
  forge script "$@" --rpc-url "$RPC" --sender "$DEPLOYER" > "$WORK/${label}.log" 2>&1
}
# One transaction from an impersonated account; records its gas. $1 label $2 from $3 to $4 calldata $5 value
TX_GAS=0
send_tx() {
  local r status gas
  r=$(cast send "$3" "$4" --value "${5:-0}" --from "$2" --unlocked --rpc-url "$RPC" --json 2>&1)
  status=$(echo "$r" | jq -r '.status // empty' 2>/dev/null)
  gas=$(echo "$r" | jq -r '.gasUsed // empty' 2>/dev/null); [[ -n "$gas" ]] && gas=$(cast to-dec "$gas")
  if [[ "$status" == "0x1" || "$status" == "1" ]]; then
    TX_GAS=$((TX_GAS + ${gas:-0})); echo "    ok  $1  gas=${gas}"; return 0
  fi
  echo "    FAIL $1 — $(echo "$r" | tail -3 | tr '\n' ' ' | cut -c1-300)"; return 1
}
# Replay a Safe Transaction-Builder batch file, in order, from $3. Refuses DELEGATECALL entries.
exec_batch() {
  local label="$1" file="$2" from="$3" n i to val data op
  [[ -f "$file" ]] || { echo "    FAIL $label — batch file $file missing"; return 1; }
  n=$(jq '.transactions | length' "$file")
  echo "--- $label: replaying $n transaction(s) from $from"
  TX_GAS=0
  for ((i = 0; i < n; i++)); do
    to=$(jq -r ".transactions[$i].to" "$file"); val=$(jq -r ".transactions[$i].value" "$file")
    data=$(jq -r ".transactions[$i].data" "$file"); op=$(jq -r ".transactions[$i].operation" "$file")
    [[ "$op" != "0" ]] && { echo "    FAIL $label — entry $i is operation $op (DELEGATECALL)"; return 1; }
    send_tx "${label}[$i]" "$from" "$to" "$data" "$val" || return 1
  done
  echo -e "${label}\t0\t${TX_GAS}\tOK(${n} tx)" >> "$WORK/steps.tsv"
  echo "    batch gas (sum of inner txs) = $TX_GAS"
}
# Run a Transaction-Builder batch through the REAL ops Safe as ONE MultiSend execTransaction (ops_safe.py).
ops_exec() {
  local label="$1" file="$2" out gas
  echo "--- $label: ONE execTransaction via ops Safe $OPS"
  out=$(python3 "$OPS_TOOL" exec --rpc-url "$RPC" --owner "$DEPLOYER" --safe "$OPS" --batch "$file" --send \
        -- --unlocked --from "$DEPLOYER" 2>&1)
  local rc=$?
  echo "$out" | sed 's/^/    /'
  gas=$(echo "$out" | grep -oE "gasUsed [0-9]+" | grep -oE "[0-9]+$")
  if (( rc == 0 )); then
    echo -e "${label}\t0\t${gas:-0}\tOK($(jq '.transactions|length' "$file") calls, 1 tx)" >> "$WORK/steps.tsv"; return 0
  fi
  echo -e "${label}\t0\t0\tFAIL" >> "$WORK/steps.tsv"; return 1
}
assert() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILED=1; fi; }
impl_of() { cast parse-bytes32-address "$(cast storage "$NAV" $IMPL_SLOT --rpc-url "$RPC")"; }
reg() { cast call "$NAV" 'isAdapterRegistered(address)(bool)' "$1" --rpc-url "$RPC" 2>/dev/null; }
ninst() { cast call "$NAV" 'getMetaInstances(address)(bytes32[])' "$1" --rpc-url "$RPC" 2>/dev/null | grep -o '0x[0-9a-fA-F]\{64\}' | wc -l; }
has() { cast call "$NAV" 'hasRole(bytes32,address)(bool)' "$1" "$2" --rpc-url "$RPC" 2>/dev/null; }

FAILED=0

# Snapshot the gitignored outputs BEFORE any step writes them; `cleanup` restores / prunes them (see there).
SAFE_TX_BACKUP="$WORK/safe-transactions.orig"
rm -rf "$SAFE_TX_BACKUP"; cp -a safe-transactions "$SAFE_TX_BACKUP"
IGNORED_BEFORE="$WORK/broadcast-ignored-before.txt"
git ls-files -oi --exclude-standard -- broadcast > "$IGNORED_BEFORE"

# --- 0. pre-snapshot of the FORK — the base state the Phase-2 post-snapshot is diffed against ---------
rm -rf "$WORK/pre" "$WORK/post"
echo "--- pre-snapshot (fork, before any step)"
snap "$WORK/pre" || { echo "pre-snapshot failed; see $WORK/pre.log"; tail -5 "$WORK/pre.log"; exit 1; }
PRE_IMPL="$(impl_of)"
FORK_HEAD="$(cast block-number --rpc-url "$RPC")"
echo "pre-upgrade impl: $PRE_IMPL"

# --- 0b. live swap-set sidecar: which enabled meta keys are REGISTERED pre-swap, and their set sizes ----
declare -A OLD=() OLDN=() LIVE=()
while IFS=$'\t' read -r name addr; do
  OLD[$name]="$addr"
  [[ -n "$addr" && "$(reg "$addr")" == "true" ]] || continue
  LIVE[$name]=1; OLDN[$name]=$(ninst "$addr")
done < <(jq -r --slurpfile rec "$REC" 'to_entries[] | select((.key|startswith("$")|not) and (.value|type=="object") and .value.enabled==true) | [.key, ($rec[0].balanceAdapters[.key] // "")] | @tsv' "$META_CFG")
echo "live (registered) meta adapters pre-swap: ${#LIVE[@]}"

# --- Phase 1 prep: snapshot + surgical clear of the moved meta keys ---------------------------------
python3 script/deploy/preflight/snapshot_and_clear_meta.py --apply "$CHAIN_ID" > "$WORK/clear.log" 2>&1 \
  || { echo "snapshot_and_clear_meta failed; see $WORK/clear.log"; exit 1; }
grep -E "meta key|WARN" "$WORK/clear.log" | head -4 | sed 's/^/  /'

# --- Phase 1: EOA deploys -----------------------------------------------------------------------------
run_step 01_2_DeployNAVImplementation script/deploy/01_2_DeployNAVImplementation.s.sol || FAILED=1
ALLOW_ALREADY=1 run_step 04_DeployBalanceAdapters script/deploy/04_DeployBalanceAdapters.s.sol || FAILED=1
NEW_IMPL="$(jq -r '.NAVCalculatorImplementation // ""' "$REC")"
# The live sheet's gates, run here so each is rehearsed before it is trusted on a real chain.
CHECK=script/deploy/preflight/pr338_check.py
gate() { local g="$1"; shift; python3 "$CHECK" "$g" "$CHAIN_ID" --rpc-url "$RPC" "$@" > "$WORK/gate-$g.log" 2>&1; }
gate phase1 --pre "$WORK/pre"; GATE_P1=$?
echo "--- deploy the 1/1 ops Safe (ops_safe.py deploy)"
python3 "$OPS_TOOL" deploy --rpc-url "$RPC" --owner "$DEPLOYER" --send -- --unlocked --from "$DEPLOYER" 2>&1 \
  | sed 's/^/    /'
[[ "${PIPESTATUS[0]}" == 0 ]] || FAILED=1
send_tx grant-ops-MANAGER "$DEPLOYER" "$NAV" "$(cast calldata 'grantRole(bytes32,address)' "$MANAGER_ROLE" "$OPS")" || FAILED=1

# --- Phase 2: upgrade (EOA, needs ADMIN), upgrade-landed gate, swap, wallet adds ------------------------
send_tx upgradeToAndCall "$DEPLOYER" "$NAV" "$(cast calldata 'upgradeToAndCall(address,bytes)' "$NEW_IMPL" 0x)" || FAILED=1
GOT_IMPL="$(impl_of)"
gate upgrade --pre "$WORK/pre"; GATE_UP=$?
echo "impl after upgrade: $GOT_IMPL (record: $NEW_IMPL)"

OPS_SAFE="$OPS" sim_step SwapMetaAdapter.plan script/manage/SwapMetaAdapter.s.sol --sig 'plan()'
PLAN_RC=$?
SWAP_JSON="safe-transactions/${CHAIN_ID}-swap-meta-adapters.json"
if (( ${#LIVE[@]} == 0 )); then
  assert "no live meta ⇒ plan() reverts NoMetaAdaptersToSwap (impl-only chain)" \
         'grep -qa NoMetaAdaptersToSwap "$WORK/SwapMetaAdapter.plan.log"'
  echo -e "swap-batch\t0\t0\tNONE(impl-only)" >> "$WORK/steps.tsv"
else
  if (( PLAN_RC != 0 )); then echo "    FAIL plan() — tail:"; tail -15 "$WORK/SwapMetaAdapter.plan.log" | sed 's/^/      /'; FAILED=1
  else ops_exec swap-batch "$SWAP_JSON" || FAILED=1; fi
fi

WALLET_JSON="safe-transactions/${CHAIN_ID}-wallet-adds.json"
echo "--- emit the wallet-adds batch (emit_wallet_adds_batch.py)"
python3 script/deploy/preflight/emit_wallet_adds_batch.py "$CHAIN_ID" --safe "$OPS" 2>&1 | sed 's/^/    /'
if [[ "${PIPESTATUS[0]}" != 0 ]]; then FAILED=1
elif [[ -f "$WALLET_JSON" ]]; then ops_exec wallet-adds-batch "$WALLET_JSON" || FAILED=1
else echo -e "wallet-adds-batch\t0\t0\tNONE" >> "$WORK/steps.tsv"; fi

gate swap --pre "$WORK/pre"; GATE_SWAP=$?

# --- Phase-2 value-neutrality check: post-snapshot NOW, before Phase 3/4 intentionally change heartbeats
#     and roles (which the structural diff would otherwise, correctly, flag). ---------------------------
echo "--- post-snapshot (fork, end of Phase 2)"
snap "$WORK/post" || { echo "post-snapshot failed; see $WORK/post.log"; FAILED=1; }
python3 script/deploy/preflight/diff_snapshots.py "$WORK/pre" "$WORK/post" --json "$WORK/diff.json" > "$WORK/diff.log" 2>&1
DIFF_RC=$?

# 06 must now have NOTHING to do (plan MEDIUM-3): any add/reconcile means the swap left a gap.
sim_step 06_Configure.idempotence script/deploy/06_Configure.s.sol
SIX_RC=$?

# --- Phase 3: heartbeats (EOA MANAGER), then the backfill completion check -----------------------------
run_step RealignHeartbeats script/manage/RealignHeartbeats.s.sol || FAILED=1
sim_step Backfill.plan script/manage/BackfillMetaInstanceClaimants.s.sol --sig 'plan()'

# --- Phase 4: Council grant via cast (NOT 07), then 11 executed by the Council -------------------------
send_tx grant-council-ADMIN   "$DEPLOYER" "$NAV" "$(cast calldata 'grantRole(bytes32,address)' "$ADMIN_ROLE" "$COUNCIL")"   || FAILED=1
send_tx grant-council-MANAGER "$DEPLOYER" "$NAV" "$(cast calldata 'grantRole(bytes32,address)' "$MANAGER_ROLE" "$COUNCIL")" || FAILED=1
export DEPLOYER_EOA="$DEPLOYER" SAFE_RETAINS_ROLES=true OPS_SAFE="$OPS"
run_step 11_DeployTimelockController script/deploy/11_DeployTimelockController.s.sol || FAILED=1
unset DEPLOYER_EOA SAFE_RETAINS_ROLES OPS_SAFE
exec_batch install-timelock "safe-transactions/${CHAIN_ID}-install-timelock.json" "$COUNCIL" || FAILED=1
TL="$(jq -r '.TimelockController // ""' "$REC")"
# One schedule -> execute round trip through the timelock (plan: "a timelock that cannot execute is a
# bricked NAV"). Idempotent payload: re-grant MANAGER to the timelock itself.
if [[ -n "$TL" ]]; then
  PAYLOAD="$(cast calldata 'grantRole(bytes32,address)' "$MANAGER_ROLE" "$TL")"
  SALT=0x00000000000000000000000000000000000000000000000000000000000000a1
  send_tx timelock-schedule "$COUNCIL" "$TL" "$(cast calldata 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' "$NAV" 0 "$PAYLOAD" "$ZERO32" "$SALT" 0)" || FAILED=1
  send_tx timelock-execute "$EXECUTOR" "$TL" "$(cast calldata 'execute(address,uint256,bytes,bytes32,bytes32)' "$NAV" 0 "$PAYLOAD" "$ZERO32" "$SALT")" || FAILED=1
fi

# Census from the fork block: grants made DURING the rehearsal are what it can get wrong; pre-fork holders are
# the live chain's and are covered by the live census (and by the explicit hasRole checks either way).
gate roles --ops-safe "$OPS" --council-retains --from-block "$FORK_HEAD"; GATE_ROLES=$?

# --- assertions ----------------------------------------------------------------------------------------
echo; echo "=== post-conditions ==="
DEFAULT="$(jq -r '.balanceAdapters.ERC20Default' "$REC")"
for G in P1:phase1 UP:upgrade SWAP:swap ROLES:roles; do
  v="GATE_${G%%:*}"; assert "pr338_check.py ${G#*:} gate passes (see $WORK/gate-${G#*:}.log)" "[[ ${!v} -eq 0 ]]"
done
assert "upgrade landed: 1967 slot == recorded new impl" '[[ -n "$NEW_IMPL" && "${GOT_IMPL,,}" == "${NEW_IMPL,,}" ]]'
assert "impl actually changed (new != pre-upgrade $PRE_IMPL)" '[[ "${GOT_IMPL,,}" != "${PRE_IMPL,,}" ]]'
for name in "${!LIVE[@]}"; do
  NEWA="$(jq -r --arg k "$name" '.balanceAdapters[$k] // ""' "$REC")"; OLDA="${OLD[$name]}"
  assert "$name: moved to a NEW address"          '[[ -n "$NEWA" && "${NEWA,,}" != "${OLDA,,}" ]]'
  assert "$name: OLD deregistered"                '[[ "$(reg "$OLDA")" == "false" ]]'
  assert "$name: NEW registered"                  '[[ "$(reg "$NEWA")" == "true" ]]'
  N_NEW=$(ninst "$NEWA")
  assert "$name: instance set carried (${OLDN[$name]} -> $N_NEW)" '[[ "$N_NEW" == "${OLDN[$name]}" ]]'
  assert "$name: OLD set cleared (no residue)"    '[[ "$(ninst "$OLDA")" == "0" ]]'
done
while IFS=$'\t' read -r name addr; do
  assert "wallet $name registered" '[[ -n "$addr" && "$(reg "$addr")" == "true" ]]'
  for tok in $(jq -r --arg k "$name" '.[$k].instances // [] | .[]' "$NAV_META_CFG"); do
    assert "  $name coord $tok no longer default-armed" \
           '[[ "$(cast call "$DEFAULT" "isSupportedByDefault(address)(bool)" "$tok" --rpc-url "$RPC")" == "false" ]]'
  done
done < <(jq -r --slurpfile rec "$REC" 'to_entries[] | select((.key|test("Wallet")) and (.value|type=="object") and .value.enabled==true) | [.key, ($rec[0].balanceAdapters[.key] // "")] | @tsv' "$META_CFG")
assert "post-snapshot was taken ON THE FORK (sees the new impl)" \
       '[[ "$(jq -r .implementation "$WORK/post/${CHAIN_ID}.json" | tr A-Z a-z)" == "${NEW_IMPL,,}" ]]'
assert "Phase-2 value-neutral: diff_snapshots pre->post passes (see $WORK/diff.log)" '[[ $DIFF_RC -eq 0 ]]'
# Positive check, not just "no Added/Reconciled": a 06 that REVERTS prints neither, and a gap the swap left
# (e.g. a double-claimed coordinate) is exactly what makes 06 revert. So require a clean exit AND its own
# zero-work summary line (`added` counts adapter registrations, `configured` counts instance reconciles).
assert "06_Configure exits cleanly and has nothing left to do (added 0, configured 0)" \
       '[[ $SIX_RC -eq 0 ]] && grep -qaE "Balance adapters: added 0 ; meta sets configured 0" "$WORK/06_Configure.idempotence.log"'
assert "backfill complete: plan() reverts NothingToDo" 'grep -qa NothingToDo "$WORK/Backfill.plan.log"'
assert "timelock deployed + recorded" '[[ -n "$TL" ]]'
if [[ -n "$TL" ]]; then
  assert "timelock holds ADMIN"   '[[ "$(has $ADMIN_ROLE "$TL")" == "true" ]]'
  assert "timelock holds MANAGER" '[[ "$(has $MANAGER_ROLE "$TL")" == "true" ]]'
fi
assert "deployer holds NO ADMIN"   '[[ "$(has $ADMIN_ROLE "$DEPLOYER")" == "false" ]]'
assert "deployer holds NO MANAGER" '[[ "$(has $MANAGER_ROLE "$DEPLOYER")" == "false" ]]'
assert "ops Safe holds NO MANAGER (revoked by 11)" '[[ "$(has $MANAGER_ROLE "$OPS")" == "false" ]]'
assert "ops Safe holds NO ADMIN"   '[[ "$(has $ADMIN_ROLE "$OPS")" == "false" ]]'
assert "Council retains ADMIN (SAFE_RETAINS_ROLES=true)"   '[[ "$(has $ADMIN_ROLE "$COUNCIL")" == "true" ]]'
assert "Council retains MANAGER (SAFE_RETAINS_ROLES=true)" '[[ "$(has $MANAGER_ROLE "$COUNCIL")" == "true" ]]'

echo; echo "=== diff_snapshots (pre -> end of Phase 2) ==="; tail -25 "$WORK/diff.log" | sed 's/^/  /'
cp "$REC" "$WORK/deployments-${CHAIN_ID}.result.json"
cp -r safe-transactions "$WORK/safe-transactions" 2>/dev/null

cleanup

echo; echo "=== per-step timing / gas ==="; column -t "$WORK/steps.tsv"
echo; echo "logs, snapshots, diff and emitted batches in $WORK"
DIRTY_END="$(git status --porcelain -- script/config broadcast)"
if [[ -n "$DIRTY_END" ]]; then echo "WARNING: script/config or broadcast/ still dirty:"; echo "$DIRTY_END"; FAILED=1; fi
(( FAILED )) && echo "RESULT: FAIL" || echo "RESULT: PASS"
exit $FAILED
