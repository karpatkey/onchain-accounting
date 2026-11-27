// Builds docs/research/fund-infra/report/index.html from the measured gas JSON files next to it.
// Run: bun docs/research/fund-infra/report/build-report.ts
// Every number in the page comes from gas-profile.json / gas-complex-*.json; nothing is typed in by hand.
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const dir = join(import.meta.dir, "..");

// Every input is a JSON file this repo's tests or config write. Each is read through a guard that checks the
// top-level keys the report uses, so a renamed or missing field fails here with the file name, not mid-render.
function hasKeys<K extends string>(v: unknown, keys: readonly K[]): v is Record<K, unknown> {
  return !!v && typeof v === "object" && keys.every((k) => k in v);
}
function readJson<T>(rel: string, isT: (v: unknown) => v is T): T {
  const v: unknown = JSON.parse(readFileSync(join(dir, rel), "utf8"));
  if (!isT(v)) throw new Error(`${rel}: unexpected shape`);
  return v;
}

// Shape written by test/poc/fundconfig/FundConfigGas.fork.t.sol runs (docs/research/fund-infra/gas-profile.json).
type StepEntry = { total: number; children: Record<string, { calls: number; gas: number }>; fundconfig_residual: number };
type Phase = "before" | "after";
type GasProfile = {
  fork_block: number;
  toolchain: { forge: string; solc: string };
  per_step: Record<Phase, Record<string, StepEntry>>;
  scaling: { before: Record<string, number>; after: Record<string, number>; delta_before: Record<string, number>; delta_after: Record<string, number> };
  t6_gap_decomposition: Record<
    "gap_first_minus_second_AB" | "dedupe_allCooled_first_minus_second" | "warm_access_second_AB_minus_secondCooled" | "first_fund_cold_penalty_allCooled_minus_AB_first",
    Record<Phase, number>
  >;
};
const isGasProfile = (v: unknown): v is GasProfile => hasKeys(v, ["fork_block", "toolchain", "per_step", "scaling", "t6_gap_decomposition"]);
const profile = readJson("gas-profile.json", isGasProfile);

type Row = { type: string; step: string; gas: number };
const isRow = (r: unknown): r is Row =>
  !!r && typeof r === "object" && "type" in r && "step" in r && "gas" in r && typeof r.gas === "number";
const complex: { file: string; rows: Row[] }[] = readdirSync(dir)
  .filter((f) => /^gas-complex-.*\.json$/.test(f))
  .map((f) => {
    const raw: unknown = JSON.parse(readFileSync(join(dir, f), "utf8"));
    const list = Array.isArray(raw) ? raw : raw && typeof raw === "object" && "rows" in raw && Array.isArray(raw.rows) ? raw.rows : [];
    return { file: f, rows: list.filter(isRow) };
  });

const fmt = (n: number) => n.toLocaleString("en-US");
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

const SEGMENTS: [string, string][] = [
  ["registry.moduleOf", "#94a3b8"],
  ["module.validate", "#64748b"],
  ["module.permissions", "#f59e0b"],
  ["roles.scopeTarget", "#38bdf8"],
  ["roles.scopeFunction", "#2563eb"],
  ["fundconfig_residual", "#e11d48"],
];
const segLabel: Record<string, string> = {
  "registry.moduleOf": "registry lookup",
  "module.validate": "module.validate",
  "module.permissions": "module.permissions",
  "roles.scopeTarget": "Roles scopeTarget",
  "roles.scopeFunction": "Roles scopeFunction",
  fundconfig_residual: "FundConfig storage + overhead",
};

function stackedBars(): string {
  const rows: { label: string; entry: StepEntry }[] = [];
  for (const call of ["fundA.morpho", "fundA.aave", "fundB.morpho", "fundB.aave"])
    for (const phase of ["before", "after"] as const) rows.push({ label: `${call} · ${phase}`, entry: profile.per_step[phase][call] });
  const max = Math.max(...rows.map((r) => r.entry.total));
  const W = 900, left = 170, barH = 22, gap = 10, top = 10;
  const scale = (W - left - 90) / max;
  let y = top, out = "";
  for (const r of rows) {
    let x = left;
    out += `<text x="${left - 8}" y="${y + 15}" text-anchor="end" class="lbl">${esc(r.label)}</text>`;
    for (const [k, color] of SEGMENTS) {
      const g = k === "fundconfig_residual" ? r.entry.fundconfig_residual : (r.entry.children[k]?.gas ?? 0);
      const w = g * scale;
      out += `<rect x="${x}" y="${y}" width="${w}" height="${barH}" fill="${color}"><title>${segLabel[k]}: ${fmt(g)} gas</title></rect>`;
      x += w;
    }
    out += `<text x="${x + 6}" y="${y + 15}" class="val">${fmt(r.entry.total)}</text>`;
    y += barH + gap;
  }
  // Legend in two rows of three so the longest label never runs off the 900-wide canvas.
  const ly = y + 8;
  SEGMENTS.forEach(([k, c], i) => {
    const lx = left + (i % 3) * 230, row = ly + Math.floor(i / 3) * 20;
    out += `<rect x="${lx}" y="${row}" width="12" height="12" fill="${c}"/><text x="${lx + 16}" y="${row + 11}" class="lbl">${segLabel[k]}</text>`;
  });
  return `<svg viewBox="0 0 ${W} ${ly + 44}" role="img">${out}</svg>`;
}

function scalingChart(): string {
  const s = profile.scaling;
  const ns = Object.keys(s.before).map((k) => Number(k.slice(1)));
  const W = 900, H = 340, L = 80, B = 40, T = 30, R = 20;
  const max = Math.max(...Object.values<number>(s.before));
  const x = (n: number) => L + ((n - 1) / (ns.length - 1)) * (W - L - R);
  const y = (g: number) => T + (1 - g / max) * (H - T - B);
  let out = "";
  for (let i = 0; i <= 5; i++) {
    const g = (max / 5) * i;
    out += `<line x1="${L}" x2="${W - R}" y1="${y(g)}" y2="${y(g)}" class="grid"/><text x="${L - 8}" y="${y(g) + 4}" text-anchor="end" class="lbl">${(g / 1e6).toFixed(1)}M</text>`;
  }
  for (const n of ns) out += `<text x="${x(n)}" y="${H - B + 18}" text-anchor="middle" class="lbl">N=${n}</text>`;
  for (const [phase, color] of [["before", "#e11d48"], ["after", "#16a34a"]] as const) {
    const pts = ns.map((n) => `${x(n)},${y(s[phase][`N${n}`])}`).join(" ");
    out += `<polyline points="${pts}" fill="none" stroke="${color}" stroke-width="2.5"/>`;
    for (const n of ns) out += `<circle cx="${x(n)}" cy="${y(s[phase][`N${n}`])}" r="3.5" fill="${color}"><title>${phase} N=${n}: ${fmt(s[phase][`N${n}`])} gas</title></circle>`;
    const last = s[phase][`N${ns.at(-1)}`];
    out += `<text x="${x(ns.at(-1)!) - 6}" y="${y(last) - 8}" text-anchor="end" class="val" fill="${color}">${phase}: ${fmt(last)}</text>`;
  }
  return `<svg viewBox="0 0 ${W} ${H}" role="img">${out}</svg>`;
}

function gapWaterfall(): string {
  const d = profile.t6_gap_decomposition;
  const items: [string, number][] = [
    ["Roles condition-tree dedupe (all cold)", d.dedupe_allCooled_first_minus_second.after],
    ["Warm access on fund B (saves)", -d.warm_access_second_AB_minus_secondCooled.after],
    ["Cold-first penalty on fund A", -d.first_fund_cold_penalty_allCooled_minus_AB_first.after],
  ];
  const total = d.gap_first_minus_second_AB.after;
  const W = 900, L = 260, barH = 26, gap = 12;
  const max = Math.max(total, items[0][1] + Math.max(0, items[1][1])) * 1.15;
  const sx = (g: number) => L + (g / max) * (W - L - 120);
  let acc = 0, y = 10, out = "";
  for (const [label, v] of items) {
    const a = sx(Math.min(acc, acc + v)), b = sx(Math.max(acc, acc + v));
    out += `<text x="${L - 8}" y="${y + 17}" text-anchor="end" class="lbl">${esc(label)}</text><rect x="${a}" y="${y}" width="${b - a}" height="${barH}" fill="${v >= 0 ? "#2563eb" : "#f59e0b"}"/><text x="${b + 6}" y="${y + 17}" class="val">${v >= 0 ? "+" : "−"}${fmt(Math.abs(v))}</text>`;
    acc += v;
    y += barH + gap;
  }
  out += `<text x="${L - 8}" y="${y + 17}" text-anchor="end" class="lbl"><tspan font-weight="600">Fund B cheaper by</tspan></text><rect x="${sx(0)}" y="${y}" width="${sx(total) - sx(0)}" height="${barH}" fill="#16a34a"/><text x="${sx(total) + 6}" y="${y + 17}" class="val">${fmt(total)}</text>`;
  return `<svg viewBox="0 0 ${W} ${y + barH + 10}" role="img">${out}</svg>`;
}

function complexSection(): string {
  if (complex.length === 0) return `<p class="muted">No complex-position gas files yet.</p>`;
  return complex
    .map(({ file, rows }) => {
      const max = Math.max(...rows.map((r) => r.gas));
      const W = 900, L = 330, barH = 20, gap = 8;
      let y = 6, out = "";
      for (const r of rows) {
        const w = (r.gas / max) * (W - L - 100);
        out += `<text x="${L - 8}" y="${y + 14}" text-anchor="end" class="lbl">${esc(`${r.type} · ${r.step}`)}</text><rect x="${L}" y="${y}" width="${w}" height="${barH}" fill="#7c3aed"/><text x="${L + w + 6}" y="${y + 14}" class="val">${fmt(r.gas)}</text>`;
        y += barH + gap;
      }
      return `<h3><code>${esc(file)}</code></h3><svg viewBox="0 0 ${W} ${y + 4}" role="img">${out}</svg>`;
    })
    .join("\n");
}

// Grades: 2 strong, 1 partial, 0 weak, null n/a or unverified (architecture-comparison.json).
type Grade = 2 | 1 | 0 | null;
type Comparison = { systems: string[]; dimensions: { key: string; label: string; cells: [Grade, string][] }[] };
const comparison = readJson("architecture-comparison.json", (v): v is Comparison => hasKeys(v, ["systems", "dimensions"]));
const GRADE_STYLE: Record<string, { glyph: string; bg: string }> = {
  "2": { glyph: "●", bg: "#dcfce7" },
  "1": { glyph: "◐", bg: "#fef9c3" },
  "0": { glyph: "○", bg: "#fee2e2" },
  null: { glyph: "—", bg: "#f8fafc" },
};

function comparisonHtml(): string {
  const head = comparison.systems
    .map((s, i) => `<th class="sys${i < 2 ? " kpk" : ""}"><span>${esc(s)}</span></th>`)
    .join("");
  const body = comparison.dimensions
    .map((d) => {
      const cells = d.cells
        .map(([g, basis], i) => {
          const st = GRADE_STYLE[String(g)];
          return `<td class="g${i < 2 ? " kpk" : ""}" style="background:${st.bg}" title="${esc(basis)}">${st.glyph}</td>`;
        })
        .join("");
      return `<tr><th class="dim">${esc(d.label)}</th>${cells}</tr>`;
    })
    .join("");
  // Fixed layout takes widths from the first row, so the label column is sized via <colgroup>.
  return `<table class="matrix"><colgroup><col style="width:260px">${comparison.systems.map(() => "<col>").join("")}</colgroup><thead><tr><th></th>${head}</tr></thead><tbody>${body}</tbody></table>
<p class="muted">● strong · ◐ partial · ○ weak · — n/a or unverified. Hover a cell for its basis. Source: <code>architecture-comparison.json</code>.</p>`;
}

// The markdown doc embeds the same matrix between markers, so the JSON stays the single source of the grades.
function writeComparisonMarkdown(): void {
  const mdPath = join(dir, "architecture-comparison.md");
  const md = readFileSync(mdPath, "utf8");
  const header = `| Dimension | ${comparison.systems.join(" | ")} |\n|---|${comparison.systems.map(() => ":-:").join("|")}|`;
  const rows = comparison.dimensions
    .map((d) => `| ${d.label} | ${d.cells.map(([g]) => GRADE_STYLE[String(g)].glyph).join(" | ")} |`)
    .join("\n");
  const start = "<!-- matrix:start -->", end = "<!-- matrix:end -->";
  const i = md.indexOf(start), j = md.indexOf(end);
  if (i < 0 || j < i) throw new Error(`matrix markers missing in ${mdPath}`);
  writeFileSync(mdPath, `${md.slice(0, i + start.length)}\n${header}\n${rows}\n${md.slice(j)}`);
}

const standardHtml = `<div class="std">
  <div class="ok"><b>(a) Fund discovery</b><span>share token → metadata, NAV source</span><em>Partly covered: ERC-7575, ERC-8318 draft. Missing: share-token binding.</em></div>
  <div class="part"><b>(b) NAV-bound settlement</b><span>requests settle only against an authorized NAV, min-out</span><em>Gap: ERC-7540 has no min-out by design; ERC-8330 snapshots exist. Keep as kpk interface.</em></div>
  <div class="gap"><b>(c) Portfolio accounting</b><span>per-position assets, debt, protocol exposure</span><em>Uncovered by any ERC. kpk's PositionBalance + FundConfig supply it.</em></div>
</div>`;

// Worked example: one fund declaring every position type, dumped by test/poc/fundconfig/FundConfigDerivation.fork.t.sol.
type Cond = { parent: number; paramType: string; operatorName: string; compValue: string };
type Leaf = { target: string; targetLabel: string; signature: string; options: string; conditions: Cond[] };
type Bal = { symbol: string; amount: number | string; isDebt: boolean; value?: number | string };
type DerivedPosition = {
  kind: string; instance: string; instanceLabel: string; leaves: Leaf[];
  accounting: { adapter: string; isMeta: boolean; coordinate: string; assetFilter: string };
  balances: Bal[] | null;
};
type RolesKey = { targetLabel: string; signature: string; leafCount: number; roleCall: string; conditionMerge: string };
type Derivation = {
  meta: { forkBlock: number; positionCount: number; rolesKeyCount: number; leafCount: number };
  fund: { safe: string };
  positions: DerivedPosition[];
  rolesKeys: RolesKey[];
};
const derivation = readJson("derivation-example.json", (v): v is Derivation => hasKeys(v, ["meta", "fund", "positions", "rolesKeys"]));
// Adapter names come from the deployment registry, so the example shows which production adapter values each position.
const deployments = readJson("../../../script/config/deployments/1.json", (v): v is { balanceAdapters: Record<string, string> } =>
  hasKeys(v, ["balanceAdapters"]),
);
const adapterName = new Map(Object.entries(deployments.balanceAdapters).map(([name, addr]) => [addr.toLowerCase(), name]));
const addrLabel = new Map<string, string>([[derivation.fund.safe.toLowerCase(), "Safe"]]);
for (const p of derivation.positions) {
  if (/^0x0{24}/.test(p.instance)) addrLabel.set(`0x${p.instance.slice(26)}`.toLowerCase(), p.instanceLabel);
  for (const l of p.leaves) addrLabel.set(l.target.toLowerCase(), l.targetLabel);
}

// Renders one ConditionFlat tree (BFS, parent indices) as "argN = …" clauses, expanding tuples one level.
function describeConditions(conds: Cond[]): string {
  if (conds.length === 0) return "any arguments";
  const value = (c: Cond): string => {
    switch (c.operatorName) {
      case "PASS": return "any";
      case "EQUAL_TO_AVATAR": return "= Safe";
      case "CUSTOM": return `custom check (${addrLabel.get(`0x${c.compValue.slice(2, 42)}`.toLowerCase()) ?? "module"})`;
      case "EQUAL_TO": {
        const hex = c.compValue.slice(2);
        // Small values (fee tiers, rate modes) also have 24 leading zero nibbles; only wide values are addresses.
        if (hex.length === 64 && hex.startsWith("0".repeat(24)) && BigInt(`0x${hex}`) > 0xffffffffffffn) {
          const a = `0x${hex.slice(24)}`.toLowerCase();
          return `= ${addrLabel.get(a) ?? `${a.slice(0, 8)}…`}`;
        }
        return `= ${BigInt(`0x${hex || "0"}`).toString()}`;
      }
      default: return c.operatorName.toLowerCase();
    }
  };
  const childrenOf = (i: number) => conds.map((c, j) => [c, j] as const).filter(([c, j]) => j !== i && c.parent === i);
  return childrenOf(0)
    .map(([c, j], argIdx) =>
      c.paramType === "Tuple"
        ? `arg${argIdx} (${childrenOf(j).map(([cc], k) => `.${k} ${value(cc)}`).filter((s) => !s.endsWith(" any")).join(", ")})`
        : `arg${argIdx} ${value(c)}`,
    )
    .filter((s) => !s.endsWith(" any") && !s.endsWith("()"))
    .join(", ") || "any arguments";
}

function derivationHtml(): string {
  const rows = derivation.positions
    .map((p) => {
      const leaves = p.leaves
        .map((l) => `<li><code>${esc(l.signature.split("(")[0])}</code> on ${esc(l.targetLabel)}${l.options !== "Send" ? ` <span class="tag">${esc(l.options)}</span>` : ""}<br><span class="muted">${esc(describeConditions(l.conditions))}</span></li>`)
        .join("");
      const a = p.accounting;
      const name = adapterName.get(a.adapter.toLowerCase()) ?? "POC-only adapter (not deployed)";
      const legs = (p.balances ?? []).map((b) => `${b.isDebt ? "−" : "+"}${esc(b.symbol)}`).join(" ") || "no balance at dump time";
      return `<tr><td><b>${esc(p.kind)}</b><br><span class="muted">${esc(p.instanceLabel)}</span></td><td><ul class="leaves">${leaves}</ul></td><td>${esc(name)}${a.isMeta ? " <span class=\"tag\">meta, this instance only</span>" : ""}<br><span class="muted">legs: ${legs}</span></td></tr>`;
    })
    .join("");
  const merged = derivation.rolesKeys
    .filter((k) => k.leafCount > 1)
    .map((k) => `<li><code>${esc(k.signature.split("(")[0])}</code> on ${esc(k.targetLabel)}: ${k.leafCount} positions → one <code>${esc(k.roleCall)}</code> with an <b>${esc(k.conditionMerge.toUpperCase())}</b> of their conditions</li>`)
    .join("");
  const m = derivation.meta;
  return `<p>One fund declares ${m.positionCount} positions. FundConfig derives ${m.leafCount} permission leaves, writes them as ${m.rolesKeyCount} Roles entries, and values the same ${m.positionCount} positions. Everything below is dumped from the fork test at block ${fmt(m.forkBlock)}; condition text is rendered from the stored condition trees.</p>
<table class="deriv"><thead><tr><th>Declared position</th><th>→ Permissions written to Roles</th><th>→ Accounting route</th></tr></thead><tbody>${rows}</tbody></table>
<h3>Shared functions merged</h3><ul>${merged}</ul>`;
}

// What the fork tests prove about the derivation (test names in fundconfig-poc.md and the complex-positions docs).
const invariantsHtml = `<table>
<thead><tr><th>Invariant</th><th>Why it holds</th><th>Proven by</th></tr></thead><tbody>
<tr><td>Every Roles permission traces to a declared position</td><td>FundConfig owns the Roles proxy and has no raw-permission entrypoint</td><td>T7 (owner = FundConfig; owner calls from curator or raw <code>call</code> fail)</td></tr>
<tr><td>Every declared position is valued</td><td>The same module returns the leaves and the adapter route; <code>fundNav</code> walks the declared list</td><td>T1 (NAV tracks Morpho + Aave deposits within 0.1%), borrow (debt negative), Curve (both legs)</td></tr>
<tr><td>Undeclared calls are refused</td><td>Leaves pin targets, assets and recipient = Safe (<code>EqualToAvatar</code>)</td><td>T2; swap into undeclared token; LP NFT from another pool; borrow on behalf of a third party</td></tr>
<tr><td>Shared functions merge, and unmerge cleanly</td><td>Leaves on the same (target, selector) become one Or-tree; removal drops only that branch</td><td>T3 (<code>approve(USDC)</code> for Aave pool + Morpho vault)</td></tr>
<tr><td>Accounting cannot be dropped while value remains</td><td><code>removePosition</code> reverts while the position's adapter reports a balance</td><td>T4; borrow with open debt</td></tr>
<tr><td>Assisted positions reachable only through their assistant</td><td>Module permits only <code>DelegateCall</code> to the assistant</td><td>T5 (direct EtherFi LiquidityPool call reverts)</td></tr>
</tbody></table>
<p class="muted">Outside FundConfig: the Safe's owners can still enable another module, set a guard, or remove Roles.</p>`;

// Known limits per type, from the complex-positions docs; the derived permissions and routes themselves come from derivationHtml().
const gapsHtml = `<ul>
<li><b>aave-v3-borrow:</b> no LTV / health-factor bound in Roles; the removal guard is per asset, so a co-declared supply of the same asset blocks removing the borrow.</li>
<li><b>uniswap-v3-swap:</b> single-hop only; slippage bound is only the caller's <code>amountOutMinimum</code>.</li>
<li><b>curve pool + gauge:</b> two declared positions because accounting is one route per position; legacy Curve pools report no wallet LP through <code>CurvePoolsMeta</code> (latent, in <code>src/</code>).</li>
</ul>`;

// NAV read cost and the subscription verdict, from test/poc/fundconfig/FundConfigNavGas.fork.t.sol (gas-nav-read.json).
type NavGas = {
  cap: { eip7825TxGasLimit: number };
  today: { prodGetAccountNav: Record<string, { cold: number; warm: number }> };
  perType: Record<string, { cold: number; warm: number }>;
  fit: Record<"cold" | "warm", { aGas: number; bGasPerPosition: number; maxNUnderCap: number }>;
  subscription: Record<"sync" | "async" | "oracle", { feasible: boolean; optimal?: boolean; why: string[] }>;
};
// Behavioural validation of the derived permissions (FundConfigPermissionValidation.fork.t.sol).
type Validation = { suites: { suite: string; total: number; failures: number; statuses: Record<string, number> }[] };
const validation = readJson("permission-validation.json", (v): v is Validation => hasKeys(v, ["suites"]));
const SUITE_LABEL: Record<string, string> = {
  positive: "A call satisfying each derived leaf passes Roles",
  words: "Each constrained argument, mutated alone, is rejected",
  options: "Wrong execution option (delegatecall, ETH value) is rejected where not derived",
  undeclared: "Undeclared selector on a declared target / undeclared target is rejected",
  removal: "After removing a position, only its unshared leaves stop passing",
};

function validationHtml(): string {
  const rows = validation.suites
    .map((s) => `<tr><td>${esc(SUITE_LABEL[s.suite] ?? s.suite)}</td><td class="n">${s.total}</td><td class="n">${s.failures}</td><td>${Object.entries(s.statuses).map(([k, v]) => `${esc(k)} ${v}`).join(", ")}</td></tr>`)
    .join("");
  const total = validation.suites.reduce((a, s) => a + s.total, 0);
  const failures = validation.suites.reduce((a, s) => a + s.failures, 0);
  return `<p>Against the live Roles v2 mastercopy on a mainnet fork, generic over every leaf of the worked example: <b>${total} checks, ${failures} mismatches</b>. This checks that Roles enforces what FundConfig derived; the DeFi Kit diff checks the derivation against today's production permissions.</p>
<table><thead><tr><th>Check</th><th>Cases</th><th>Mismatches</th><th>Roles outcomes</th></tr></thead><tbody>${rows}</tbody></table>
<h3>Against DeFi Kit (today's production permissions)</h3>
<ul>
<li>12 overlapping functions derive identical condition trees (approve, Morpho deposit/redeem/withdraw, Aave supply/withdraw/borrow/repay).</li>
<li>Uniswap V3 LP is stricter in FundConfig: the tokenId is bound to a Safe-owned NFT of the declared pool by the module's custom check.</li>
<li>Looser in FundConfig: every non-assistant leaf allows sending ETH (<code>Send</code>); DeFi Kit grants <code>None</code>. To fix in the modules.</li>
<li>Missing in the POC modules: Aave <code>setUserUseReserveAsCollateral</code> and <code>claimRewards</code>. No DeFi Kit recipe exists for the swap, Curve and EtherFi positions.</li>
</ul>`;
}

const operatingHtml = `<table>
<thead><tr><th>Actor</th><th>Controls</th><th>Cannot</th></tr></thead><tbody>
<tr><td>Security Council</td><td>Admits position modules (write-once registry); registers assets and price feeds; upgrades NAVCalculator</td><td>Change a registered module; touch a fund's positions</td></tr>
<tr><td>Fund curator</td><td><code>addPosition</code>, <code>removePosition</code>, <code>assignManager</code></td><td>Write a permission no registered module derives; remove a position that holds value</td></tr>
<tr><td>Fund Safe owners</td><td>Enable/disable modules, guards</td><td>— (outside FundConfig's guarantee)</td></tr>
<tr><td>Manager / bot</td><td>Execute derived calls only</td><td>Anything else</td></tr>
</tbody></table>
<ul>
<li><b>New position of an existing type:</b> one curator tx; its assets must be priced in NAVCalculator.</li>
<li><b>New position type:</b> module (+ adapter) reviewed, then registered by the Security Council.</li>
<li><b>Dynamic positions:</b> runtime ids (LP NFTs, withdrawal tickets) need no re-declaration; new markets or vaults do.</li>
<li><b>Upgrades:</b> modules, adapters and FundConfig are immutable. A module fix is a new module id plus a per-fund swap, which needs a <code>replacePosition</code> the POC lacks; a bad module needs a deprecate + revoke path the POC lacks.</li>
</ul>
<p class="muted">Full detail: <code>operating-model.md</code>.</p>`;

const navGas = readJson("gas-nav-read.json", (v): v is NavGas => hasKeys(v, ["cap", "today", "perType", "fit", "subscription"]));
const CAP = navGas.cap.eip7825TxGasLimit;

function navReadHtml(): string {
  const rows: [string, number][] = [
    ...Object.entries(navGas.today.prodGetAccountNav).map(([k, v]) => [`getAccountNav, production ${k} (today)`, v.cold] as [string, number]),
    ["fundNav, 1 funded Aave V3 position", navGas.perType.aaveFundedUsdc.cold],
    ["fundNav, 1 funded Morpho vault", navGas.perType.morphoFundedN1.cold],
    [`fundNav, ${navGas.fit.cold.maxNUnderCap} zero-balance Morpho positions (fit)`, navGas.fit.cold.aGas + navGas.fit.cold.bGasPerPosition * navGas.fit.cold.maxNUnderCap],
  ];
  const max = Math.max(CAP, ...rows.map(([, g]) => g)) * 1.05;
  const W = 900, L = 330, barH = 22, gap = 10;
  const sx = (g: number) => L + (g / max) * (W - L - 90);
  let y = 8, out = "";
  for (const [label, g] of rows) {
    const over = g > CAP;
    out += `<text x="${L - 8}" y="${y + 15}" text-anchor="end" class="lbl">${esc(label)}</text><rect x="${L}" y="${y}" width="${sx(g) - L}" height="${barH}" fill="${over ? "#e11d48" : "#2563eb"}"/><text x="${sx(g) + 6}" y="${y + 15}" class="val">${fmt(g)}</text>`;
    y += barH + gap;
  }
  out += `<line x1="${sx(CAP)}" x2="${sx(CAP)}" y1="0" y2="${y}" stroke="#0f172a" stroke-dasharray="4 3"/><text x="${sx(CAP) - 4}" y="${y + 14}" text-anchor="end" class="lbl">EIP-7825 per-tx cap ${fmt(CAP)}</text>`;
  const s = navGas.subscription;
  const opt = (title: string, o: { feasible: boolean; optimal?: boolean; why: string[] }, cls: string) =>
    `<div class="${cls}"><b>${title}</b><span>${o.feasible ? "feasible" : "not feasible"}${o.optimal === false ? " · not optimal" : ""}</span><em>${o.why.map(esc).join(" ")}</em></div>`;
  return `<p>Cold reads (first touch in the tx), mainnet fork. Red bars do not fit in one transaction.</p>
<svg viewBox="0 0 ${W} ${y + 22}" role="img">${out}</svg>
<div class="std">${opt("1. Sync: NAV inside each subscription", s.sync, "part")}${opt("2. Async batch: NAV once per settlement", s.async, "part")}${opt("3. Oracle: pushed NAV snapshot", s.oracle, "ok")}</div>
<p class="muted">fundNav cost per position depends heavily on type (funded Aave ≈ ${fmt(navGas.perType.aaveFundedUsdc.cold)} vs Morpho ≈ ${fmt(navGas.fit.cold.bGasPerPosition)} marginal); the POC's fundNav prices each leg separately and is not optimized, so these are upper bounds for the scoped design.</p>
<h3>Ideas to fit more positions</h3>
<ul>
<li><b>Batch the price calls:</b> sum every leg and wallet balance per asset, then make one <code>calculateValue</code> call for credits and one for debts, instead of one per leg. Price reads scale with distinct assets, not legs.</li>
<li>Resolve each position's module once per <code>fundNav</code> call; dedupe wallet tokens in linear time.</li>
<li>Gas-stipend each adapter and fail open with a health flag, as <code>NAVCalculator</code> does, so one bad position cannot block a subscription.</li>
</ul>
<p class="muted">Not implemented or measured yet; details in <code>fundconfig-poc.md</code> § Ideas to improve.</p>`;
}

const architecture = `<svg viewBox="0 0 940 330" role="img" class="arch">
  <defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#475569"/></marker></defs>
  <text x="20" y="22" class="h">Shared (immutable)</text>
  <rect x="20" y="34" width="250" height="56" rx="8" class="box"/><text x="145" y="58" text-anchor="middle" class="t">ModuleRegistry</text><text x="145" y="76" text-anchor="middle" class="s">security-council gated, write-once</text>
  <rect x="20" y="106" width="250" height="74" rx="8" class="box"/><text x="145" y="130" text-anchor="middle" class="t">Position modules</text><text x="145" y="148" text-anchor="middle" class="s">permissions(instance) → leaves</text><text x="145" y="166" text-anchor="middle" class="s">accounting(instance) → adapter</text>
  <rect x="20" y="196" width="250" height="56" rx="8" class="box"/><text x="145" y="220" text-anchor="middle" class="t">Balance adapters + NAVCalculator</text><text x="145" y="238" text-anchor="middle" class="s">this repo, unchanged</text>
  <text x="340" y="22" class="h">Per fund</text>
  <rect x="340" y="80" width="230" height="110" rx="8" class="box hl"/><text x="455" y="106" text-anchor="middle" class="t">FundConfig</text><text x="455" y="126" text-anchor="middle" class="s">declared (module, instance)[]</text><text x="455" y="144" text-anchor="middle" class="s">owner of Roles, no passthrough</text><text x="455" y="162" text-anchor="middle" class="s">merge leaves → Or-trees</text><text x="455" y="180" text-anchor="middle" class="s">fundNav(quote)</text>
  <rect x="650" y="40" width="230" height="64" rx="8" class="box"/><text x="765" y="66" text-anchor="middle" class="t">Zodiac Roles v2 clone</text><text x="765" y="86" text-anchor="middle" class="s">scopeFunction / scopeTarget</text>
  <rect x="650" y="160" width="230" height="64" rx="8" class="box"/><text x="765" y="186" text-anchor="middle" class="t">Fund Safe (avatar)</text><text x="765" y="206" text-anchor="middle" class="s">holds every position</text>
  <rect x="650" y="262" width="230" height="52" rx="8" class="box"/><text x="765" y="293" text-anchor="middle" class="t">Manager / bot</text>
  <line x1="270" y1="62" x2="340" y2="110" class="ar"/><line x1="270" y1="143" x2="340" y2="135" class="ar"/>
  <line x1="340" y1="170" x2="270" y2="222" class="ar"/><text x="300" y="214" class="s">values</text>
  <line x1="570" y1="110" x2="650" y2="76" class="ar"/><text x="578" y="70" class="s">derived perms</text>
  <line x1="765" y1="104" x2="765" y2="160" class="ar"/><text x="772" y="138" class="s">module</text>
  <path d="M880,288 H905 V72 H884" fill="none" class="ar"/><text x="918" y="180" class="s" transform="rotate(-90 918 180)" text-anchor="middle">execTransactionWithRole</text>
</svg>`;

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>FundConfig POC report</title>
<style>
  body{font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#0f172a;max-width:960px;margin:32px auto;padding:0 24px;background:#fff}
  h1{font-size:26px;margin:0 0 4px} h2{font-size:19px;margin:36px 0 8px;border-bottom:1px solid #e2e8f0;padding-bottom:4px} h3{font-size:15px;margin:18px 0 6px}
  .muted{color:#64748b} code{background:#f1f5f9;padding:1px 4px;border-radius:4px;font-size:13px}
  table{border-collapse:collapse;width:100%;font-size:14px} th,td{border:1px solid #e2e8f0;padding:6px 8px;text-align:left} th{background:#f8fafc} td.n{text-align:right;font-variant-numeric:tabular-nums}
  svg{width:100%;height:auto} .lbl{font-size:12px;fill:#334155} .val{font-size:12px;fill:#0f172a;font-variant-numeric:tabular-nums} .grid{stroke:#e2e8f0}
  .arch .box{fill:#f8fafc;stroke:#94a3b8} .arch .hl{fill:#eff6ff;stroke:#2563eb;stroke-width:2} .arch .t{font-size:14px;font-weight:600;fill:#0f172a} .arch .s{font-size:12px;fill:#475569} .arch .h{font-size:13px;font-weight:600;fill:#64748b;text-transform:uppercase} .arch .ar{stroke:#475569;stroke-width:1.5;marker-end:url(#ah)}
  .kpi{display:flex;gap:16px;margin:16px 0} .kpi div{flex:1;border:1px solid #e2e8f0;border-radius:8px;padding:12px} .kpi b{display:block;font-size:22px}
  .matrix{font-size:13px;table-layout:fixed} .matrix th.dim{width:220px;font-weight:500;background:#fff} .matrix th.sys{height:120px;vertical-align:bottom;padding:4px 0;background:#fff} .matrix th.sys span{display:block;writing-mode:vertical-rl;transform:rotate(180deg);margin:0 auto;white-space:nowrap} .matrix th.kpk span{font-weight:700;color:#1d4ed8} .matrix td.g{text-align:center;font-size:16px;padding:4px 0} .matrix td.kpk{outline:2px solid #2563eb;outline-offset:-2px}
  .std{display:flex;gap:12px;margin:12px 0} .std div{flex:1;border-radius:8px;padding:12px;border:1px solid #e2e8f0} .std b{display:block} .std span{display:block;color:#475569;font-size:13px;margin:4px 0} .std em{font-size:13px;font-style:normal} .std .ok{background:#fef9c3} .std .part{background:#fef9c3} .std .gap{background:#dcfce7;border-color:#16a34a}
  .deriv{font-size:13px} .deriv td{vertical-align:top} .deriv td:first-child{width:170px} .deriv td:last-child{width:230px} .leaves{margin:0;padding-left:16px} .leaves li{margin:2px 0} .tag{font-size:11px;background:#e0e7ff;color:#3730a3;border-radius:4px;padding:0 4px}
</style></head><body>
<h1>FundConfig: one declaration, derived permissions and accounting</h1>
<p class="muted">A fund declares its positions once. Each declared <code>(module, instance)</code> yields both the Zodiac Roles v2 leaves the manager may call and the balance-adapter route that values it. Mainnet fork at block ${fmt(profile.fork_block)}.</p>
<h2>How the derivation works</h2>
${architecture}
${invariantsHtml}
<h2>Worked example: one fund, every position type</h2>
${derivationHtml()}
<h3>Known gaps per type</h3>
${gapsHtml}
<h2>Validation of the derived permissions</h2>
${validationHtml()}
<h2>Operating model</h2>
${operatingHtml}
<h2>Can the NAV be read on subscription?</h2>
${navReadHtml()}
<h2>Compared with NAV-based funds</h2>
${comparisonHtml()}
<h2>Standard proposal: NAV-linked tokenized funds</h2>
<p class="muted">Three interfaces on the fund's share token, against existing ERCs (detail: <code>architecture-comparison.md</code>, <code>erc-landscape.md</code>). Green = where no ERC exists and kpk already has the substance.</p>
${standardHtml}
<h2>Appendix: cost of deriving on-chain</h2>
<div class="kpi">
  <div><span class="muted">Fund A, 2 positions</span><b>${fmt(profile.per_step.after["fundA.morpho"].total + profile.per_step.after["fundA.aave"].total)}</b><span class="muted">was ${fmt(profile.per_step.before["fundA.morpho"].total + profile.per_step.before["fundA.aave"].total)} gas</span></div>
  <div><span class="muted">Marginal position (N≥3)</span><b>~${fmt(Math.round(profile.scaling.delta_after.N7_to_N8 / 1000))}k</b><span class="muted">was ~${fmt(Math.round(profile.scaling.delta_before.N7_to_N8 / 1000))}k gas</span></div>
  <div><span class="muted">Second identical fund saves</span><b>${fmt(profile.t6_gap_decomposition.gap_first_minus_second_AB.after)}</b><span class="muted">mostly Roles condition-tree reuse</span></div>
</div>
<h3>addPosition gas per step (before → after)</h3>
${stackedBars()}
<h3>Scaling: Nth position sharing one approve key</h3>
${scalingChart()}
<h3>Why the second fund is cheaper</h3>
${gapWaterfall()}
<h3>Manager calls and setup per complex type</h3>
${complexSection()}
</body></html>
`;

const outPath = join(import.meta.dir, "index.html");
writeFileSync(outPath, html);
writeComparisonMarkdown();
console.log(`wrote ${outPath} and the architecture-comparison.md matrix`);
