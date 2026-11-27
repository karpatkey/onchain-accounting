#!/usr/bin/env node
// Offline diff: FundConfig-derived Zodiac Roles leaves vs DeFi Kit (eth) permissions.
// Pure functions only (allow.*, processPermissions, reconstructPermissions). No planApply/postRole, no network.
// Usage: node docs/research/fund-infra/defikit-diff/diff.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as dk from "defi-kit/eth";
import { coercePermission, processPermissions, reconstructPermissions } from "zodiac-roles-sdk";

const here = dirname(fileURLToPath(import.meta.url));
const pkgVersion = (name) => JSON.parse(readFileSync(join(here, "node_modules", name, "package.json"), "utf8")).version;
const derivation = JSON.parse(readFileSync(join(here, "..", "derivation-example.json"), "utf8"));
const position = (index) => derivation.positions.find((p) => p.index === index);

// Enum names as used in derivation-example.json (ParameterType / Operator in zodiac-roles-deployments).
const PARAMS = { 0: "None", 1: "Static", 2: "Dynamic", 3: "Tuple", 4: "Array", 5: "Calldata", 6: "AbiEncoded" };
const OPS = {
  0: "PASS", 1: "AND", 2: "OR", 5: "MATCHES", 7: "ARRAY_EVERY", 15: "EQUAL_TO_AVATAR", 16: "EQUAL_TO",
  17: "GREATER_THAN", 18: "LESS_THAN", 19: "SIGNED_INT_GREATER_THAN", 20: "SIGNED_INT_LESS_THAN",
  21: "BITMASK", 22: "CUSTOM", 28: "WITHIN_ALLOWANCE", 29: "ETHER_WITHIN_ALLOWANCE", 30: "CALL_WITHIN_ALLOWANCE",
};
const OPTIONS = { 0: "None", 1: "Send", 2: "DelegateCall", 3: "Both" };

// Positions DeFi Kit (eth) has no allow.* entry for. Reported as fc_only, not forced to a match.
const NOT_COVERED = {
  3: "Uniswap V3 SwapRouter02 exactInputSingle: DeFi Kit only has cowswap.swap (different target)",
  5: "Curve 3pool: no curve key in defi-kit/eth",
  6: "Curve 3pool gauge + CRV minter: no curve key in defi-kit/eth",
  7: "EtherFi withdrawal assistant: no etherfi key in defi-kit/eth",
};

// ---- canonical tree helpers -------------------------------------------------
const norm = (v) => (!v || v === "0x" ? "0x" : v.toLowerCase());
const PASS = { o: "PASS", v: "0x", c: [] };
const nz = (n) => n ?? PASS;
const isPass = (n) => n.o === "PASS" && n.c.length === 0;
const json = (n) => JSON.stringify(n ?? null);
const label = (n) => (n.v === "0x" ? n.o : `${n.o} ${n.v}`);

// Drop trailing unconstrained children so "explicit Pass" and "omitted" compare equal.
const trim = (n) => {
  const c = n.c.map(trim);
  while (c.length && isPass(c.at(-1))) c.pop();
  return { ...n, c };
};
// A root MATCHES with no constraints is the same as no condition at all.
const finalize = (root) => {
  if (!root) return null;
  const t = trim(root);
  return t.o === "MATCHES" && t.c.length === 0 ? null : t;
};

function fcTree(conds) {
  if (!conds?.length) return null;
  const nodes = conds.map((c) => ({ p: c.paramType, o: c.operatorName, v: norm(c.compValue), c: [] }));
  conds.forEach((c, i) => {
    if (i > 0) nodes[c.parent].c.push(nodes[i]);
  });
  return finalize(nodes[0]);
}

const fromDk = (n) => ({
  p: PARAMS[n.paramType] ?? `PT_${n.paramType}`,
  o: OPS[n.operator] ?? `OP_${n.operator}`,
  v: norm(n.compValue),
  c: (n.children ?? []).map(fromDk),
});
const dkTree = (cond) => (cond ? finalize(fromDk(cond)) : null);

const caps = (o) => ({ send: o === "Send" || o === "Both", dc: o === "DelegateCall" || o === "Both" });
function optionsKind(fc, dk) {
  if (fc === dk) return null;
  const a = caps(fc);
  const b = caps(dk);
  const looser = (a.send && !b.send) || (a.dc && !b.dc);
  const stricter = (b.send && !a.send) || (b.dc && !a.dc);
  if (looser && stricter) return "different";
  if (looser) return "fc_looser";
  if (stricter) return "fc_stricter";
  return "different";
}

// Walk two canonical trees; emit one entry per differing node.
function diffNode(path, x0, y0, out = []) {
  const x = nz(x0);
  const y = nz(y0);
  if (json(x) === json(y)) return out;
  if (isPass(x)) out.push({ path, kind: "fc_looser", fc: label(x), dk: label(y) });
  else if (isPass(y)) out.push({ path, kind: "fc_stricter", fc: label(x), dk: label(y) });
  else if (x.o === y.o && x.p === y.p && x.v === y.v) {
    const n = Math.max(x.c.length, y.c.length);
    for (let i = 0; i < n; i++) diffNode(`${path}.${i}`, x.c[i], y.c[i], out);
  } else out.push({ path, kind: "different", fc: label(x), dk: label(y) });
  return out;
}

// Count non-Pass nodes that match between two trees at aligned positions. Used to pair leftovers.
function sharedConstraints(a0, b0) {
  const walk = (a, b) => {
    const x = nz(a);
    const y = nz(b);
    if (isPass(x)) return 0;
    let n = json(x) === json(y) ? 1 : 0;
    for (let i = 0; i < Math.max(x.c.length, y.c.length); i++) n += walk(x.c[i], y.c[i]);
    return n;
  };
  return walk(a0, b0);
}

// Combine per-difference kinds into one status.
function combine(kinds) {
  const s = new Set(kinds.filter(Boolean));
  if (!s.size) return "identical";
  if (s.has("different")) return "different";
  if (s.has("fc_looser") && s.has("fc_stricter")) return "mixed";
  return s.has("fc_looser") ? "fc_looser" : "fc_stricter";
}

// ---- DeFi Kit side ----------------------------------------------------------
const dkOptions = (t) => (t.send && t.delegatecall ? "Both" : t.send ? "Send" : t.delegatecall ? "DelegateCall" : "None");
const vaultAddress = "0x" + position(0).instance.slice(-40);
const AAVE_POOL = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";

const dkCalls = [
  { source: "morphoVaults.deposit", run: () => dk.allow.morphoVaults.deposit({ targets: [vaultAddress] }) },
  { source: "aave_v3.deposit", run: () => dk.allow.aave_v3.deposit({ market: AAVE_POOL, targets: ["WETH"] }) },
  { source: "aave_v3.borrow", run: () => dk.allow.aave_v3.borrow({ market: AAVE_POOL, targets: ["USDC"] }) },
  { source: "uniswap_v3.deposit", run: () => dk.allow.uniswap_v3.deposit({ tokens: ["USDC", "WETH"], fees: ["0.05%"] }) },
];

const sigBySelector = new Map();
const dkVariants = [];
for (const call of dkCalls) {
  const input = await call.run();
  for (const p of input) {
    if (p.signature) sigBySelector.set(coercePermission(p).selector.toLowerCase(), p.signature);
  }
  const { targets } = processPermissions(input);
  for (const t of reconstructPermissions(targets)) {
    dkVariants.push({
      source: call.source,
      target: t.targetAddress.toLowerCase(),
      selector: (t.selector ?? "*").toLowerCase(),
      options: dkOptions(t),
      tree: dkTree(t.condition),
    });
  }
}

// ---- FundConfig side --------------------------------------------------------
const fcVariants = [];
for (const p of derivation.positions) {
  for (const l of p.leaves) {
    fcVariants.push({
      position: p.index,
      targetLabel: l.targetLabel,
      target: l.target.toLowerCase(),
      selector: l.selector.toLowerCase(),
      signature: l.signature,
      options: l.options,
      tree: fcTree(l.conditions),
    });
  }
}

// ---- match -------------------------------------------------------------------
const groups = new Map();
const group = (k) => {
  if (!groups.has(k)) groups.set(k, { fc: [], dk: [] });
  return groups.get(k);
};
for (const v of fcVariants) group(`${v.target}|${v.selector}`).fc.push(v);
for (const v of dkVariants) group(`${v.target}|${v.selector}`).dk.push(v);

const records = [];
const fcRecord = (f, status, extra = {}) => ({
  side: "fc", position: f.position, targetLabel: f.targetLabel, target: f.target, selector: f.selector,
  signature: f.signature, fcOptions: f.options, status, ...extra,
});
const pairRecord = (f, d) => {
  const diffs = diffNode("root", f.tree, d.tree);
  const optKind = optionsKind(f.options, d.options);
  const status = combine([...diffs.map((x) => x.kind), optKind]);
  return fcRecord(f, status, {
    side: "both", dkSource: d.source, dkOptions: d.options, optionsStatus: optKind ?? "identical",
    paramDiffs: diffs,
  });
};

for (const [key, g] of groups) {
  const [target, selector] = key.split("|");
  const dkLeft = [...g.dk];
  const fcLeft = [];
  for (const f of g.fc) {
    const j = dkLeft.findIndex((d) => json(d.tree) === json(f.tree));
    if (j >= 0) records.push(pairRecord(f, dkLeft.splice(j, 1)[0]));
    else fcLeft.push(f);
  }
  for (const f of fcLeft) {
    let best = -1;
    let bestScore = 0;
    dkLeft.forEach((d, j) => {
      const s = sharedConstraints(f.tree, d.tree);
      if (s > bestScore) {
        best = j;
        bestScore = s;
      }
    });
    if (best >= 0) records.push(pairRecord(f, dkLeft.splice(best, 1)[0]));
    else records.push(fcRecord(f, "fc_only", { reason: NOT_COVERED[f.position] ?? "DeFi Kit has no matching function" }));
  }
  for (const d of dkLeft) {
    records.push({
      side: "dk", source: d.source, target, selector, signature: sigBySelector.get(selector) ?? null,
      dkOptions: d.options, status: "dk_only", tree: undefined,
      dkRootConstraints: d.tree ? d.tree.c.length : 0,
    });
  }
}

// ---- summary -----------------------------------------------------------------
const count = (arr, pick) => arr.reduce((acc, r) => {
  const k = pick(r);
  acc[k] = (acc[k] ?? 0) + 1;
  return acc;
}, {});
const byPosition = {};
for (const p of derivation.positions) {
  const rs = records.filter((r) => r.side !== "dk" && r.position === p.index);
  byPosition[p.index] = {
    kind: p.kind,
    instanceLabel: p.instanceLabel,
    fcVariants: rs.length,
    dkSources: [...new Set(rs.filter((r) => r.dkSource).map((r) => r.dkSource))],
    status: count(rs, (r) => r.status),
    notCovered: NOT_COVERED[p.index] ?? null,
  };
}
const summary = {
  fcVariants: fcVariants.length,
  dkVariants: dkVariants.length,
  status: count(records, (r) => r.status),
  optionsStatusOnMatched: count(records.filter((r) => r.side === "both"), (r) => r.optionsStatus),
  dkOnlyBySource: count(records.filter((r) => r.side === "dk"), (r) => r.source),
};

const out = {
  schema: "defikit-diff/v1",
  versions: { "defi-kit": pkgVersion("defi-kit"), "zodiac-roles-sdk": pkgVersion("zodiac-roles-sdk") },
  derivation: "docs/research/fund-infra/derivation-example.json",
  dkCalls: dkCalls.map((c) => c.source),
  summary,
  byPosition,
  records: records.map(({ tree, ...r }) => r),
};
writeFileSync(join(here, "defikit-diff.json"), JSON.stringify(out, null, 2) + "\n");

console.log(`FC variants ${summary.fcVariants}, DK variants ${summary.dkVariants}`);
console.log("status:", JSON.stringify(summary.status));
console.log("options on matched:", JSON.stringify(summary.optionsStatusOnMatched));
for (const [idx, s] of Object.entries(byPosition)) {
  console.log(`pos ${idx} ${s.kind} ${s.instanceLabel ?? ""}: ${JSON.stringify(s.status)}`);
}
console.log("dk-only by source:", JSON.stringify(summary.dkOnlyBySource));
console.log("wrote defikit-diff.json");
