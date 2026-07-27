"""Shared path/toolchain resolution for the verification sweeps.

Everything is derived from this file's location so the runners work from any checkout, with env
vars available as overrides:

  NAV_REPO_ROOT  repo root                      (default: four levels up from this file)
  SOLC_BIN       solc binary matching the pin   (default: ~/.svm/<ver>/solc-<ver>, else "solc")
  FOUNDRY_BIN    dir holding forge/cast         (default: ~/.foundry/bin if present)
"""
import os
import shutil

# <repo>/script/verify/sweeps/_paths.py -> <repo>
_DEFAULT_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))

SP = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("NAV_REPO_ROOT", _DEFAULT_ROOT)

# Keep in sync with foundry.toml's solc_version.
SOLC_VERSION = "0.8.34"
SOLC_COMMIT = "v0.8.34+commit.80d5c536"


def solc_bin() -> str:
    """solc matching the pin: $SOLC_BIN, else the svm-managed build, else whatever is on PATH."""
    override = os.environ.get("SOLC_BIN")
    if override:
        return override
    svm = os.path.expanduser(f"~/.svm/{SOLC_VERSION}/solc-{SOLC_VERSION}")
    if os.path.exists(svm):
        return svm
    found = shutil.which(f"solc-{SOLC_VERSION}") or shutil.which("solc")
    if not found:
        raise SystemExit(
            f"solc {SOLC_VERSION} not found — set SOLC_BIN, or install it with "
            f"`svm install {SOLC_VERSION}`"
        )
    return found


def forge_env(**extra) -> dict:
    """os.environ plus the foundry bin dir on PATH, and any extra vars."""
    path = os.environ.get("PATH", "")
    foundry = os.environ.get("FOUNDRY_BIN") or os.path.expanduser("~/.foundry/bin")
    if os.path.isdir(foundry) and foundry not in path.split(os.pathsep):
        path = foundry + os.pathsep + path
    return dict(os.environ, PATH=path, **extra)


def require_inputs(*names) -> None:
    """Fail with a pointer to the generator rather than a bare FileNotFoundError."""
    missing = [n for n in names if not os.path.exists(os.path.join(SP, n))]
    if missing:
        raise SystemExit(
            f"missing input(s): {', '.join(missing)} — generate them first with "
            f"`python3 {os.path.join(SP, 'make_targets.py')}`"
        )
