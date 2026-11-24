import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pruneBootCache } from "./bootCache.ts";

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.UTC(2026, 10, 23);
let root: string;

const write = (path: string, ageDays: number, content = "x"): void => {
  writeFileSync(path, content);
  const time = (NOW - ageDays * DAY) / 1000;
  utimesSync(path, time, time);
};

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "addonsim-boot-"));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

test("keeps what a recent run used and what is new, deletes the rest", () => {
  const folder = join(root, "1-LuaJIT21");
  mkdirSync(join(folder, "used"), { recursive: true });
  write(join(folder, ".made"), 60);
  write(join(folder, "lua-a-1.luac"), 40);
  write(join(folder, "lua-a-0.luac"), 40, "old"); // (the same file before it changed)
  write(join(folder, "lua-b-1.luac"), 0.1); // (written by a run going on now)
  write(join(folder, "lua-c-1.luac"), 30); // (listed by a run long ago only)
  write(join(folder, "used", "recent.txt"), 2, "lua-a-1.luac\n");
  write(join(folder, "used", "old.txt"), 30, "lua-c-1.luac\n");

  const result = pruneBootCache(root, { now: NOW });
  expect(result.files).toBe(2);
  expect(existsSync(join(folder, "lua-a-1.luac"))).toBe(true);
  expect(existsSync(join(folder, "lua-b-1.luac"))).toBe(true);
  expect(existsSync(join(folder, "lua-a-0.luac"))).toBe(false);
  expect(existsSync(join(folder, "lua-c-1.luac"))).toBe(false);
  expect(existsSync(join(folder, "used", "old.txt"))).toBe(false);
});

test("a folder no run uses any more goes once nothing in it is recent; a recent one stays", () => {
  const old = join(root, "0-LuaJIT20");
  mkdirSync(old);
  write(join(old, ".made"), 90);
  write(join(old, "lua-a-1.luac"), 60);
  const lively = join(root, "1-LuaJIT21");
  mkdirSync(lively);
  write(join(lively, ".made"), 90);
  write(join(lively, "lua-a-1.luac"), 1); // (a cache from before the lists, still in use)

  const result = pruneBootCache(root, { now: NOW });
  expect(result.folders).toBe(1);
  expect(existsSync(old)).toBe(false);
  expect(existsSync(join(lively, "lua-a-1.luac"))).toBe(true);
});

test("once a day", () => {
  const folder = join(root, "1-LuaJIT21");
  mkdirSync(join(folder, "used"), { recursive: true });
  write(join(folder, "used", "recent.txt"), 1, "");
  expect(pruneBootCache(root, { now: NOW }).isSkipped).toBe(false);
  write(join(folder, "lua-a-1.luac"), 40);
  expect(pruneBootCache(root, { now: NOW + 60_000 }).isSkipped).toBe(true);
  expect(existsSync(join(folder, "lua-a-1.luac"))).toBe(true);
  expect(pruneBootCache(root, { now: NOW + 60_000, isForced: true }).files).toBe(1);
});
