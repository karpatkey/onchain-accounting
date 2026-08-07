#!/usr/bin/env python3
"""Shared helpers for the preflight tools: repo paths, RPC resolution, JSON-RPC, deployment enumeration.

RPC resolution mirrors `script/utils/ConfigReader.sol` exactly:
  - `"$ALCHEMY"`      -> https://<network>.g.alchemy.com/v2/$ALCHEMY_API_KEY, network from
                         `_alchemyNetworkForChainId` (ConfigReader.sol:769)
  - `"$FOO"`          -> os.environ["FOO"]
  - anything else     -> used verbatim
A chain whose RPC cannot be resolved is reported, never silently skipped.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import requests

REPO = Path(__file__).resolve().parents[3]
CHAINS_DIR = REPO / "script/config/chains"
DEPLOY_DIR = REPO / "script/config/deployments"
NAV_CONFIG_DIR = REPO / "script/config/nav-config"
CONTRACTS_CONFIG_DIR = REPO / "script/config/contracts-deployment-config"
PREFLIGHT_DIR = REPO / "script/deploy/preflight"
SNAPSHOT_DIR = PREFLIGHT_DIR / "snapshots"

# ConfigReader.sol:769 `_alchemyNetworkForChainId`. Kept in the same order as the source so a
# drift check is a straight visual diff.
ALCHEMY_NETWORK = {
    1: "eth-mainnet",
    10: "opt-mainnet",
    56: "bnb-mainnet",
    100: "gnosis-mainnet",
    42161: "arb-mainnet",
    8453: "base-mainnet",
    137: "polygon-mainnet",
    1101: "polygonzkevm-mainnet",
    80094: "berachain-mainnet",
    999: "hyperliquid-mainnet",
    57073: "ink-mainnet",
    59144: "linea-mainnet",
    204: "opbnb-mainnet",
    146: "sonic-mainnet",
    130: "unichain-mainnet",
    534352: "scroll-mainnet",
    196: "xlayer-mainnet",
    42220: "celo-mainnet",
    43114: "avax-mainnet",
    5000: "mantle-mainnet",
    480: "worldchain-mainnet",
    143: "monad-mainnet",
    9745: "plasma-mainnet",
}

# Per-chain URL env vars. `ConfigReader` does NOT read these — it resolves `$ALCHEMY` from
# ALCHEMY_API_KEY only — but `forge script --rpc-url` overrides the config, and this is how the
# 2026-07-22 redeploy actually reached the chains the Alchemy app does not have enabled. Keeping the
# mapping here means the preflight sees exactly the endpoint inventory the deploy will have.
CHAIN_URL_ENV = {
    1: "MAINNET_URL", 10: "OP_URL", 56: "BNB_URL", 100: "GNOSIS_URL", 130: "UNICHAIN_URL",
    137: "POLYGON_URL", 146: "SONIC_URL", 480: "WORLDCHAIN_URL", 999: "HYPEREVM_URL",
    5000: "MANTLE_URL", 8453: "BASE_URL", 9745: "PLASMA_URL", 42161: "ARBITRUM_URL",
    42220: "CELO_URL", 43114: "AVALANCHE_URL", 57073: "INK_URL", 59144: "LINEA_URL",
    80094: "BERACHAIN_URL", 534352: "SCROLL_URL",
}

# Public fallbacks for chains with no configured endpoint at all. Read-only use only; the deploy
# itself must use a proper endpoint.
PUBLIC_FALLBACK_RPC = {
    43111: "https://rpc.hemi.network/rpc",
    16661: "https://evmrpc.0g.ai",
    143: "https://rpc.monad.xyz",
    196: "https://rpc.xlayer.tech",
    204: "https://opbnb-mainnet-rpc.bnbchain.org",
}


def _git(cwd: Path, *args: str) -> str | None:
    """Run `git -C cwd <args>` and return stripped stdout, or None if it fails at all.

    The git environment is CLEARED: GIT_DIR / GIT_WORK_TREE make `rev-parse` answer about whatever
    they point at rather than about `cwd`, which makes every check below vacuous — and git exports
    GIT_DIR to hooks, so this is reachable rather than theoretical.
    """
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR")}
    try:
        out = subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True, text=True, timeout=10, check=True, env=env,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return out or None


def _owns_gitdir(gitdir: Path, candidate: Path) -> bool:
    """True only when `candidate` is the working tree that OWNS `gitdir`.

    Being *a* working-tree top is not enough: a bare repo's parent directory is frequently itself a
    checked-out repo — a dotfiles-managed ``$HOME`` is the ordinary case — and that parent would
    otherwise be adopted as "the canonical clone" and have its .env read first.
    """
    if not _is_worktree_top(candidate):
        return False
    common = _git(candidate, "rev-parse", "--git-common-dir")
    if not common:
        return False
    try:
        return (candidate / common).resolve() == gitdir.resolve()
    except OSError:
        return False


def _is_worktree_top(path: Path) -> bool:
    """True only when `path` is the TOP directory of a non-bare working tree.

    git answers `rev-parse` from any directory INSIDE a repository, and that willingness is a trap:
    without this check, a tree with no `.git` of its own that merely sits inside an ancestor repo
    (a vendored or tarball copy) makes git walk UP and report the ANCESTOR, whose unrelated `.env`
    is then read; and the parent of a bare repo is reported as a "clone" although it is not a
    working tree at all.
    """
    if _git(path, "rev-parse", "--is-bare-repository") != "false":
        return False
    top = _git(path, "rev-parse", "--show-toplevel")
    if not top:
        return False
    try:
        # Resolved comparison: the checkout is legitimately reached via a symlink in some setups.
        return Path(top).resolve() == path.resolve()
    except OSError:
        return False


def _canonical_repo_root() -> Path | None:
    """The MAIN clone's working tree for a normal checkout or a git worktree, else None.

    Not "whatever the layout is": a SUBMODULE resolves to `<super>/.git/modules/<name>`, whose
    parent is not a working tree, so this returns None there and the sibling candidates apply —
    the pre-fix behaviour, degraded to safely rather than silently pointed at the superproject.

    `git rev-parse --git-common-dir` reports the main clone's `.git` from inside ANY worktree —
    unlike `--git-dir`, which reports the per-worktree one — so this resolves for a worktree nested
    at `<repo>/.claude/worktrees/<name>` as well as for a sibling one. Deriving the canonical clone
    from `REPO.parent` instead (as this module used to) only worked for the sibling layout.

    A normal checkout answers with a relative ``.git``; joining onto `REPO` handles that, and is a
    no-op when the answer is absolute. Both `REPO` and the derived root are required to be genuine
    working-tree tops — see `_is_worktree_top`. Returns None when git is unavailable, `REPO` is not
    a repository top, or the result is not one, none of which is an error: the sibling candidates
    still apply, exactly as before this fix.
    """
    if not _is_worktree_top(REPO):
        return None
    out = _git(REPO, "rev-parse", "--git-common-dir")
    if not out:
        return None
    common = REPO / out
    # Take the parent LEXICALLY, mirroring the shell twin's logical `cd -- "$common/.."`.
    # `.resolve().parent` would resolve symlinks across the whole path first, so a clone whose
    # `.git` is a symlink to a relocated git dir would yield the TARGET's parent — an unrelated
    # directory — instead of the clone. The two implementations must agree.
    canonical = Path(os.path.normpath(str(common))).parent
    return canonical if _owns_gitdir(common, canonical) else None


def _default_env_files() -> list[Path]:
    """.env candidates in PRECEDENCE order — `load_env` uses `setdefault`, so the first wins.

    `REPO / ".env"` leads, matching `env_candidates` in rehearse_fork.sh exactly — the two must
    produce the SAME ordered list, or "one endpoint inventory" is untrue again the moment a worktree
    carries its own .env. (The previous PR deliberately left this asymmetry alone because changing
    precedence was out of its scope; unifying precedence is the whole point of this one.)
    """
    candidates: list[Path] = [REPO / ".env"]
    canonical = _canonical_repo_root()
    if canonical is not None:
        candidates.append(canonical / ".env")
        # OIV is a separate repo git cannot discover, so it stays sibling-derived — but a sibling of
        # the CANONICAL CLONE, not of REPO. Deriving it from REPO carries the same defect the OA
        # probe had: from a nested worktree it points at
        # `<repo>/.claude/worktrees/onchain-investment-vehicles`, so the OIV-only endpoints go
        # missing exactly where the OA env does.
        candidates += [
            canonical.parent / "onchain-accounting" / ".env",
            canonical.parent / "onchain-investment-vehicles" / ".env",
        ]
    # The original REPO-derived probes, kept as belt-and-braces: they still cover a canonical clone
    # reached outside git (no git binary, REPO not in a repository). Deduped away otherwise.
    candidates += [
        REPO.parent / "onchain-accounting" / ".env",
        REPO.parent / "onchain-investment-vehicles" / ".env",
    ]
    # In a normal checkout several candidates are the same file; keep the first occurrence of each.
    seen: set[Path] = set()
    unique: list[Path] = []
    for path in candidates:
        try:
            key = path.resolve()
        except OSError:
            key = path
        if key not in seen:
            seen.add(key)
            unique.append(path)
    return unique


DEFAULT_ENV_FILES = _default_env_files()


_ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def load_env(dotenv: Path | None = None) -> None:
    """Load KEY=VALUE lines from .env files into os.environ.

    THE PRECEDENCE RULE, identical to `load_env_files` in `rehearse_fork.sh`:
    read every candidate in order; the FIRST writer of a key wins, and a value already in the
    environment beats every file. Files therefore UNION — load-bearing, because the OIV env carries
    endpoints for 19 chains this repo's own .env has none for — while the earliest source of any one
    key decides it. Precedence: environment > local .env > canonical clone > OIV.

    The shell twin used to `source` forward, so its LAST file won and OIV outranked this repo's own
    .env, giving a different answer from this function on 5 of the 6 keys the files share —
    MAINNET_URL among them, which is what the rehearsal forks. Keeping the rule stated and
    implemented explicitly on both sides is the point: the drift happened precisely because one side
    got its precedence from `source` order and the other from `setdefault`.
    """
    for path in ([dotenv] if dotenv else DEFAULT_ENV_FILES):
        if not path or not path.exists():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            # Same key filter as the shell twin's `[[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]`.
            # Without it the two sides diverge on any non-identifier line — `export FOO=x` (key
            # "export FOO") or `MY-VAR=x` are skipped by bash and accepted here — which breaks the
            # "one endpoint inventory" invariant this loader exists to uphold, and quietly puts
            # unusable names into the environment of five preflight tools.
            if not _ENV_KEY_RE.match(k):
                continue
            # ONE matching pair of surrounding quotes — not `.strip('"').strip("'")`, which peels
            # any number from either end independently and cannot be mirrored exactly in shell.
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                v = v[1:-1]
            os.environ.setdefault(k, v)


def all_chain_ids() -> list[int]:
    return sorted(int(p.stem) for p in DEPLOY_DIR.glob("*.json"))


def deployed_chain_ids() -> list[int]:
    """Chains whose deployment record currently holds a NAVCalculatorProxy.

    NOT a safe default for a tool's chain scope — see `resolve_chains`. This reads *live* record
    state, and runbook step 1.1 (`reset_deployment_records.py --apply`) sets `NAVCalculatorProxy` to
    `""` on every chain, at which point this returns `[]`.
    """
    out = []
    for cid in all_chain_ids():
        if deployment(cid).get("NAVCalculatorProxy"):
            out.append(cid)
    return out


SCOPE_FILE = PREFLIGHT_DIR / "redeploy_scope.json"


def snapshot_scope(tag: str = "pre") -> list[int]:
    """The chains present in `snapshots/<tag>/index.json`.

    NOT a scope authority — `snapshot_production.py` rebuilds this index, and a chain that failed
    capture is absent from it. Used only to cross-check the declared scope and report gaps.
    """
    idx = SNAPSHOT_DIR / tag / "index.json"
    if not idx.is_file():
        return []
    doc = json.loads(idx.read_text())
    return sorted({int(e["chainId"]) for e in doc.get("chains", []) if e.get("chainId")})


def declared_scope() -> list[int]:
    """The hand-maintained scope from `redeploy_scope.json`. No tool writes that file."""
    if not SCOPE_FILE.is_file():
        return []
    doc = json.loads(SCOPE_FILE.read_text())
    return sorted({int(x) for x in doc.get("chains", [])})


def redeploy_scope() -> tuple[list[int], str, list[str]]:
    """The chains in the redeploy scope, as (chain_ids, source, complaints).

    The scope is DECLARED, not inferred. Every derived candidate is rewritten by something in the
    deploy: `deployments/<id>.json .NAVCalculatorProxy` is blanked by runbook step 1.1, and
    `snapshots/pre/index.json` is rebuilt from whichever chains the last `snapshot_production.py` run
    covered — so a chain that failed capture, or a documented per-chain re-snapshot, silently shrinks
    it. A scope that quietly gets smaller is the same defect as a checker that quietly passes, so the
    declared list wins and every disagreement with derived state is reported rather than absorbed.
    """
    complaints: list[str] = []
    ids = declared_scope()
    if ids:
        missing_record = [c for c in ids if not (DEPLOY_DIR / f"{c}.json").is_file()]
        if missing_record:
            complaints.append(
                f"declared scope names {missing_record} with no script/config/deployments/<id>.json")
        snap = set(snapshot_scope("pre"))
        if snap:
            gaps = [c for c in ids if c not in snap]
            if gaps:
                complaints.append(
                    f"{len(gaps)} declared chain(s) {gaps} are NOT in snapshots/pre/index.json — the "
                    f"pre-deploy capture is incomplete for them, so the before/after comparison and "
                    f"any 'address actually moved' check cannot be made there")
            extra = sorted(snap - set(ids))
            if extra:
                complaints.append(
                    f"snapshots/pre/index.json holds {extra}, absent from the declared scope")
        return ids, str(SCOPE_FILE.relative_to(REPO)), complaints

    complaints.append(f"{SCOPE_FILE} is missing — falling back to derived state, which the deploy "
                      f"itself rewrites. Restore the file before trusting any scope.")
    ids = sorted(set(snapshot_scope("pre")) | set(deployed_chain_ids()))
    return ids, "fallback: snapshots/pre/index.json + populated NAVCalculatorProxy", complaints


def resolve_chains(explicit: list[int] | None) -> tuple[list[int], str]:
    """Resolve a tool's chain scope, exiting non-zero rather than silently checking nothing.

    Every preflight tool used to default to `deployed_chain_ids()`, which reads the deployment
    records — the very files step 1.1 blanks. An empty list then flows straight through the tool's
    main loop: `preflight_config.py` reports `0 error(s) across 0 chain(s)` and exits 0, and
    `reset_deployment_records.py --restore <tag>` restores nothing and exits 0, so the rollback path
    fails silently at the exact moment it is needed. Since the whole point of this suite is that a
    clean exit must mean work happened, an unresolvable scope has to be fatal, not empty.
    """
    if explicit:
        declared = set(declared_scope())
        chosen = sorted(set(explicit))
        note = "command line"
        if declared:
            omitted = sorted(declared - set(chosen))
            if omitted:
                # Not an error — a per-chain run is legitimate — but it must be visible, because the
                # whole point of a scope banner is that nobody mistakes a subset for the whole.
                note += f" (SUBSET: {len(omitted)} declared chain(s) not covered: {omitted})"
        return chosen, note
    ids, src, complaints = redeploy_scope()
    for c_ in complaints:
        print(f"SCOPE WARNING: {c_}", file=sys.stderr)
    if not ids:
        print("ERROR: could not resolve any chain to operate on.\n"
              f"  {SCOPE_FILE} is missing or empty, and neither snapshots/pre/index.json nor a\n"
              "  populated NAVCalculatorProxy in script/config/deployments/*.json yielded a chain\n"
              "  list. Restore redeploy_scope.json, or pass the chain ids explicitly.",
              file=sys.stderr)
        sys.exit(2)
    return ids, src


def chain_config(chain_id: int) -> dict:
    p = CHAINS_DIR / f"{chain_id}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def deployment(chain_id: int) -> dict:
    p = DEPLOY_DIR / f"{chain_id}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def resolve_rpc(chain_id: int, allow_fallback: bool = True,
                config_only: bool = False) -> tuple[str | None, str]:
    """Return (url, note). url is None when the chain has no resolvable endpoint.

    `config_only=True` resolves exactly the way `ConfigReader` does, so the preflight can report
    which chains a bare `forge script` (no `--rpc-url`) would fail to reach.
    """
    cfg = chain_config(chain_id)
    raw = cfg.get("rpc", "")
    if raw == "$ALCHEMY":
        net = ALCHEMY_NETWORK.get(chain_id)
        key = os.environ.get("ALCHEMY_API_KEY", "")
        if net and key:
            return f"https://{net}.g.alchemy.com/v2/{key}", "alchemy"
        missing = "ALCHEMY_API_KEY" if net else f"no alchemy network mapped for {chain_id}"
        note = f"unresolved ($ALCHEMY, {missing})"
    elif raw.startswith("$"):
        val = os.environ.get(raw[1:], "")
        if val:
            return val, f"env {raw[1:]}"
        note = f"unresolved ({raw} not in env)"
    elif raw:
        return raw, "literal"
    else:
        note = "no rpc in chain config"

    if config_only:
        return None, note
    # `--rpc-url $<CHAIN>_URL` overrides the chain config; this is how the previous redeploy reached
    # the chains the Alchemy app has disabled.
    envvar = CHAIN_URL_ENV.get(chain_id)
    if envvar and os.environ.get(envvar):
        return os.environ[envvar], f"env {envvar} (config rpc {raw} unusable)"
    if allow_fallback and chain_id in PUBLIC_FALLBACK_RPC:
        return PUBLIC_FALLBACK_RPC[chain_id], f"public fallback ({note})"
    return None, note


def fork_rpc_spec(chain_id: int) -> tuple[str | None, str]:
    """WHERE a local fork of `chain_id` gets its endpoint — named, never materialised. (spec, note).

    This is the primitive; `fork_rpc` is derived from it. It returns a SOURCE DESCRIPTOR rather than
    a URL so that a caller which only needs to be told where to look never has to handle the secret:

        env:<VARNAME>      read that environment variable
        alchemy:<network>  build https://<network>.g.alchemy.com/v2/$ALCHEMY_API_KEY
        literal:<url>      a non-secret URL committed in the chain config

    None means nothing resolved, and the caller MUST abort rather than substitute another chain's
    endpoint — the defect this whole path exists to end.

    Operator override FIRST, the opposite of `resolve_rpc` (which mirrors ConfigReader, where the
    chain config wins). `$<CHAIN>_URL` is how the 2026-07-22 redeploy reached the chains the Alchemy
    app has disabled, and a rehearsal is only worth running against the endpoint the deploy will
    use. This is the literal generalisation of what `rehearse_fork.sh` did for ONE chain
    (`FORK_URL="${MAINNET_URL:-<eth-mainnet alchemy>}"`), so chain 1 resolves exactly as before.
    """
    envvar = CHAIN_URL_ENV.get(chain_id)
    if envvar and os.environ.get(envvar):
        return f"env:{envvar}", f"env {envvar}"

    raw = chain_config(chain_id).get("rpc", "")
    if raw == "$ALCHEMY":
        net = ALCHEMY_NETWORK.get(chain_id)
        if net and os.environ.get("ALCHEMY_API_KEY"):
            return f"alchemy:{net}", "alchemy"
        note = ("unresolved ($ALCHEMY, ALCHEMY_API_KEY)" if net
                else f"unresolved (no alchemy network mapped for {chain_id})")
    elif raw.startswith("$"):
        if os.environ.get(raw[1:]):
            return f"env:{raw[1:]}", f"env {raw[1:]}"
        note = f"unresolved ({raw} not in env)"
    elif raw:
        return f"literal:{raw}", "literal"
    else:
        note = "no rpc in chain config"

    if chain_id in PUBLIC_FALLBACK_RPC:
        return f"literal:{PUBLIC_FALLBACK_RPC[chain_id]}", f"public fallback ({note})"
    return None, note


def _materialise_spec(spec: str) -> str | None:
    """Turn a `fork_rpc_spec` descriptor into the actual URL. Mirrored by rehearse_fork.sh."""
    kind, _, val = spec.partition(":")
    if kind == "env":
        return os.environ.get(val) or None
    if kind == "alchemy":
        key = os.environ.get("ALCHEMY_API_KEY")
        return f"https://{val}.g.alchemy.com/v2/{key}" if key else None
    if kind == "literal":
        return val or None
    return None


def fork_rpc(chain_id: int) -> tuple[str | None, str]:
    """The endpoint a LOCAL FORK of `chain_id` must be taken from. (url, note); url None = give up.

    Derived from `fork_rpc_spec` so there is exactly one place that decides, and so the URL — which
    embeds an API key — is only ever built by a caller that genuinely needs the value.
    """
    spec, note = fork_rpc_spec(chain_id)
    return (_materialise_spec(spec) if spec else None), note


class RpcError(RuntimeError):
    pass


def rpc_candidates(chain_id: int) -> list[tuple[str, str]]:
    """Every endpoint worth trying for a chain, best first, as [(url, note)]."""
    out: list[tuple[str, str]] = []
    primary, note = resolve_rpc(chain_id, allow_fallback=False, config_only=True)
    if primary:
        out.append((primary, note))
    envvar = CHAIN_URL_ENV.get(chain_id)
    if envvar and os.environ.get(envvar):
        out.append((os.environ[envvar], f"env {envvar}"))
    if chain_id in PUBLIC_FALLBACK_RPC:
        out.append((PUBLIC_FALLBACK_RPC[chain_id], "public fallback"))
    return out


def probe_rpc(chain_id: int) -> tuple[str | None, str, list[str]]:
    """Return the first endpoint that actually answers, plus why the earlier ones did not.

    A URL resolving is not the same as a URL working: the Alchemy app behind ALCHEMY_API_KEY has most
    networks disabled and answers `-32600 ... is not enabled for this app`, which only shows up on a
    real request. The preflight has to know the difference.
    """
    rejected: list[str] = []
    for url, note in rpc_candidates(chain_id):
        try:
            rpc(url, "eth_blockNumber", [], retries=1, timeout=20)
            return url, note, rejected
        except Exception as e:  # noqa: BLE001
            rejected.append(f"{note}: {str(e)[:160]}")
    return None, "no working endpoint", rejected


def rpc(url: str, method: str, params: list, retries: int = 4, timeout: int = 60):
    last = None
    for attempt in range(retries):
        try:
            r = requests.post(
                url,
                json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                timeout=timeout,
            )
            body = r.json()
            if "error" in body:
                raise RpcError(f"{method}: {body['error']}")
            return body["result"]
        except RpcError:
            raise
        except Exception as e:  # transport / json / rate limit
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise RpcError(f"{method} failed after {retries} attempts: {last}")


def eth_call(url: str, to: str, data: str, block: str = "latest") -> str:
    return rpc(url, "eth_call", [{"to": to, "data": data}, block])


def rpc_batch(url: str, calls: list[tuple[str, list]], chunk: int = 40,
              retries: int = 4, timeout: int = 120) -> list:
    """Batch JSON-RPC. `calls` is [(method, params)]; returns a same-length list whose entries are
    either the result or an RpcError instance (per-call errors do not fail the batch).

    Providers meter per *request*, not per call, so batching is what makes a 200-call snapshot
    finish in seconds rather than minutes when the endpoint is throttled.
    """
    out: list = [None] * len(calls)
    for base in range(0, len(calls), chunk):
        window = calls[base:base + chunk]
        payload = [{"jsonrpc": "2.0", "id": i, "method": m, "params": p}
                   for i, (m, p) in enumerate(window)]
        body = None
        last = None
        for attempt in range(retries):
            try:
                r = requests.post(url, json=payload, timeout=timeout)
                body = r.json()
                if not isinstance(body, list):
                    raise RuntimeError(f"non-batch response: {str(body)[:200]}")
                break
            except Exception as e:  # noqa: BLE001
                last = e
                body = None
                time.sleep(2.0 * (attempt + 1))
        if body is None:
            for i in range(len(window)):
                out[base + i] = RpcError(f"batch failed: {last}")
            continue
        by_id = {item.get("id"): item for item in body}
        for i, (m, _p) in enumerate(window):
            item = by_id.get(i)
            if item is None:
                out[base + i] = RpcError(f"{m}: missing from batch response")
            elif "error" in item:
                out[base + i] = RpcError(f"{m}: {item['error']}")
            else:
                out[base + i] = item["result"]
    return out


def eth_call_batch(url: str, targets: list[tuple[str, str]], block: str = "latest") -> list:
    """Batch of (to, data) eth_calls at a fixed block."""
    return rpc_batch(url, [("eth_call", [{"to": to, "data": data}, block])
                           for to, data in targets])


def get_code(url: str, addr: str, block: str = "latest") -> str:
    return rpc(url, "eth_getCode", [addr, block])


def block_number(url: str) -> int:
    return int(rpc(url, "eth_blockNumber", []), 16)


# ---------------------------------------------------------------------------
# Deployment-record enumeration
# ---------------------------------------------------------------------------

# Top-level string keys that hold a deployed address, mapped to the artifact contract name used to
# look up out/<File>.sol/<Name>.json. `NavRegistryLib` is the deliberate spelling exception (the
# CREATE2 salt seed string) — the contract is `NAVRegistryLib`.
CANONICAL_KEYS = {
    "PriceFeedLib": "PriceFeedLib",
    "NavRegistryLib": "NAVRegistryLib",
    "NAVCalculatorImplementation": "NAVCalculator",
    "BridgeEscrowImplementation": "BridgeEscrow",
    "NAVCalculatorProxy": "ERC1967Proxy",
    "BridgeEscrowProxy": "ERC1967Proxy",
    "NexusMutualStakingPoolsAssistant": "NexusMutualStakingPoolsAssistant",
    "EtherFiWithdrawalQueueAssistant": "EtherFiWithdrawalQueueAssistant",
    "StakeWiseV3ExitQueueAssistant": "StakeWiseV3ExitQueueAssistant",
}

NESTED_KEYS = ("balanceAdapters", "customPriceFeeds", "bridgeAdapters")


def is_address(v) -> bool:
    return isinstance(v, str) and v.startswith("0x") and len(v) == 42 and int(v, 16) != 0


def enumerate_deployed(chain_id: int) -> list[dict]:
    """Every address in deployments/<chainId>.json, as {chain, addr, key, group, name?}.

    Unlike `script/verify/sweeps/make_targets.py` — which only emits PriceFeedLib + the NAV impl
    plus feed instances read out of uncommitted broadcast logs — this walks the whole record, so
    the proxy, NAVRegistryLib, every balance adapter (incl. ERC20Default) and every assistant are
    covered. That completeness is the point: the audit has to be able to say "nothing was missed".
    """
    rec = deployment(chain_id)
    out: list[dict] = []
    for k, v in rec.items():
        if k in NESTED_KEYS:
            if not isinstance(v, dict):
                continue
            for sub, addr in v.items():
                if is_address(addr):
                    # `configName` is the operator-facing key ("wstETH_L2", "AaveV3InstancesMeta").
                    # It is deliberately NOT `name`: only the canonical top-level keys map to an
                    # artifact name, so only they carry a name expectation for the audit.
                    out.append(dict(chain=chain_id, addr=addr, key=f"{k}.{sub}", group=k,
                                    configName=sub, name=None))
            continue
        if is_address(v):
            out.append(dict(chain=chain_id, addr=v, key=k, group="canonical",
                            name=CANONICAL_KEYS.get(k)))
    return out


if __name__ == "__main__":
    # Tiny CLI so shell tooling resolves endpoints through THIS module rather than reimplementing
    # the rules.
    #
    # It prints the SPEC, never the URL. The URL embeds $ALCHEMY_API_KEY, and stdout is a channel
    # that ends up in logs and CI transcripts — CodeQL flags exactly that
    # (py/clear-text-logging-sensitive-data, high), and it is right to. The caller already holds the
    # key in its own environment, so naming the source leaks nothing while keeping every DECISION
    # (which override wins, which network, when to give up) in this module.
    #
    #   python3 chainlib.py fork-rpc <chainId>
    #     stdout: env:<VAR> | alchemy:<network> | literal:<url>
    #     stderr: human-readable note
    #     exit:   0 resolved, 2 bad usage, 3 nothing resolves
    import sys as _sys

    if len(_sys.argv) != 3 or _sys.argv[1] != "fork-rpc":
        print("usage: chainlib.py fork-rpc <chainId>", file=_sys.stderr)
        raise SystemExit(2)
    try:
        _cid = int(_sys.argv[2])
    except ValueError:
        print(f"chainId must be an integer, got {_sys.argv[2]!r}", file=_sys.stderr)
        raise SystemExit(2)
    load_env()
    _spec, _note = fork_rpc_spec(_cid)
    print(_note, file=_sys.stderr)
    if not _spec:
        raise SystemExit(3)
    print(_spec)
