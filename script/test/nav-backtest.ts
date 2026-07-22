#!/usr/bin/env bun
// NAV historical backtest driver (single-file, no dependencies — run with bun).
// Usage: bun script/test/nav-backtest.ts [--chain 1] [--window w1-30d] [--mode report|snapshot|assert]
//   report   (default) run sweep, print summary, do not touch the fixture
//   snapshot run sweep and (over)write the window's entry in test/integration/nav-timeseries.json
//   assert   run sweep and deep-diff against the fixture's window entry; exit 1 on any difference
import { parseArgs } from "node:util";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const BLOCKS_JSON = `${ROOT}/test/integration/backtest-blocks.json`;
const FIXTURE = `${ROOT}/test/integration/nav-timeseries.json`;

// ── Types (parse-don't-validate: boundaries produce these) ──

interface WindowDef {
  fromBlock: number;
  toBlock: number;
  blockStep: number;
  metrics?: string[];
}

interface BlocksFile {
  windows: Record<string, { chains: Record<string, WindowDef> }>;
}

interface Point {
  block: number;
  timestamp: number;
  value?: string;
  error?: string;
}

type Series = Record<string, Record<string, Point[]>>; // account -> metric -> points

interface FixtureWindowEntry {
  generatedAtCommit: string;
  accounts: Series;
}

interface Fixture {
  $comment: string;
  windows: Record<string, { chains: Record<string, FixtureWindowEntry> }>;
}

type Mode = "report" | "snapshot" | "assert";

// ── Helpers ──

function fail(msg: string, code: 1 | 2): never {
  console.error(msg);
  process.exit(code);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortKeys);
  }
  if (isRecord(value)) {
    const sorted: Record<string, unknown> = {};
    const keys = Object.keys(value).sort((a, b) => a.localeCompare(b));
    for (const k of keys) {
      sorted[k] = sortKeys(value[k]);
    }
    return sorted;
  }
  return value;
}

function diffSeries(pinned: Series, current: Series): void {
  let shown = 0;
  const accounts = new Set([...Object.keys(pinned), ...Object.keys(current)]);
  for (const account of accounts) {
    const pinnedMetrics = pinned[account] ?? {};
    const currentMetrics = current[account] ?? {};
    const metrics = new Set([...Object.keys(pinnedMetrics), ...Object.keys(currentMetrics)]);
    for (const metric of metrics) {
      const p = pinnedMetrics[metric] ?? [];
      const c = currentMetrics[metric] ?? [];
      const maxLen = Math.max(p.length, c.length);
      for (let i = 0; i < maxLen && shown < 30; i++) {
        const pi = i < p.length ? p[i] : undefined;
        const ci = i < c.length ? c[i] : undefined;
        if (JSON.stringify(pi) !== JSON.stringify(ci)) {
          const block = ci?.block ?? pi?.block ?? 0;
          console.error(
            `  ${account}/${metric} block ${block}: pinned=${JSON.stringify(pi)} got=${JSON.stringify(ci)}`,
          );
          shown++;
        }
      }
    }
  }
}

// ── Mode type guard ──

function isMode(value: string): value is Mode {
  return value === "report" || value === "snapshot" || value === "assert";
}

// ── Main ──

const { values: args } = parseArgs({
  options: {
    chain: { type: "string", default: "1" },
    window: { type: "string", default: "w1-30d" },
    mode: { type: "string", default: "report" },
  },
});

const chain = args.chain ?? "1";
const windowName = args.window ?? "w1-30d";
const modeRaw = args.mode ?? "report";

if (!isMode(modeRaw)) {
  fail(`bad --mode: ${modeRaw} (expected report|snapshot|assert)`, 2);
}
const mode: Mode = modeRaw;

// Parse blocks file at boundary
let blocksFileRaw: unknown;
try {
  blocksFileRaw = await Bun.file(BLOCKS_JSON).json();
} catch {
  fail(`missing/invalid ${BLOCKS_JSON}`, 2);
}
if (!isRecord(blocksFileRaw) || !isRecord(blocksFileRaw.windows)) {
  fail(`invalid structure in ${BLOCKS_JSON}`, 2);
}
const blocksFile = blocksFileRaw as unknown as BlocksFile;

const win = blocksFile.windows[windowName]?.chains[chain];
if (!win) {
  fail(`no window ${windowName} / chain ${chain} in ${BLOCKS_JSON}`, 2);
}

const expectedBlocks =
  Math.floor((win.toBlock - win.fromBlock) / win.blockStep) + 1 +
  ((win.toBlock - win.fromBlock) % win.blockStep === 0 ? 0 : 1);
const metrics = win.metrics ?? ["nav"];

console.error(
  `Running sweep (window ${windowName}, chain ${chain}, ${expectedBlocks} blocks, metrics: ${metrics.join(",")})...`,
);

// Run forge test
const proc = Bun.spawn(
  ["forge", "test", "--match-contract", "NavBacktest", "--match-test", "test_backtestSweep", "-vv"],
  {
    cwd: ROOT,
    env: {
      ...process.env,
      BACKTEST_CHAIN: chain,
      BACKTEST_BLOCKS_FILE: "test/integration/backtest-blocks.json",
      BACKTEST_WINDOW: windowName,
      FOUNDRY_PROFILE: "slow",
    },
    stdout: "pipe",
    stderr: "pipe",
  },
);

const out = await new Response(proc.stdout).text();
const err = await new Response(proc.stderr).text();
const exitCode = await proc.exited;

if (exitCode !== 0) {
  const tail = (out + err).split("\n").slice(-50).join("\n");
  fail(`forge test failed (exit ${exitCode}):\n${tail}`, 2);
}

// Parse BACKTEST lines at boundary
const results: Series = {};
const backtestRe = /^BACKTEST\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(.*)$/;
for (const line of out.split("\n")) {
  const m = line.trim().match(backtestRe);
  if (!m || m[1] !== chain) continue;
  const [, , blockStr, tsStr, account, metric, val] = m;
  const block = Number(blockStr);
  const timestamp = Number(tsStr);
  const point: Point = val.startsWith("ERROR:")
    ? { block, timestamp, error: val }
    : { block, timestamp, value: val };
  const byMetric = results[account] ?? {};
  const points = byMetric[metric] ?? [];
  points.push(point);
  byMetric[metric] = points;
  results[account] = byMetric;
}

if (Object.keys(results).length === 0) {
  fail("no BACKTEST lines in forge output", 2);
}

// Completeness check
let missing = false;
for (const [account, byMetric] of Object.entries(results)) {
  for (const metric of metrics) {
    const n = byMetric[metric]?.length ?? 0;
    if (n !== expectedBlocks) {
      console.error(`MISSING POINTS: ${account}/${metric} has ${n}/${expectedBlocks}`);
      missing = true;
    }
  }
}

// Report
console.log(`== Backtest report (window ${windowName}, chain ${chain}) ==`);
for (const [account, byMetric] of Object.entries(results)) {
  for (const [metric, points] of Object.entries(byMetric)) {
    const errors = points.filter((p) => p.error !== undefined).length;
    console.log(`${account}/${metric}: ${points.length} points, ${errors} reverting`);
    const vals = points.filter((p) => p.value !== undefined);
    let worst: { block: number; pct: number } | undefined;
    for (let i = 1; i < vals.length; i++) {
      const prev = Number(vals[i - 1].value);
      const curr = Number(vals[i].value);
      const pct = ((curr - prev) / (prev === 0 ? 1 : prev)) * 100;
      if (worst === undefined || Math.abs(pct) > Math.abs(worst.pct)) {
        worst = { block: vals[i].block, pct };
      }
    }
    if (worst !== undefined) {
      console.log(`  max step jump ${worst.pct.toFixed(1)}% at block ${worst.block}`);
    }
  }
}

// Mode dispatch
switch (mode) {
  case "report": {
    // nothing more to do
    break;
  }
  case "snapshot": {
    let fixture: Fixture;
    try {
      const raw = await Bun.file(FIXTURE).json();
      fixture = raw as unknown as Fixture;
    } catch {
      fixture = {
        $comment:
          "Backtest fixture. Regenerate: bun script/test/nav-backtest.ts --mode snapshot",
        windows: {},
      };
    }
    const commitOut = await new Response(
      Bun.spawn(["git", "rev-parse", "--short", "HEAD"], { cwd: ROOT }).stdout,
    ).text();
    const commit = commitOut.trim();
    const windowEntry: FixtureWindowEntry = {
      generatedAtCommit: commit,
      accounts: results,
    };
    const chains = fixture.windows[windowName]?.chains ?? {};
    chains[chain] = windowEntry;
    fixture.windows[windowName] = { chains };
    await Bun.write(FIXTURE, JSON.stringify(fixture, null, 2) + "\n");
    console.log(`Wrote ${FIXTURE} (window ${windowName}, chain ${chain})`);
    break;
  }
  case "assert": {
    let fixtureRaw: unknown;
    try {
      fixtureRaw = await Bun.file(FIXTURE).json();
    } catch {
      fail(
        `no fixture at ${FIXTURE} — run --mode snapshot first`,
        2,
      );
    }
    if (!isRecord(fixtureRaw) || !isRecord(fixtureRaw.windows)) {
      fail(`invalid fixture structure in ${FIXTURE}`, 2);
    }
    const fixture = fixtureRaw as unknown as Fixture;
    const pinned = fixture.windows[windowName]?.chains[chain]?.accounts;
    if (!pinned) {
      fail(
        `no fixture entry for window ${windowName} / chain ${chain} — run --mode snapshot first`,
        2,
      );
    }
    const a = JSON.stringify(sortKeys(pinned));
    const b = JSON.stringify(sortKeys(results));
    if (a === b) {
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
