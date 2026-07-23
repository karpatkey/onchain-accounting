#!/usr/bin/env bun
// NAV historical backtest driver (single-file, no dependencies — run with bun).
// Usage: bun script/test/nav-backtest.ts [--chain 1] [--window w1-1d] [--mode report|snapshot|assert]
//   report   (default) run sweep, print summary, do not touch the fixture
//   snapshot run sweep and (over)write the window's entry in test/integration/nav-timeseries.json
//   assert   run sweep and deep-diff against the fixture's window entry; exit 1 on any difference
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const BLOCKS_JSON = `${ROOT}/test/integration/backtest-blocks.json`;
const FIXTURE = `${ROOT}/test/integration/nav-timeseries.json`;

// ── Types ──

interface WindowDef { fromBlock: number; toBlock: number; blockStep: number; metrics: string[]; accounts?: string[] }
interface BlocksFile { windows: Record<string, { chains: Record<string, WindowDef> }> }
interface Point { block: number; timestamp: number; value?: string; error?: string }
type Series = Record<string, Record<string, Point[]>>;
interface FixtureWindowEntry { generatedAtCommit: string; accounts: Series }
interface Fixture { $comment: string; windows: Record<string, { chains: Record<string, FixtureWindowEntry> }> }
type Mode = "report" | "snapshot" | "assert";

// ── Helpers ──

function fail(msg: string, code: 1 | 2): never { console.error(msg); process.exit(code); }
function isRecord(v: unknown): v is Record<string, unknown> { return typeof v === "object" && v !== null && !Array.isArray(v); }
function isStringArray(v: unknown): v is string[] { return Array.isArray(v) && v.every((x) => typeof x === "string"); }
function isFiniteNonNeg(v: unknown): v is number { return typeof v === "number" && Number.isFinite(v) && v >= 0 && Number.isSafeInteger(v); }
function isPoint(v: unknown): v is Point {
  if (!isRecord(v)) return false;
  const { block, timestamp, value, error } = v;
  if (!isFiniteNonNeg(block) || !isFiniteNonNeg(timestamp)) return false;
  const hv = typeof value === "string", he = typeof error === "string";
  return hv !== he;
}
function isPointArray(v: unknown): v is Point[] { return Array.isArray(v) && v.every(isPoint); }
const HEX40 = /^0x[0-9a-fA-F]{40}$/;
function isHexAddress(v: unknown): v is string { return typeof v === "string" && HEX40.test(v); }

// ── Boundary parsers (no `as`, no `any`, no non-null) ──

function parseWindowDef(raw: unknown): WindowDef {
  if (!isRecord(raw)) fail("window def must be an object", 2);
  const { fromBlock, toBlock, blockStep } = raw;
  if (!isFiniteNonNeg(fromBlock)) fail("fromBlock must be a finite non-negative integer", 2);
  if (!isFiniteNonNeg(toBlock)) fail("toBlock must be a finite non-negative integer", 2);
  if (!isFiniteNonNeg(blockStep) || blockStep === 0) fail("blockStep must be a positive integer", 2);
  if (toBlock <= fromBlock) fail("toBlock must be > fromBlock", 2);
  const mr = raw.metrics;
  const metrics: string[] = mr !== undefined
    ? (isStringArray(mr) && mr.length > 0 ? mr : fail("metrics must be a non-empty string array", 2))
    : ["nav"];
  const ar = raw.accounts;
  let accounts: string[] | undefined;
  if (ar !== undefined) {
    if (!isStringArray(ar) || ar.length === 0) fail("accounts must be a non-empty string array", 2);
    const seen = new Set<string>();
    for (const a of ar) {
      if (!isHexAddress(a)) fail(`invalid account address: ${a}`, 2);
      const lo = a.toLowerCase();
      if (seen.has(lo)) fail(`duplicate account: ${a}`, 2);
      seen.add(lo);
    }
    accounts = ar;
  }
  return { fromBlock, toBlock, blockStep, metrics, accounts };
}

function parseBlocksFile(raw: unknown): BlocksFile {
  if (!isRecord(raw) || !isRecord(raw.windows)) fail(`invalid structure in ${BLOCKS_JSON}`, 2);
  const windows: BlocksFile["windows"] = {};
  for (const [name, wc] of Object.entries(raw.windows)) {
    if (!isRecord(wc) || !isRecord(wc.chains)) fail(`window ${name}: chains must be an object`, 2);
    const chains: Record<string, WindowDef> = {};
    for (const [cid, def] of Object.entries(wc.chains)) chains[cid] = parseWindowDef(def);
    windows[name] = { chains };
  }
  return { windows };
}

function parseFixture(raw: unknown): Fixture {
  if (!isRecord(raw) || !isRecord(raw.windows)) fail(`invalid fixture structure in ${FIXTURE}`, 2);
  const windows: Fixture["windows"] = {};
  for (const [name, wc] of Object.entries(raw.windows)) {
    if (!isRecord(wc) || !isRecord(wc.chains)) fail(`fixture window ${name}: chains must be an object`, 2);
    const chains: Record<string, FixtureWindowEntry> = {};
    for (const [cid, entry] of Object.entries(wc.chains)) {
      if (!isRecord(entry)) fail(`fixture window ${name}/${cid}: must be an object`, 2);
      const gac = entry.generatedAtCommit;
      if (typeof gac !== "string") fail(`fixture window ${name}/${cid}: generatedAtCommit must be a string`, 2);
      if (!isRecord(entry.accounts)) fail(`fixture window ${name}/${cid}: accounts must be an object`, 2);
      const accounts: Series = {};
      for (const [account, metricsRaw] of Object.entries(entry.accounts)) {
        if (!isRecord(metricsRaw)) fail(`fixture ${name}/${cid}/${account}: must be an object`, 2);
        const metrics: Record<string, Point[]> = {};
        for (const [metric, pointsRaw] of Object.entries(metricsRaw)) {
          if (!isPointArray(pointsRaw)) fail(`fixture ${name}/${cid}/${account}/${metric}: must be a Point[]`, 2);
          metrics[metric] = pointsRaw;
        }
        accounts[account] = metrics;
      }
      chains[cid] = { generatedAtCommit: gac, accounts };
    }
    windows[name] = { chains };
  }
  return { $comment: typeof raw.$comment === "string" ? raw.$comment : "", windows };
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (isRecord(v)) {
    const s: Record<string, unknown> = {};
    for (const k of Object.keys(v).sort((a, b) => a.localeCompare(b))) s[k] = sortKeys(v[k]);
    return s;
  }
  return v;
}

function diffSeries(pinned: Series, current: Series): void {
  let shown = 0;
  for (const account of new Set([...Object.keys(pinned), ...Object.keys(current)])) {
    const pm = pinned[account] ?? {}, cm = current[account] ?? {};
    for (const metric of new Set([...Object.keys(pm), ...Object.keys(cm)])) {
      const p = pm[metric] ?? [], c = cm[metric] ?? [];
      for (let i = 0; i < Math.max(p.length, c.length) && shown < 30; i++) {
        const pi = i < p.length ? p[i] : undefined, ci = i < c.length ? c[i] : undefined;
        if (JSON.stringify(pi) !== JSON.stringify(ci)) {
          console.error(`  ${account}/${metric} block ${ci?.block ?? pi?.block ?? 0}: pinned=${JSON.stringify(pi)} got=${JSON.stringify(ci)}`);
          shown++;
        }
      }
    }
  }
}

// ── Concurrent subprocess drain ──

async function drainProc(proc: { stdout: ReadableStream<Uint8Array>; stderr: ReadableStream<Uint8Array>; exited: Promise<number> }) {
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  return { out, err, exitCode: await proc.exited };
}

async function gitShortHash(): Promise<string> {
  const p = Bun.spawn(["git", "rev-parse", "--short", "HEAD"], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  const { out, err, exitCode } = await drainProc(p);
  if (exitCode !== 0) fail(`git rev-parse failed (exit ${exitCode}): ${err}`, 2);
  const h = out.trim();
  if (h.length === 0) fail("git rev-parse returned empty hash", 2);
  return h;
}

// ── Mode guard ──

function isMode(v: string): v is Mode { return v === "report" || v === "snapshot" || v === "assert"; }

// ── Main ──

const { values: args } = parseArgs({
  options: { chain: { type: "string", default: "1" }, window: { type: "string", default: "w1-1d" }, mode: { type: "string", default: "report" } },
});
const chain = args.chain ?? "1", windowName = args.window ?? "w1-1d", modeRaw = args.mode ?? "report";
if (!isMode(modeRaw)) fail(`bad --mode: ${modeRaw} (expected report|snapshot|assert)`, 2);
const mode: Mode = modeRaw;

let blocksFileRaw: unknown;
try { blocksFileRaw = await Bun.file(BLOCKS_JSON).json(); } catch { fail(`missing/invalid ${BLOCKS_JSON}`, 2); }
const blocksFile = parseBlocksFile(blocksFileRaw);
const win = blocksFile.windows[windowName]?.chains[chain];
if (!win) fail(`no window ${windowName} / chain ${chain} in ${BLOCKS_JSON}`, 2);

const expectedBlocks = Math.floor((win.toBlock - win.fromBlock) / win.blockStep) + 1
  + ((win.toBlock - win.fromBlock) % win.blockStep === 0 ? 0 : 1);
const metrics = win.metrics;
console.error(`Running sweep (window ${windowName}, chain ${chain}, ${expectedBlocks} blocks, metrics: ${metrics.join(",")})...`);

const forgeProc = Bun.spawn(
  ["forge", "test", "--match-contract", "NavBacktest", "--match-test", "test_backtestSweep", "-vv"],
  { cwd: ROOT, env: { ...process.env, BACKTEST_CHAIN: chain, BACKTEST_BLOCKS_FILE: "test/integration/backtest-blocks.json", BACKTEST_WINDOW: windowName, FOUNDRY_PROFILE: "slow" }, stdout: "pipe", stderr: "pipe" },
);
const { out, err, exitCode } = await drainProc(forgeProc);
if (exitCode !== 0) fail(`forge test failed (exit ${exitCode}):\n${(out + err).split("\n").slice(-50).join("\n")}`, 2);

// Parse BACKTEST lines
const results: Series = {};
const re = /^BACKTEST\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(.*)$/;
for (const line of out.split("\n")) {
  const m = line.trim().match(re);
  if (!m || m[1] !== chain) continue;
  const [, , bs, ts, account, metric, val] = m;
  const block = Number(bs), timestamp = Number(ts);
  const point: Point = val.startsWith("ERROR:") ? { block, timestamp, error: val } : { block, timestamp, value: val };
  const bm = results[account] ?? {};
  if (bm[metric] === undefined) bm[metric] = [];
  bm[metric].push(point);
  results[account] = bm;
}
if (Object.keys(results).length === 0) fail("no BACKTEST lines in forge output", 2);

// Completeness check
let missing = false;
const resultAddrs = new Set(Object.keys(results).map((a) => a.toLowerCase()));
if (win.accounts !== undefined) {
  for (const a of win.accounts) {
    if (!resultAddrs.has(a.toLowerCase())) { console.error(`MISSING ACCOUNT: ${a}`); missing = true; }
  }
  for (const a of resultAddrs) {
    if (!win.accounts.some((c) => c.toLowerCase() === a)) { console.error(`EXTRA ACCOUNT: ${a}`); missing = true; }
  }
}
for (const [account, bm] of Object.entries(results)) {
  for (const metric of metrics) {
    if ((bm[metric]?.length ?? 0) !== expectedBlocks) {
      console.error(`MISSING POINTS: ${account}/${metric} has ${bm[metric]?.length ?? 0}/${expectedBlocks}`);
      missing = true;
    }
  }
}

// Report
console.log(`== Backtest report (window ${windowName}, chain ${chain}) ==`);
for (const [account, bm] of Object.entries(results)) {
  for (const [metric, points] of Object.entries(bm)) {
    const errors = points.filter((p) => p.error !== undefined).length;
    console.log(`${account}/${metric}: ${points.length} points, ${errors} reverting`);
    const vals = points.filter((p) => p.value !== undefined);
    let worst: { block: number; pct: number } | undefined;
    for (let i = 1; i < vals.length; i++) {
      const ps = vals[i - 1].value, cs = vals[i].value;
      if (ps === undefined || cs === undefined) continue;
      const prev = BigInt(ps), curr = BigInt(cs);
      const pct = prev === 0n ? (curr === 0n ? 0 : Number.MAX_VALUE) : Number((curr - prev) * 10000n / prev) / 100;
      if (worst === undefined || Math.abs(pct) > Math.abs(worst.pct)) worst = { block: vals[i].block, pct };
    }
    if (worst !== undefined) console.log(`  max step jump ${worst.pct.toFixed(1)}% at block ${worst.block}`);
  }
}

// Mode dispatch
switch (mode) {
  case "report":
    break;
  case "snapshot": {
    if (missing) fail("snapshot aborted: sweep has missing points", 1);
    let fixture: Fixture;
    try { fixture = parseFixture(await Bun.file(FIXTURE).json()); } catch { fixture = { $comment: "Backtest fixture. Regenerate: bun script/test/nav-backtest.ts --mode snapshot", windows: {} }; }
    const commit = await gitShortHash();
    const we: FixtureWindowEntry = { generatedAtCommit: commit, accounts: results };
    const ec = fixture.windows[windowName]?.chains ?? {};
    ec[chain] = we;
    fixture.windows[windowName] = { chains: ec };
    await Bun.write(FIXTURE, `${JSON.stringify(fixture, null, 2)}\n`);
    console.log(`Wrote ${FIXTURE} (window ${windowName}, chain ${chain})`);
    break;
  }
  case "assert": {
    let fixtureRaw: unknown;
    try { fixtureRaw = await Bun.file(FIXTURE).json(); } catch { fail(`no fixture at ${FIXTURE} — run --mode snapshot first`, 2); }
    const fixture = parseFixture(fixtureRaw);
    const pinned = fixture.windows[windowName]?.chains[chain]?.accounts;
    if (!pinned) fail(`no fixture entry for window ${windowName} / chain ${chain} — run --mode snapshot first`, 2);
    if (JSON.stringify(sortKeys(pinned)) === JSON.stringify(sortKeys(results))) {
      console.log("ASSERT OK: sweep matches fixture exactly");
    } else {
      console.error("ASSERT FAIL: sweep differs from fixture");
      diffSeries(pinned, results);
      process.exit(1);
    }
    break;
  }
}

process.exit(missing ? 1 : 0);
