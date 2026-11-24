// What of an addon the scenarios reach: merges the line and call records `play --coverage` writes, and lists, file by
// file, how much ran and which functions never did (each with its name or the line that makes it).
//
// The addon is the project's coverage addon (addonsim.config.ts "coverage", its first addon by default); the records
// and the report are kept in the project's scenarios folder.
//
//   bun run src/cli/play.ts --coverage    plays every scenario, then writes <scenarios>/.coverage/report.txt
//   bun run src/cli/coverage.ts           composes the report again from the records the last such run left
//   ... --project <dir>                   another project than the working folder's
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import type { Project } from "../project/config.ts";
import { selectProject, takeProjectFlag } from "../project/select.ts";
import { findAddonDir } from "../server/addonSources.ts";
import { loadConfig } from "../server/config.ts";
import { pyFixed } from "./format.ts";

export type CoveragePaths = { dir: string; records: string; report: string };

/** Where a project's coverage records and report are kept */
export const coveragePaths = (project: Project): CoveragePaths => {
  const dir = join(project.scenariosDir, ".coverage");
  return { dir, records: join(dir, "records.tsv"), report: join(dir, "report.txt") };
};

// A line that does something: not blank, not only a comment, not only a closing word or bracket
const QUIET_LINE = /^\s*(--.*)?$|^\s*(end|else|\}|\)|do|then|repeat)[\s,;)\]}]*(--.*)?$/;
const FUNCTION_LINE = /\bfunction\b\s*([\w.:]*)\s*\(/;
const ASSIGNED_NAME = /([\w.[\]"']+)\s*=\s*function\s*\(/;
const SCRIPT_NAME = /SetScript\(\s*"(\w+)"/;
const HOOK_NAME = /(?:hooksecurefunc|HookScript)\(\s*(?:[\w.]+\s*,\s*)?"(\w+)"/;

type Numbers = Map<string, Set<number>>;

/** A text file's lines: utf-8, its byte-order mark and Windows line ends taken off (LuaJIT writes \r\n there) */
const readLines = (path: string): string[] =>
  readFileSync(path, "utf8").replace(/^﻿/, "").replace(/\r\n?/g, "\n").split("\n");

const add = (into: Numbers, name: string, number: number): void => {
  const numbers = into.get(name) ?? new Set<number>();
  numbers.add(number);
  into.set(name, numbers);
};

/** The records: "L<tab>file<tab>line" for a line run, any other kind ("F") for a function called at that line */
const readRecords = (path: string): { lines: Numbers; functions: Numbers } => {
  const lines: Numbers = new Map();
  const functions: Numbers = new Map();
  for (const record of readLines(path)) {
    const [kind, name, number] = record.split("\t");
    if (kind === undefined || name === undefined || number === undefined) continue;
    add(kind === "L" ? lines : functions, name, Number.parseInt(number, 10));
  }
  return { lines, functions };
};

const nameFunction = (text: string, number: number): string => {
  for (const pattern of [ASSIGNED_NAME, FUNCTION_LINE]) {
    const found = pattern.exec(text)?.[1];
    if (found) return found;
  }
  const script = SCRIPT_NAME.exec(text)?.[1];
  if (script !== undefined) return `${script} script`;
  const hook = HOOK_NAME.exec(text)?.[1];
  if (hook !== undefined) return `hook on ${hook}`;
  // Cut by characters, not UTF-16 units, as Python's slice did
  return `function at line ${number}: ${Array.from(text.trim()).slice(0, 70).join("")}`;
};

type Row = { name: string; covered: number; count: number; never: [number, string][] };

const percent = (part: number, whole: number): number => (100 * part) / Math.max(whole, 1);

/** The report on one addon's folder (its own .lua files, not its libraries' folders) from a records file */
export const composeReport = (addonFolder: string, recordsPath: string): string => {
  const records = readRecords(recordsPath);
  const files = readdirSync(addonFolder)
    .filter((name) => name.endsWith(".lua"))
    .sort();
  const rows: Row[] = [];
  let totalRun = 0;
  let totalLines = 0;
  for (const name of files) {
    const text = readLines(join(addonFolder, name));
    const ran = records.lines.get(name) ?? new Set<number>();
    const called = records.functions.get(name) ?? new Set<number>();
    let candidates = 0;
    let covered = 0;
    const never: [number, string][] = [];
    text.forEach((line, index) => {
      const number = index + 1;
      if (!QUIET_LINE.test(line)) {
        candidates += 1;
        if (ran.has(number)) covered += 1;
      }
      if (FUNCTION_LINE.test(line) && !line.trimStart().startsWith("--") && !called.has(number)) {
        never.push([number, nameFunction(line, number)]);
      }
    });
    totalRun += covered;
    totalLines += candidates;
    rows.push({ name, covered, count: candidates, never });
  }
  const out = [
    `Coverage of ${basename(addonFolder)}: ${totalRun} of ${totalLines} lines ran (${pyFixed(percent(totalRun, totalLines), 0)}%)`,
    "",
  ];
  // Least covered first (a stable sort, as Python's)
  const byShare = [...rows].sort((a, b) => a.covered / Math.max(a.count, 1) - b.covered / Math.max(b.count, 1));
  for (const row of byShare) {
    const share = pyFixed(percent(row.covered, row.count), 0).padStart(3);
    out.push(
      `${row.name.padEnd(24)} ${String(row.covered).padStart(5)} of ${String(row.count).padStart(5)} lines  ${share}%   ${row.never.length} functions never ran`,
    );
  }
  out.push("");
  for (const row of rows) {
    if (row.never.length === 0) continue;
    out.push(`== ${row.name} (${row.never.length} never ran)`);
    for (const [number, label] of row.never) out.push(`  ${String(number).padStart(5)}  ${label}`);
  }
  return `${out.join("\n")}\n`;
};

/** Writes report.txt from the records a coverage run left; its first paragraph and where it lies, printed */
export const writeReport = (addonFolder: string, paths: CoveragePaths): void => {
  const report = composeReport(addonFolder, paths.records);
  writeFileSync(paths.report, report);
  process.stdout.write(`\n${report.split("\n\n")[0]}\n`);
  process.stdout.write(`Coverage report: ${paths.report}\n`);
};

/** The project's coverage addon's folder, or null when it names none */
export const coverageFolder = (project: Project): string | null =>
  project.coverageAddon ? findAddonDir(loadConfig(), project.addons, project.coverageAddon) : null;

if (import.meta.main) {
  const project = await selectProject(takeProjectFlag(process.argv.slice(2)).projectDir);
  const paths = coveragePaths(project);
  const folder = coverageFolder(project);
  if (!folder) {
    process.stderr.write(`The project at ${project.root} names no addon to cover (addonsim.config.ts "coverage")\n`);
    process.exit(1);
  }
  if (!existsSync(paths.records)) {
    process.stderr.write(`No coverage records at ${paths.records}: play the scenarios with --coverage first\n`);
    process.exit(1);
  }
  writeReport(folder, paths);
}
