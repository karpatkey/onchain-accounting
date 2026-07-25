#!/usr/bin/env python3
"""Build a full-deploy-scope standard-JSON for PriceFeedLib (gotcha 9).

Under via_ir, a library's bytecode depends on the WHOLE compilation scope, so forge's trimmed
import closure compiles to different bytecode ("does NOT match"). Reproduce the deploy scope:
every src/** and script/** file as a root, transitive imports resolved via remappings, and
settings.libraries linking both libraries INCLUDING PriceFeedLib's self-link.
"""
import json
import os
import re
import subprocess
import sys

from _paths import REPO, SP, forge_env, solc_bin

os.chdir(REPO)
SOLC = solc_bin()

remaps = []
for line in subprocess.run(["forge", "remappings"], capture_output=True, text=True,
                           env=forge_env()).stdout.splitlines():
    if "=" in line:
        a, b = line.split("=", 1)
        remaps.append((a.strip(), b.strip()))
remaps.sort(key=lambda kv: -len(kv[0]))

IMPORT_RE = re.compile(r'import\s+(?:[^"\';]*?\s+from\s+)?["\']([^"\']+)["\']', re.M)


def resolve(spec, importer):
    if spec.startswith("."):
        p = os.path.normpath(os.path.join(os.path.dirname(importer), spec))
        return p if os.path.exists(p) else None
    for a, b in remaps:
        if spec.startswith(a):
            p = os.path.normpath(spec.replace(a, b, 1))
            if os.path.exists(p):
                return p
    return spec if os.path.exists(spec) else None


sources, seen = {}, set()


def add(path):
    if path in seen or not os.path.exists(path):
        return
    seen.add(path)
    content = open(path, encoding="utf8").read()
    sources[path] = {"content": content}
    for spec in IMPORT_RE.findall(content):
        r = resolve(spec, path)
        if r:
            add(r)
        else:
            print("  UNRESOLVED", spec, "from", path, file=sys.stderr)


roots = []
for base in ("src", "script"):
    for dirpath, _, files in os.walk(base):
        for f in files:
            if f.endswith(".sol"):
                roots.append(os.path.join(dirpath, f))
for r in sorted(roots):
    add(r)
print(f"roots={len(roots)} sources={len(sources)}")

tmpl = json.load(open(f"{SP}/std/PriceFeedLib.json"))
std = {"language": "Solidity", "sources": sources, "settings": tmpl["settings"]}
print("libraries:", json.dumps(std["settings"]["libraries"]))

with open(f"{SP}/std/PriceFeedLib_full.json", "w") as f:
    json.dump(std, f)


def check(path, label):
    size = os.path.getsize(path)
    with open(path) as f:
        r = subprocess.run([SOLC, "--standard-json"], stdin=f, capture_output=True, text=True)
    o = json.loads(r.stdout)
    errs = [e for e in o.get("errors", []) if e.get("severity") == "error"]
    art = json.load(open("out/PriceFeedLib.sol/PriceFeedLib.json"))["bytecode"]["object"].removeprefix("0x")
    try:
        rc = o["contracts"]["src/prices/PriceFeedLib.sol"]["PriceFeedLib"]["evm"]["bytecode"]["object"]
    except Exception:
        rc = ""
    print(f"{label}: {size} bytes, solc_errors={len(errs)}, MATCH={rc == art}")
    if errs:
        print("  first error:", errs[0]["message"][:200])
    return rc == art, size


ok, size = check(f"{SP}/std/PriceFeedLib_full.json", "full-scope")

# Etherscan hard limit: 3,000,000 chars of sourceCode -> whitespace-only reduction (bytecode-neutral)
if ok and size > 3_000_000:
    red = {"language": "Solidity",
           "sources": {p: {"content": "\n".join(l.lstrip() for l in v["content"].split("\n") if l.strip())}
                       for p, v in sources.items()},
           "settings": tmpl["settings"]}
    with open(f"{SP}/std/PriceFeedLib_reduced.json", "w") as f:
        json.dump(red, f, separators=(",", ":"))
    ok2, size2 = check(f"{SP}/std/PriceFeedLib_reduced.json", "reduced")
    print("under 3M:", size2 < 3_000_000)
